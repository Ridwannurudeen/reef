#!/usr/bin/env python
"""Deploy and self-list one Reef BYOA agent on Mantle Sepolia."""
# ruff: noqa: E402

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path
from typing import Any

try:
    from dotenv import load_dotenv
except ImportError:  # pragma: no cover - dotenv is optional
    load_dotenv = None

HERE = Path(__file__).resolve().parent
REEF_ROOT = Path(os.getenv("REEF_ROOT", HERE.parent)).resolve()
sys.path.insert(0, str(REEF_ROOT))

from eth_utils import keccak

from agents.shared.client import (
    get_w3,
    load_abi,
    load_account,
    load_bytecode,
    rpc_read,
    send_tx,
)
from agents.shared.config import DEPLOYMENTS_DIR, load_chain
from agents.shared.receipt import sign_receipt

if load_dotenv:
    load_dotenv(REEF_ROOT / ".env")
    load_dotenv(HERE / ".env")


def contract(w3, address: str, name: str):
    return w3.eth.contract(address=w3.to_checksum_address(address), abi=load_abi(name))


def deploy_contract(w3, account, name: str, args: list[Any]):
    factory = w3.eth.contract(abi=load_abi(name), bytecode=load_bytecode(name))
    receipt = send_tx(w3, account, factory.constructor(*args))
    address = receipt.get("contractAddress")
    if not address:
        raise RuntimeError(f"{name} deployment did not return a contract address")
    print(f"{name}: {address}")
    return w3.to_checksum_address(address)


def env_int(name: str, default: int) -> int:
    raw = os.getenv(name)
    return default if raw in (None, "") else int(raw)


def env_optional_int(name: str) -> int | None:
    raw = os.getenv(name)
    return None if raw in (None, "") else int(raw)


def load_deployment(network: str) -> dict[str, Any]:
    path = DEPLOYMENTS_DIR / f"{network}.json"
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> int:
    network = os.getenv("REEF_NETWORK", "mantle-sepolia")
    chain = load_chain(network)
    data = load_deployment(network)
    seeded = data["seeded"]
    reef = data["reef"]

    asset = seeded["asset"]
    identity_addr = reef["AgentIdentity"]
    index_addr = reef["AgentIndex"]
    bond_addr = seeded["reputationBond"]["address"]
    guard_addr = data["reefGuard"]["address"]

    bond_amount = env_int("BOND_AMOUNT_WEI", 10 * 10**18)
    seed_amount = env_int("SEED_AMOUNT_WEI", 10**18)
    initial_yield = env_int("INITIAL_YIELD_WEI", 10**17)
    existing_agent_id = env_optional_int("AGENT_ID")
    period = env_int("RECEIPT_PERIOD_S", 600)
    out_path = Path(os.getenv("AGENT_CONFIG", HERE / "agent.json"))

    w3 = get_w3(chain.rpc_url)
    account = load_account()
    print(f"operator: {account.address}")

    identity = contract(w3, identity_addr, "AgentIdentity")
    index = contract(w3, index_addr, "AgentIndex")
    token = contract(w3, asset, "MockERC20")
    bond = contract(w3, bond_addr, "ReputationBond")

    if existing_agent_id is None:
        reg_receipt = send_tx(w3, account, identity.functions.register())
        events = identity.events.AgentRegistered().process_receipt(reg_receipt)
        if not events:
            raise RuntimeError("AgentRegistered event missing")
        agent_id = int(events[0]["args"]["agentId"])
    else:
        wallet = rpc_read(
            lambda: identity.functions.getAgentWallet(existing_agent_id).call()
        )
        if wallet.lower() != account.address.lower():
            raise RuntimeError(
                f"AGENT_ID {existing_agent_id} belongs to {wallet}, not {account.address}"
            )
        agent_id = existing_agent_id
    print(f"agentId: {agent_id}")

    registry_addr = deploy_contract(w3, account, "AdapterRegistry", [])
    vault_addr = deploy_contract(
        w3,
        account,
        "AgentVault",
        [
            w3.to_checksum_address(asset),
            agent_id,
            w3.to_checksum_address(identity_addr),
            registry_addr,
        ],
    )
    adapter_addr = deploy_contract(
        w3,
        account,
        "MockStrategyAdapter",
        [w3.to_checksum_address(asset), vault_addr],
    )

    registry = contract(w3, registry_addr, "AdapterRegistry")
    vault = contract(w3, vault_addr, "AgentVault")

    send_tx(w3, account, identity.functions.setReputationSource(agent_id, vault_addr))
    send_tx(w3, account, registry.functions.approveAdapter(adapter_addr))
    send_tx(w3, account, vault.functions.approveStrategy(adapter_addr))

    send_tx(
        w3, account, token.functions.mint(account.address, seed_amount + bond_amount)
    )
    send_tx(w3, account, token.functions.approve(vault_addr, seed_amount))
    send_tx(w3, account, vault.functions.deposit(seed_amount))
    send_tx(w3, account, vault.functions.deployToStrategy(adapter_addr, seed_amount))
    if initial_yield > 0:
        send_tx(w3, account, token.functions.mint(adapter_addr, initial_yield))
    send_tx(
        w3,
        account,
        vault.functions.recallFromStrategy(adapter_addr, seed_amount + initial_yield),
    )

    reasoning = (
        "Initial BYOA proof: seed capital entered the approved strategy, "
        "testnet yield was realized back to the vault, and this receipt binds "
        "the rationale to the on-chain evidence hash."
    )
    evidence = keccak(reasoning.encode("utf-8"))
    seq = rpc_read(lambda: vault.functions.nextReceiptSeq().call())
    receipt_args = sign_receipt(
        account.key,
        vault=vault_addr,
        chain_id=w3.eth.chain_id,
        agent_id=agent_id,
        seq=seq,
        evidence_hash=evidence,
        claimed_delta=initial_yield,
        period=period,
    )
    receipt = send_tx(w3, account, vault.functions.publishReceipt(*receipt_args))
    print(f"receipt: {w3.to_hex(receipt['transactionHash'])}")

    send_tx(w3, account, token.functions.approve(bond_addr, bond_amount))
    send_tx(w3, account, bond.functions.postBond(agent_id, bond_amount))
    send_tx(w3, account, index.functions.selfListVault(vault_addr))

    config = {
        "network": network,
        "chainId": w3.eth.chain_id,
        "rpc": chain.rpc_url,
        "operator": account.address,
        "agentId": agent_id,
        "asset": w3.to_checksum_address(asset),
        "identity": w3.to_checksum_address(identity_addr),
        "index": w3.to_checksum_address(index_addr),
        "bond": w3.to_checksum_address(bond_addr),
        "reefGuard": w3.to_checksum_address(guard_addr),
        "registry": registry_addr,
        "vault": vault_addr,
        "strategyAdapter": adapter_addr,
        "strategyKind": "mock",
        "strategyLabel": "Mock testnet yield adapter",
        "receiptTx": w3.to_hex(receipt["transactionHash"]),
        "deployedAt": int(time.time()),
    }
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(config, indent=2), encoding="utf-8")
    print(f"wrote {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
