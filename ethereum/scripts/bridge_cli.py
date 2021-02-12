#!/usr/bin/env python3

from brownie import network, accounts, Bridge as Contract
import json
import os
import sys


def main():
    base_dir = os.path.dirname(os.path.abspath(__file__))
    deploument_manifest_filename = "deployment_manifest.json"
    deployment_manifest_path = os.path.join(base_dir, deploument_manifest_filename)

    priv_key_path_env_var = "PRIV_KEY_PATH"
    if priv_key_path_env_var in os.environ:
        # IF env var to key file is provided
        private_key_file = os.environ.get(priv_key_path_env_var)
        owner = accounts.load(private_key_file)
    else:
        # If not use default accounts
        owner = accounts[0]

    print(f"key: {owner}")
    with open(deployment_manifest_path, mode="r") as f:
        manifest = json.load(f)
        network_manif = manifest[network.show_active()]
        contract_manif = network_manif["Bridge"]

    print(f'network manifest: {network_manif}')

    print(f'{sys.argv}')