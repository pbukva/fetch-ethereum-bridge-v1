// SPDX-License-Identifier: Apache-2.0
//------------------------------------------------------------------------------
//
//   Copyright 2026 Fetch.AI Limited
//
//   Licensed under the Apache License, Version 2.0 (the "License");
//   you may not use this file except in compliance with the License.
//   You may obtain a copy of the License at
//
//       http://www.apache.org/licenses/LICENSE-2.0
//
//   Unless required by applicable law or agreed to in writing, software
//   distributed under the License is distributed on an "AS IS" BASIS,
//   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//   See the License for the specific language governing permissions and
//   limitations under the License.
//
//------------------------------------------------------------------------------

pragma solidity 0.8.24;

import "./IBridgeRelayer.sol";

/// @title Interface of the TimeLock - delayed message queue in front of the Bridge
///        relayer API (EVM twin of the CosmWasm `fetch/contract-timelock`).
interface ITimeLock {

    // -----     TYPES     -------------------------------------------------------

    /// @dev Message kind mirrors the CosmWasm `BridgeMessagePayload` variants.
    enum MsgKind {
        ReverseSwap,   // 0
        Refund,        // 1
        RefundInFull,  // 2
        NewRelayEon    // 3
    }

    /// @dev Message lifecycle mirrors the CosmWasm `ExecutionState` variants.
    enum ExecutionState {
        Pending,   // 0
        Executed,  // 1
        Cancelled, // 2
        Failed     // 3
    }

    /// @dev Full queued message record (`BridgeMessage` on the CosmWasm side).
    ///      Fields not relevant for the given `kind` are zero-initialised.
    struct Message {
        MsgKind kind;
        ExecutionState state;
        uint64 executionTime;  // earliest block.timestamp the message can be executed
        uint64 relayEon;
        uint64 id;             // rid (ReverseSwap) or swap id (Refund/RefundInFull), 0 for NewRelayEon
        uint256 amount;
        address to;
        string sender;         // origin source address (ReverseSwap only), empty otherwise
        bytes32 originTxHash;  // ReverseSwap only
    }

    /// @dev (nonce, message) pair returned by the getters.
    ///      `nonce == 0` in `getLast*Message` means "no message with that id/rid submitted".
    struct MessageView {
        uint64 nonce;
        Message message;
    }

    // -----     ERRORS     -----------------------------------------------------

    error ZeroAddress();
    error ZeroLockDelay();
    error ZeroMaxPendingMessages();
    error ContractIsPaused();
    error TooManyPendingMessages(uint64 nMaxPendingMessages);
    error ExecutionTimeOverflow();
    error NonceOverflow();
    error MessageAlreadySubmitted(uint64 nonce);
    error MessageNotFound(uint64 nonce);
    error MessageNotPending(uint64 nonce);
    error MessageNotNext(uint64 nonce, uint64 expected);
    error MessageNotMature(uint64 nonce, uint64 executionTime);

    // -----     EVENTS     -----------------------------------------------------

    /// @dev Mirror of the CosmWasm `state_updated` event.
    event StateUpdated(
        address indexed bridge,
        uint64 reverseSwapLockDelay,
        uint64 refundLockDelay,
        uint64 nMaxPendingMessages
    );

    /// @dev Mirror of the CosmWasm `ContractPausedEvent`.
    event PausedSince(uint64 sinceTimestamp);

    /// @dev Mirror of the CosmWasm `ContractResumedEvent`.
    event Resumed();

    /// @dev Emitted on each successful submission (CosmWasm: `action=submit` attributes).
    ///      The `id` (rid for reverse swaps, swap id for refunds, 0 for `NewRelayEon`) makes
    ///      the full per-index message history reconstructable from events - the EVM
    ///      replacement of the CosmWasm `ReverseSwapMessages` / `RefundMessages` queries.
    event MessageSubmitted(
        uint64 indexed nonce,
        MsgKind indexed kind,
        address indexed submitter,
        uint64 executionTime,
        uint64 id
    );

    event MessageCancelled(uint64 indexed nonce);

    event MessageExecuted(uint64 indexed nonce);

    /// @dev The Bridge call failed inside `execute(...)` - the transaction itself SUCCEEDS
    ///      and the message is marked `Failed` (mirror of the CosmWasm sub-message + reply).
    event MessageFailed(uint64 indexed nonce, bytes reason);

    /// @dev Summary of the `cancelAll` performed by `newRelayEon()`
    ///      (the CosmWasm side emits per-message `message_updated` events instead).
    event CancelledAll(uint64 fromNonce, uint64 toNonce);

    // -----     STATE GETTERS (mirror of the CosmWasm queries)     -------------

    function bridge() external view returns (IBridgeRelayer);
    function reverseSwapLockDelay() external view returns (uint64);
    function refundLockDelay() external view returns (uint64);
    function nMaxPendingMessages() external view returns (uint64);
    function nextSubmitNonce() external view returns (uint64);
    function nextExecuteNonce() external view returns (uint64);
    function nPendingMessages() external view returns (uint64);
    function pausedSinceTimestamp() external view returns (uint64);

    /// @notice rid -> (nonce of the last submitted ReverseSwap with that rid) + 1;
    ///         0 = none submitted (nonces are 0-based).
    function reverseSwapIdToNonce(uint64 rid) external view returns (uint64);

    /// @notice id -> (nonce of the last submitted Refund/RefundInFull with that id) + 1;
    ///         0 = none submitted (nonces are 0-based).
    function refundSwapIdToNonce(uint64 id) external view returns (uint64);

    function getMessage(uint64 nonce) external view returns (Message memory);

    /// @notice Pending messages in execution order, starting from the next one to execute
    ///         (mirror of the CosmWasm `PendingMessages` query).
    /// @param startAfter - return messages with nonce strictly greater than this;
    ///                     `0` = no bound (from the next one to execute); values below
    ///                     `nextExecuteNonce` are clamped to it
    /// @param limit - max number of returned messages
    function getPendingMessages(uint64 startAfter, uint32 limit)
        external
        view
        returns (MessageView[] memory);

    /// @notice The last submitted reverse swap message with the given `rid`.
    ///         `nonce == 0` AND empty message = no message with that rid
    ///         (mirror of `LastReverseSwapMessage`).
    function getLastReverseSwapMessage(uint64 rid) external view returns (MessageView memory);

    /// @notice The last submitted refund/refund-in-full message with the given `id`.
    ///         `nonce == 0` AND empty message = no message with that id
    ///         (mirror of `LastRefundMessage`).
    function getLastRefundMessage(uint64 id) external view returns (MessageView memory);

    // -----     SUBMIT API (SUBMIT_ROLE)     -----------------------------------

    function submitReverseSwap(
        uint64 rid,
        address to,
        string calldata sender,
        bytes32 originTxHash,
        uint256 amount,
        uint64 relayEon_
    ) external;

    function submitRefund(uint64 id, address to, uint256 amount, uint64 relayEon_) external;

    function submitRefundInFull(uint64 id, address to, uint256 amount, uint64 relayEon_) external;

    /// @notice Cancels all pending messages and executes `newRelayEon` on the Bridge right away.
    function newRelayEon() external;

    // -----     EXECUTE / CANCEL API (EXECUTE_ROLE / CANCEL_ROLE)     ----------

    /// @notice Executes the next mature message against the Bridge.
    ///         Does NOT revert when the Bridge call itself fails - the message is marked `Failed`.
    function execute(uint64 nonce) external;

    function cancel(uint64 nonce) external;

    // -----     ADMIN API (DEFAULT_ADMIN_ROLE)     -----------------------------

    /// @notice Partial state update: a zero value (resp. `address(0)`) keeps the current
    ///         value (EVM adaptation of the CosmWasm `StateUpdate` with `Option` fields).
    function updateState(
        address bridge_,
        uint64 reverseSwapLockDelay_,
        uint64 refundLockDelay_,
        uint64 nMaxPendingMessages_
    ) external;

    function pauseSince(uint64 sinceTimestamp) external;

    function resume() external;
}
