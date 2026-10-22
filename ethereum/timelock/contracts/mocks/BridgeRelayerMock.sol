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

import "../interfaces/IBridgeRelayer.sol";

/// @title Mock of the Bridge relayer API, dedicated for the TimeLock tests.
/// @notice Records every call and can be switched into a "revert mode" to exercise
///         the `Failed` message path of the TimeLock `execute(...)` flow.
contract BridgeRelayerMock is IBridgeRelayer {
    /// @notice When true, every relayer call reverts (for testing `MessageFailed`).
    bool public shouldRevert;

    uint64 public relayEon = type(uint64).max;

    struct ReverseSwapCall {
        uint64 rid;
        address to;
        string sender;  // NOTE(pb): named `sender` not `from` - `from` is a Python
                        // keyword and breaks struct decoding in the test framework.
        bytes32 originTxHash;
        uint256 amount;
        uint64 relayEon;
    }
    struct RefundCall {
        uint64 id;
        address to;
        uint256 amount;
        uint64 relayEon;
        bool inFull;
    }

    uint256 public nReverseSwaps;
    uint256 public nRefunds;
    uint256 public nNewRelayEons;

    mapping(uint256 => ReverseSwapCall) public reverseSwapCalls;
    mapping(uint256 => RefundCall) public refundCalls;

    event MockRevertedIntoFailurePath(bytes reason);

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function newRelayEon() external override {
        _maybeRevert();
        // NOTE(pb): unchecked to mirror the production Bridge (solc 0.7.6), where the
        //           very first increment deliberately overflows MAX_UINT64 -> 0.
        unchecked {
            relayEon += 1;
        }
        nNewRelayEons += 1;
    }

    function refund(uint64 id, address to, uint256 amount, uint64 relayEon_) external override {
        _maybeRevert();
        refundCalls[nRefunds++] = RefundCall({
            id: id,
            to: to,
            amount: amount,
            relayEon: relayEon_,
            inFull: false
        });
    }

    function refundInFull(uint64 id, address to, uint256 amount, uint64 relayEon_) external override {
        _maybeRevert();
        refundCalls[nRefunds++] = RefundCall({
            id: id,
            to: to,
            amount: amount,
            relayEon: relayEon_,
            inFull: true
        });
    }

    function reverseSwap(
        uint64 rid,
        address to,
        string calldata from,
        bytes32 originTxHash,
        uint256 amount,
        uint64 relayEon_
    ) external override {
        _maybeRevert();
        reverseSwapCalls[nReverseSwaps++] = ReverseSwapCall({
            rid: rid,
            to: to,
            sender: from,
            originTxHash: originTxHash,
            amount: amount,
            relayEon: relayEon_
        });
    }

    function _maybeRevert() private view {
        require(!shouldRevert, "MockBridge: forced revert");
    }
}
