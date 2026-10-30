# TimeLock (EVM)

Solidity implementation of the `TimeLock` contract - the EVM twin of the CosmWasm
[`fetch/contract-timelock`](../../fetch/contract-timelock): a delayed message queue placed
in front of the [Bridge](../contracts/Bridge.sol) relayer API.

## Why a new Ape project

The parent `ethereum/` directory still uses the (no longer maintained)
[eth-brownie](https://github.com/eth-brownie/brownie) framework pinned to `solc 0.7.6`.
This project uses the actively developed [Ape framework](https://github.com/ApeWorX/ape)
instead, as a self-contained workspace - the brownie setup for the existing `Bridge`
contract stays untouched.

## Design

Relayer messages (`reverseSwap`, `refund`, `refundInFull`, `newRelayEon`) are first
*submitted* into the TimeLock queue, where they wait out their respective lock delay.
An off-chain executor service then *executes* them against the Bridge, strictly in nonce
order. A failing Bridge call does **not** revert the executing transaction - the message
is marked `Failed` and the reason is emitted in a `MessageFailed` event (the EVM mirror
of the CosmWasm sub-message + `reply` pattern).

Key mappings from the CosmWasm counterpart (see the contract natspec for details):

| CosmWasm `contract-timelock` | EVM `TimeLock` |
|---|---|
| `SUBMIT_ROLE` / `EXECUTE_ROLE` / `CANCEL_ROLE` | same (OpenZeppelin `AccessControl`) |
| pausing by block height | pausing by block height (`pauseSince`/`resume`) |
| lock delays in seconds (`block.time`) | lock delays in blocks (`block.number`) |
| `StateUpdate` with `Option` fields | `updateState(...)` - zero value keeps the current one |
| `NewRelayEon` (cancel-all + immediate dispatch) | `newRelayEon()` |
| `PendingMessages` / `LastReverseSwapMessage` / `LastRefundMessage` queries | `getPendingMessages` / `getLastReverseSwapMessage` / `getLastRefundMessage` |
| per-index message history (`ReverseSwapMessages`, `RefundMessages`) | reconstructable off-chain from `MessageSubmitted(nonce, kind, ..., id)` events |
| queue nonces start at 0 | queue nonces start at 0; the id->nonce index mappings store nonce + 1 (`0` = "no message") |

## Layout

```
ethereum/timelock/
├── ape-config.yaml              # Ape project config (solc 0.8.24, OpenZeppelin 5.1.0)
├── contracts/
│   ├── TimeLock.sol             # the TimeLock contract
│   ├── interfaces/
│   │   ├── ITimeLock.sol
│   │   └── IBridgeRelayer.sol   # subset of the Bridge relayer API (0.8-compatible)
│   └── mocks/
│       └── BridgeRelayerMock.sol
├── scripts/
│   ├── deploy.py                # manifest-driven deployment (ape run deploy)
│   └── deployment_manifest.json
├── tests/
│   └── test_timelock.py         # mirror of the CosmWasm test-suite
└── .venv/                       # local Python env with eth-ape (not committed)
```

## Getting started

```shell
cd ethereum/timelock

# one-time setup
python3.12 -m venv .venv
.venv/bin/pip install eth-ape==0.8.52 "ape-solidity>=0.8.0" pytest
.venv/bin/ape pm install OpenZeppelin/openzeppelin-contracts@v5.1.0

# compile
.venv/bin/ape compile

# run the test suite (uses the built-in `test` provider - eth-tester / py-evm)
.venv/bin/ape test

# deploy (against a local node, e.g. anvil or ganache)
.venv/bin/ape run deploy --network ethereum:localy:ganache
```

## Deployment

The deployment is manifest-driven (see `scripts/deployment_manifest.json`): set the
`bridge` constructor parameter (address of the deployed Bridge contract) and the
`submitter`/`executor`/`canceller` role wallets for the target network, then:

```shell
.venv/bin/ape run deploy --network ethereum:mainnet
```

The deployed contract address is written back into the manifest.

> **NOTE(pb):** The TimeLock must be granted the `RELAYER_ROLE` on the Bridge (or,
> alternatively, the Bridge role setup can be updated so the TimeLock address holds it)
> for the executed messages to be accepted by the Bridge.
