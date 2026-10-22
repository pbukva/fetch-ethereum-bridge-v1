#!/usr/bin/env python3

"""Deployment of the TimeLock contract.

Mirrors the manifest-driven flow of the existing brownie-based `scripts/deploy_bridge.py`:
constructor parameters & role wallets are read from a per-network manifest section,
the deployed address is written back into it.
"""

import json
import os
from pathlib import Path

from ape import accounts, networks, project
from eth_utils import keccak

MANIFEST_PATH_ENV = "ETH_CONTRACT_DEPLOYMENT_MANIFEST_PATH"
OUTPUT_MANIFEST_ENV = "ETH_CONTRACT_DEPLOYMENT_MANIFEST_PATH_OUTPUT"
DEFAULT_MANIFEST = Path(__file__).parent / "deployment_manifest.json"

# Role identifiers (keccak256 of the role name, mirror of the Solidity constants)
SUBMIT_ROLE = keccak(text="SUBMIT_ROLE")
EXECUTE_ROLE = keccak(text="EXECUTE_ROLE")
CANCEL_ROLE = keccak(text="CANCEL_ROLE")


def load_manifest() -> tuple[dict, dict]:
    path = Path(os.environ.get(MANIFEST_PATH_ENV, DEFAULT_MANIFEST))
    manifest = json.loads(path.read_text()) if path.exists() else {}
    network = networks.provider.name
    network_manifest = manifest.setdefault(network, {})
    return manifest, network_manifest


def save_manifest(manifest: dict):
    path = Path(os.environ.get(OUTPUT_MANIFEST_ENV, os.environ.get(MANIFEST_PATH_ENV, DEFAULT_MANIFEST)))
    path.write_text(json.dumps(manifest, indent=4) + "\n")
    print(f"manifest saved to: {path}")


def get_deployer(network_manifest: dict):
    """Deployer account: either a test account (development) or the first keyfile account."""
    deployer_address = network_manifest.get("deployer_address")
    if deployer_address:
        return accounts.load(deployer_address)
    if networks.provider.name == "test" or networks.provider.chain_id == 1337:
        return accounts.test_accounts[0]
    # live network: use the first unlocked keyfile account
    acct = accounts.containers["ethereum"].accounts[0]
    print(f"Using account: {acct.address}")
    return acct


def main():
    manifest, network_manifest = load_manifest()
    deployer = get_deployer(network_manifest)

    params = network_manifest.setdefault("constructor_parameters", {})
    bridge = params.get("bridge", "")
    submitter_wallet = network_manifest.get("submitter_wallet", deployer.address)
    executor_wallet = network_manifest.get("executor_wallet", deployer.address)
    canceller_wallet = network_manifest.get("canceller_wallet", deployer.address)

    if not bridge:
        raise SystemExit(
            f"The 'bridge' constructor parameter is not set in the manifest "
            f"({'development' if networks.provider.name == 'test' else networks.provider.name})."
        )

    contract = deployer.deploy(
        project.TimeLock,
        bridge,
        params.get("reverseSwapLockDelay", 10),
        params.get("refundLockDelay", 20),
        params.get("nMaxPendingMessages", 10),
        deployer.address,  # admin
    )
    print(f"TimeLock deployed at: {contract.address}")

    # Grant the service roles (admin stays with the deployer unless configured otherwise)
    contract.grantRole(SUBMIT_ROLE, submitter_wallet, sender=deployer)
    contract.grantRole(EXECUTE_ROLE, executor_wallet, sender=deployer)
    contract.grantRole(CANCEL_ROLE, canceller_wallet, sender=deployer)

    network_manifest["contract_address"] = contract.address
    network_manifest["deployer_address"] = deployer.address
    save_manifest(manifest)


if __name__ == "__main__":
    main()
