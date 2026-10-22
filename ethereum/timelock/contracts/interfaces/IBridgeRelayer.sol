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

/// @title The Bridge relayer-level API needed by the TimeLock contract.
/// @notice Subset of the production Bridge's relayer interface, exactly the calls the
///         TimeLock queue executes against the Bridge after the lock delay elapses.
interface IBridgeRelayer {
    function newRelayEon() external;
    function refund(uint64 id, address to, uint256 amount, uint64 relayEon_) external;
    function refundInFull(uint64 id, address to, uint256 amount, uint64 relayEon_) external;
    function reverseSwap(
        uint64 rid,
        address to,
        string calldata from,
        bytes32 originTxHash,
        uint256 amount,
        uint64 relayEon_
    ) external;
}
