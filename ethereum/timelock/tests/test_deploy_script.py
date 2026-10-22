"""Smoke test of the deployment script flow against the built-in test provider."""

import json

from ape import accounts, networks, project


def test_deploy_script_writes_manifest(tmp_path):
    # Deploy a bridge mock first so the manifest has a valid `bridge` address
    owner = accounts.test_accounts[0]
    mock = owner.deploy(project.BridgeRelayerMock)

    manifest_path = tmp_path / "manifest.json"
    manifest_path.write_text(json.dumps({
        "test": {
            "constructor_parameters": {
                "bridge": mock.address,
                "reverseSwapLockDelay": 10,
                "refundLockDelay": 20,
                "nMaxPendingMessages": 10,
            },
            "submitter_wallet": owner.address,
            "executor_wallet": owner.address,
            "canceller_wallet": owner.address,
        }
    }))

    import scripts.deploy as deploy_mod  # noqa

    # point the script to the temp manifest
    deploy_mod.DEFAULT_MANIFEST = manifest_path
    import os
    os.environ[deploy_mod.MANIFEST_PATH_ENV] = str(manifest_path)
    os.environ[deploy_mod.OUTPUT_MANIFEST_ENV] = str(manifest_path)

    deploy_mod.main()

    manifest = json.loads(manifest_path.read_text())
    assert manifest["test"]["contract_address"]
    print("deployed:", manifest["test"]["contract_address"])
