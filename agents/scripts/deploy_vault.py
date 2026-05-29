"""One-shot: deploy an AgentVault for a given agentId.

Usage:
    python -m agents.scripts.deploy_vault --agent-id <id> --asset <erc20_addr>

Reads PRIVATE_KEY + chain config from .env. Constructor args:
    AgentVault(address asset_, uint256 agentId_, address identity_)

Prints the deployed vault address on success.
"""

from __future__ import annotations

import argparse
import logging
import sys

from web3 import Web3

from agents.shared.client import get_w3, load_abi, load_account, load_bytecode
from agents.shared.config import load_chain


def main() -> int:
    parser = argparse.ArgumentParser(description="Deploy an AgentVault for an agentId.")
    parser.add_argument(
        "--agent-id",
        type=int,
        required=True,
        help="agentId from AgentIdentity.register",
    )
    parser.add_argument(
        "--asset",
        type=str,
        required=True,
        help="ERC-20 asset address (e.g. MockUSDC on Sepolia or USDY on mainnet)",
    )
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s: %(message)s"
    )
    log = logging.getLogger("deploy_vault")

    chain = load_chain()
    w3 = get_w3(chain.rpc_url)
    account = load_account()

    asset_addr = Web3.to_checksum_address(args.asset)
    identity_addr = Web3.to_checksum_address(chain.identity_address)

    abi = load_abi("AgentVault")
    bytecode = load_bytecode("AgentVault")
    Vault = w3.eth.contract(abi=abi, bytecode=bytecode)

    log.info(
        "deploying AgentVault(asset=%s, agentId=%d, identity=%s) from %s",
        asset_addr,
        args.agent_id,
        identity_addr,
        account.address,
    )

    constructor = Vault.constructor(asset_addr, args.agent_id, identity_addr)
    nonce = w3.eth.get_transaction_count(account.address)
    tx: dict = {
        "from": account.address,
        "nonce": nonce,
        "chainId": w3.eth.chain_id,
    }
    base_fee = w3.eth.get_block("latest").get("baseFeePerGas")
    if base_fee is not None:
        priority = w3.to_wei(1, "gwei")
        tx["maxPriorityFeePerGas"] = priority
        tx["maxFeePerGas"] = base_fee * 2 + priority
    else:
        tx["gasPrice"] = w3.eth.gas_price

    est = constructor.estimate_gas({"from": account.address})
    tx["gas"] = int(est * 5 // 4)

    built = constructor.build_transaction(tx)
    signed = account.sign_transaction(built)
    raw = getattr(signed, "raw_transaction", None) or signed.rawTransaction
    tx_hash = w3.eth.send_raw_transaction(raw)
    log.info("deploy tx submitted: %s", tx_hash.hex())
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=300)

    if receipt["status"] != 1:
        log.error("deploy reverted, tx=%s", tx_hash.hex())
        return 1

    vault_addr = receipt["contractAddress"]
    log.info("AgentVault deployed at %s (gas used=%d)", vault_addr, receipt["gasUsed"])
    print(vault_addr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
