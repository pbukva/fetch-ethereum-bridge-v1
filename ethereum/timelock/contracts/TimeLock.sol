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

import "@openzeppelin/contracts/access/AccessControl.sol";

import "./interfaces/IBridgeRelayer.sol";
import "./interfaces/ITimeLock.sol";

/**
 * @title TimeLock - delayed message queue in front of the Bridge relayer API.
 *
 * @notice EVM twin of the CosmWasm `fetch/contract-timelock`:
 *         Relayer messages (`reverseSwap`, `refund`, `refundInFull`, `newRelayEon`) are
 *         first *submitted* into this contract's queue, where they wait out their
 *         respective lock delays. An off-chain executor service then *executes* them
 *         against the Bridge (`EXECUTE_ROLE`), strictly in nonce order. A failing
 *         Bridge call does NOT revert the executing transaction - the message is
 *         marked `Failed` instead (mirror of the CosmWasm sub-message + reply design).
 *
 * @dev Mapping from the CosmWasm contract:
 *      - `SUBMIT_ROLE` / `EXECUTE_ROLE` / `CANCEL_ROLE` -> same names, OZ AccessControl roles.
 *      - Lock delays & pausing are measured by block height (`block.number`): the
 *        `execution_time`/`lock_delay` seconds and `paused_since_block` height of the
 *        CosmWasm twin are unified into one block-height clock on the EVM side.
 *      - `StateUpdate` with `Option` fields -> `updateState(...)`, where the zero value
 *        of a parameter means "keep the current one".
 *      - Queue nonces start at 0 (CosmWasm parity); nonces are strictly increasing and
 *        never reused. The id->nonce index mappings (`reverseSwapIdToNonce` /
 *        `refundSwapIdToNonce`) store the nonce **+ 1**, so that 0 can mean "no message".
 *      - CosmWasm `ReverseSwapMessages` / `RefundMessages` queries have no O(1) EVM
 *        equivalent - the full history is reconstructable from `MessageSubmitted` events
 *        (indexed nonce + id) off-chain instead.
 */
contract TimeLock is ITimeLock, AccessControl {

    // -----     ROLES     ------------------------------------------------------

    bytes32 public constant SUBMIT_ROLE = keccak256("SUBMIT_ROLE");
    bytes32 public constant EXECUTE_ROLE = keccak256("EXECUTE_ROLE");
    bytes32 public constant CANCEL_ROLE = keccak256("CANCEL_ROLE");

    // -----     STATE     ------------------------------------------------------

    /// @notice Bridge contract this TimeLock fronts.
    IBridgeRelayer public bridge;
    /// @notice Lock delay [blocks] applied to `reverseSwap` submissions.
    uint64 public reverseSwapLockDelay;
    /// @notice Lock delay [blocks] applied to `refund` / `refundInFull` submissions.
    uint64 public refundLockDelay;
    /// @notice Max number of pending messages; further submits are rejected.
    uint64 public nMaxPendingMessages;

    /// @notice Nonce of the next submitted message (first submitted message gets nonce 0).
    ///         Nonces are strictly increasing and are never reused.
    uint64 public nextSubmitNonce = 0;
    /// @notice Nonce of the next message eligible for execution (first pending message,
    ///         or `nextSubmitNonce` when the queue is empty).
    uint64 public nextExecuteNonce = 0;
    /// @notice Number of currently pending messages.
    uint64 public nPendingMessages;

    /// @notice The queue: nonce -> message. Use `getMessage(nonce)` to read a full record.
    mapping(uint64 nonce => Message) private _messages;
    /// @notice rid -> (nonce of the last submitted ReverseSwap with that rid) + 1;
    ///         0 = none submitted yet. Stores nonce + 1 because nonces are 0-based.
    mapping(uint64 rid => uint64 noncePlusOne) public reverseSwapIdToNonce;
    /// @notice id -> (nonce of the last submitted Refund/RefundInFull with that id) + 1;
    ///         0 = none submitted yet. Refunds and RefundsInFull share one id space
    ///         (same as on the CosmWasm side). Stores nonce + 1 because nonces are 0-based.
    mapping(uint64 id => uint64 noncePlusOne) public refundSwapIdToNonce;

    /// @notice Block height since which the contract is paused
    ///         (`type(uint64).max` = not paused).
    uint64 public pausedSinceBlock;

    // -----     MODIFIERS     --------------------------------------------------

    modifier notPaused() {
        if (pausedSinceBlock <= block.number) revert ContractIsPaused();
        _;
    }

    // -----     CONSTRUCTOR     ------------------------------------------------

    /**
     * @param bridge_ - address of the Bridge contract this TimeLock fronts
     * @param reverseSwapLockDelay_ - lock delay [s] for reverse swap submissions
     * @param refundLockDelay_ - lock delay [s] for refund submissions
     * @param nMaxPendingMessages_ - max number of pending messages
     * @param admin_ - initial admin (gets DEFAULT_ADMIN_ROLE), grants roles to services
     */
    constructor(
        address bridge_,
        uint64 reverseSwapLockDelay_,
        uint64 refundLockDelay_,
        uint64 nMaxPendingMessages_,
        address admin_
    ) {
        if (bridge_ == address(0)) revert ZeroAddress();
        if (admin_ == address(0)) revert ZeroAddress();
        if (reverseSwapLockDelay_ == 0) revert ZeroLockDelay();
        if (refundLockDelay_ == 0) revert ZeroLockDelay();
        if (nMaxPendingMessages_ == 0) revert ZeroMaxPendingMessages();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);

        bridge = IBridgeRelayer(bridge_);
        reverseSwapLockDelay = reverseSwapLockDelay_;
        refundLockDelay = refundLockDelay_;
        nMaxPendingMessages = nMaxPendingMessages_;
        pausedSinceBlock = type(uint64).max;
    }

    // -----     SUBMIT API (SUBMIT_ROLE)     -----------------------------------

    /**
     * @notice Submits a delayed `reverseSwap` message into the queue.
     * @param rid - reverse swap id (from the Fetch native side)
     * @param to - address where the Bridge will send the swapped tokens
     * @param sender - origin source address (for event indexing, mirror of CosmWasm)
     * @param originTxHash - hash of the origin swap transaction on the other chain
     * @param amount - original swap amount (includes the swap fee)
     * @param relayEon_ - relay eon of the operation
     */
    function submitReverseSwap(
        uint64 rid,
        address to,
        string calldata sender,
        bytes32 originTxHash,
        uint256 amount,
        uint64 relayEon_
    ) external onlyRole(SUBMIT_ROLE) notPaused {
        uint64 noncePlusOne = _submit(
            Message({
                kind: MsgKind.ReverseSwap,
                state: ExecutionState.Pending,
                executionBlock: _lockBlock(reverseSwapLockDelay),
                relayEon: relayEon_,
                id: rid,
                amount: amount,
                to: to,
                sender: sender,
                originTxHash: originTxHash
            }),
            reverseSwapIdToNonce[rid]
        );
        reverseSwapIdToNonce[rid] = noncePlusOne;
    }

    /**
     * @notice Submits a delayed `refund` message into the queue.
     * @param id - swap id to refund
     * @param to - address where the Bridge will send the refunded tokens
     * @param amount - original swap amount (includes the swap fee)
     * @param relayEon_ - relay eon of the operation
     */
    function submitRefund(
        uint64 id,
        address to,
        uint256 amount,
        uint64 relayEon_
    ) external onlyRole(SUBMIT_ROLE) notPaused {
        uint64 noncePlusOne = _submit(
            Message({
                kind: MsgKind.Refund,
                state: ExecutionState.Pending,
                executionBlock: _lockBlock(refundLockDelay),
                relayEon: relayEon_,
                id: id,
                amount: amount,
                to: to,
                sender: "",
                originTxHash: 0
            }),
            refundSwapIdToNonce[id]
        );
        refundSwapIdToNonce[id] = noncePlusOne;
    }

    /**
     * @notice Submits a delayed `refundInFull` message into the queue.
     * @param id - swap id to refund
     * @param to - address where the Bridge will send the refunded tokens
     * @param amount - original swap amount
     * @param relayEon_ - relay eon of the operation
     */
    function submitRefundInFull(
        uint64 id,
        address to,
        uint256 amount,
        uint64 relayEon_
    ) external onlyRole(SUBMIT_ROLE) notPaused {
        uint64 noncePlusOne = _submit(
            Message({
                kind: MsgKind.RefundInFull,
                state: ExecutionState.Pending,
                executionBlock: _lockBlock(refundLockDelay),
                relayEon: relayEon_,
                id: id,
                amount: amount,
                to: to,
                sender: "",
                originTxHash: 0
            }),
            refundSwapIdToNonce[id]
        );
        refundSwapIdToNonce[id] = noncePlusOne;
    }

    /**
     * @notice Cancels all pending messages and executes `newRelayEon` on the Bridge
     *         right away (in the same transaction) - mirror of the CosmWasm behaviour:
     *         `NewRelayEon` is not limited by `nMaxPendingMessages` and leaves no other
     *         message pending.
     */
    function newRelayEon() external onlyRole(SUBMIT_ROLE) notPaused {
        _cancelAll();
        uint64 nonce = _pushNewRelayEon();
        _dispatch(nonce, uint64(block.number));
    }

    // -----     EXECUTE / CANCEL API     ---------------------------------------

    /**
     * @notice Executes the next message in nonce order against the Bridge.
     *         Does NOT revert when the Bridge call itself fails - the message is
     *         marked `Failed` and the reason is emitted in the `MessageFailed` event.
     */
    function execute(uint64 nonce) external onlyRole(EXECUTE_ROLE) notPaused {
        _dispatch(nonce, uint64(block.number));
    }

    /**
     * @notice Cancels a pending message; execution then skips it.
     *         NOT gated by `notPaused` (same as the CosmWasm counterpart).
     */
    function cancel(uint64 nonce) external onlyRole(CANCEL_ROLE) {
        _cancel(nonce);
    }

    // -----     ADMIN API (DEFAULT_ADMIN_ROLE)     -----------------------------

    /**
     * @notice Partial state update: a zero value (resp. `address(0)`) keeps the current
     *         value (EVM adaptation of the CosmWasm `StateUpdate` with `Option` fields).
     */
    function updateState(
        address bridge_,
        uint64 reverseSwapLockDelay_,
        uint64 refundLockDelay_,
        uint64 nMaxPendingMessages_
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bridge_ != address(0)) bridge = IBridgeRelayer(bridge_);
        if (reverseSwapLockDelay_ != 0) reverseSwapLockDelay = reverseSwapLockDelay_;
        if (refundLockDelay_ != 0) refundLockDelay = refundLockDelay_;
        if (nMaxPendingMessages_ != 0) nMaxPendingMessages = nMaxPendingMessages_;

        emit StateUpdated(
            address(bridge),
            reverseSwapLockDelay,
            refundLockDelay,
            nMaxPendingMessages
        );
    }

    function pauseSince(uint64 sinceBlock) external onlyRole(DEFAULT_ADMIN_ROLE) {
        pausedSinceBlock = sinceBlock;
        emit PausedSince(sinceBlock);
    }

    function resume() external onlyRole(DEFAULT_ADMIN_ROLE) {
        pausedSinceBlock = type(uint64).max;
        emit Resumed();
    }

    // -----     VIEW / GETTERS     ---------------------------------------------

    function getMessage(uint64 nonce) public view returns (Message memory) {
        return _messages[nonce];
    }

    /// @inheritdoc ITimeLock
    function getPendingMessages(uint64 startAfter, uint32 limit)
        public
        view
        returns (MessageView[] memory out)
    {
        // inclusive `nextExecuteNonce` when startAfter is 0 (no bound) or below it,
        // exclusive otherwise (mirror of the CosmWasm `Bound::inclusive` / `Bound::exclusive`
        // logic, with 0 as the EVM adaptation of `Option::None`)
        uint64 from = (startAfter != 0 && startAfter >= nextExecuteNonce)
            ? (startAfter + 1)
            : nextExecuteNonce;

        out = new MessageView[](0);
        if (from >= nextSubmitNonce || nPendingMessages == 0) {
            return out;
        }

        out = new MessageView[](nPendingMessages);
        uint32 n = 0;
        for (uint64 nonce = from; nonce < nextSubmitNonce && n < limit; nonce++) {
            Message storage m = _messages[nonce];
            if (m.state != ExecutionState.Pending) continue;
            out[n++] = MessageView({ nonce: nonce, message: m });
        }
        // trim to the actual number of pending messages found
        assembly {
            mstore(out, n)
        }
    }

    /// @inheritdoc ITimeLock
    function getLastReverseSwapMessage(uint64 rid)
        external
        view
        returns (MessageView memory)
    {
        uint64 noncePlusOne = reverseSwapIdToNonce[rid];
        if (noncePlusOne == 0) {
            return MessageView({ nonce: 0, message: _emptyMessage() });
        }
        return MessageView({ nonce: noncePlusOne - 1, message: _messages[noncePlusOne - 1] });
    }

    /// @inheritdoc ITimeLock
    function getLastRefundMessage(uint64 id)
        external
        view
        returns (MessageView memory)
    {
        uint64 noncePlusOne = refundSwapIdToNonce[id];
        if (noncePlusOne == 0) {
            return MessageView({ nonce: 0, message: _emptyMessage() });
        }
        return MessageView({ nonce: noncePlusOne - 1, message: _messages[noncePlusOne - 1] });
    }

    // -----     INTERNAL: SUBMIT     --------------------------------------------

    /// @dev Earliest execution block height for a message submitted now with `delay`.
    function _lockBlock(uint64 delay) private view returns (uint64) {
        // NOTE(pb): Mirror of the CosmWasm `execution_time_overflow_error`:
        //  `block.number + delay` can not realistically overflow uint64, still
        //  keeping the explicit check for completeness.
        if (block.number > type(uint64).max - delay) revert ExecutionBlockOverflow();
        return uint64(block.number) + delay;
    }

    /// @dev Pushes `m` into the queue and returns the allocated nonce.
    ///      `lastIndexNoncePlusOne` is the value of the id->nonce index mapping for the
    ///      message's index (id/rid): the nonce of the last message with that index + 1,
    ///      or 0 = none submitted yet. Reverts with `MessageAlreadySubmitted` while that
    ///      message is Pending or Executed (mirror of the CosmWasm `push`).
    function _submit(Message memory m, uint64 lastIndexNoncePlusOne)
        private
        returns (uint64 _submitNoncePlusOne)
    {
        if (m.kind != MsgKind.NewRelayEon && lastIndexNoncePlusOne != 0) {
            uint64 lastNonce = lastIndexNoncePlusOne - 1;
            ExecutionState lastState = _messages[lastNonce].state;
            if (lastState == ExecutionState.Pending || lastState == ExecutionState.Executed) {
                revert MessageAlreadySubmitted(lastNonce);
            }
        }

        if (nPendingMessages >= nMaxPendingMessages) {
            revert TooManyPendingMessages(nMaxPendingMessages);
        }

        uint64 nonce = nextSubmitNonce;
        if (nonce == type(uint64).max) revert NonceOverflow();
        nextSubmitNonce = nonce + 1;

        _messages[nonce] = m;
        nPendingMessages += 1;

        emit MessageSubmitted(nonce, m.kind, msg.sender, m.executionBlock, m.id);

        return nonce + 1;
    }

    /// @dev Pushes the `NewRelayEon` message, bypassing the `nMaxPendingMessages` check
    ///      (mirror of the CosmWasm `execute_new_relay_eon`) - the queue was just
    ///      emptied by `_cancelAll()`, so the message is the only pending one.
    function _pushNewRelayEon() private returns (uint64 nonce) {
        nonce = nextSubmitNonce;
        if (nonce == type(uint64).max) revert NonceOverflow();
        nextSubmitNonce = nonce + 1;

        _messages[nonce] = Message({
            kind: MsgKind.NewRelayEon,
            state: ExecutionState.Pending,
            executionBlock: uint64(block.number),
            relayEon: 0,
            id: 0,
            amount: 0,
            to: address(0),
            sender: "",
            originTxHash: 0
        });
        nPendingMessages += 1;

        emit MessageSubmitted(nonce, MsgKind.NewRelayEon, msg.sender, uint64(block.number), 0);
    }

    // -----     INTERNAL: EXECUTE / CANCEL     ---------------------------------

    /// @dev Checks that `nonce` is next in order and mature, then dispatches to the
    ///      Bridge. The message stays `Pending` until `_finishExecution` records the result.
    function _dispatch(uint64 nonce, uint64 now) private {
        if (nonce != nextExecuteNonce) {
            revert MessageNotNext(nonce, nextExecuteNonce);
        }
        Message storage m = _messages[nonce];
        if (m.state != ExecutionState.Pending) revert MessageNotPending(nonce);
        if (now < m.executionBlock) revert MessageNotMature(nonce, m.executionBlock);

        _advance(nonce + 1);

        // NOTE(pb): Mirror of the CosmWasm sub-message + `reply`: a failing Bridge call
        //  must NOT revert this transaction, the failure is recorded on the message.
        bool success;
        bytes memory reason;
        if (m.kind == MsgKind.ReverseSwap) {
            (success, reason) = _callBridge(
                abi.encodeCall(
                    IBridgeRelayer.reverseSwap,
                    (m.id, m.to, m.sender, m.originTxHash, m.amount, m.relayEon)
                )
            );
        } else if (m.kind == MsgKind.Refund) {
            (success, reason) = _callBridge(
                abi.encodeCall(IBridgeRelayer.refund, (m.id, m.to, m.amount, m.relayEon))
            );
        } else if (m.kind == MsgKind.RefundInFull) {
            (success, reason) = _callBridge(
                abi.encodeCall(IBridgeRelayer.refundInFull, (m.id, m.to, m.amount, m.relayEon))
            );
        } else {
            (success, reason) = _callBridge(
                abi.encodeCall(IBridgeRelayer.newRelayEon, ())
            );
        }

        _finishExecution(nonce, success, reason);
    }

    /// @dev Low-level Bridge call, isolates the Bridge revert reason.
    function _callBridge(bytes memory callData) private returns (bool, bytes memory) {
        (bool success, bytes memory ret) = address(bridge).call(callData);
        return (success, ret);
    }

    /// @dev Records the Bridge result on the message (mirror of the CosmWasm `reply`).
    function _finishExecution(uint64 nonce, bool success, bytes memory reason) private {
        Message storage m = _messages[nonce];
        m.state = success ? ExecutionState.Executed : ExecutionState.Failed;
        nPendingMessages -= 1;

        if (success) {
            emit MessageExecuted(nonce);
        } else {
            emit MessageFailed(nonce, reason);
        }
    }

    /// @dev Cancels a pending message; execution then skips it.
    function _cancel(uint64 nonce) private {
        Message storage m = _messages[nonce];
        if (m.state != ExecutionState.Pending) revert MessageNotPending(nonce);

        m.state = ExecutionState.Cancelled;
        nPendingMessages -= 1;
        emit MessageCancelled(nonce);

        if (nonce == nextExecuteNonce) {
            _advance(nonce + 1);
        }
    }

    /// @dev Cancels ALL pending messages, the execute pointer moves to the submit pointer.
    function _cancelAll() private {
        uint64 from = nextExecuteNonce;
        uint64 to = nextSubmitNonce;
        if (nPendingMessages > 0) {
            for (uint64 nonce = from; nonce < to; nonce++) {
                Message storage m = _messages[nonce];
                if (m.state == ExecutionState.Pending) {
                    m.state = ExecutionState.Cancelled;
                    emit MessageCancelled(nonce);
                }
            }
            nPendingMessages = 0;
        }
        nextExecuteNonce = nextSubmitNonce;
        emit CancelledAll(from, to);
    }

    /// @dev Moves the execute pointer to the first pending message >= `from`,
    ///      or to the submit pointer if there is none.
    function _advance(uint64 from) private {
        for (uint64 nonce = from; nonce < nextSubmitNonce; nonce++) {
            if (_messages[nonce].state == ExecutionState.Pending) {
                nextExecuteNonce = nonce;
                return;
            }
        }
        nextExecuteNonce = nextSubmitNonce;
    }

    /// @dev Zero message used by `getLast*Message` when nothing was submitted for the id.
    function _emptyMessage() private pure returns (Message memory) {
        return Message({
            kind: MsgKind.NewRelayEon,
            state: ExecutionState.Pending,
            executionBlock: 0,
            relayEon: 0,
            id: 0,
            amount: 0,
            to: address(0),
            sender: "",
            originTxHash: 0
        });
    }
}
