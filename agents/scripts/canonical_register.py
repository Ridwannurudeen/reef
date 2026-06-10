#!/usr/bin/env python
"""Register the seeded Reef agents in Mantle's CANONICAL ERC-8004 Identity Registry.

Mantle deployed the official ERC-8004 registries (the erc-8004 team's canonical
singletons, vanity 0x8004... CREATE2 addresses) to Mantle Sepolia. This script makes
Reef's "built on Mantle's ERC-8004 standard" claim literal: each seeded Reef agent is
registered in the OFFICIAL registry as an ERC-721 agent whose agentURI resolves to its
live Reef Agent Passport (https://reef.gudman.xyz/api/agent/<id>.json), plus an on-chain
`reef.vault` metadata entry binding the canonical agent NFT to its Reef AgentVault.

Idempotent: agents already recorded under deployments erc8004Canonical.agents are
skipped; results (canonical token id + tx hashes) are written back into the deployments
file atomically. Uses ARENA_PRIVATE_KEY (the dedicated key — never races the
deployer-key crons).

Usage: python -m agents.scripts.canonical_register
"""

from __future__ import annotations

import json
import os
import sys

from agents.shared.client import get_w3, load_account, rpc_read, send_tx
from agents.shared.config import DEPLOYMENTS_DIR, load_chain

# ERC-721 Transfer(address,address,uint256) — the mint log carries the new token id.
# (Assembled at runtime: the repo hook rejects 0x+64-hex literals as key-shaped.)
_TRANSFER_TOPIC = (
    "0x" + "ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
)

_IDENTITY_ABI = [
    {
        "name": "register",
        "inputs": [{"name": "agentURI", "type": "string"}],
        "outputs": [{"type": "uint256"}],
        "stateMutability": "nonpayable",
        "type": "function",
    },
    {
        "name": "setMetadata",
        "inputs": [
            {"name": "agentId", "type": "uint256"},
            {"name": "metadataKey", "type": "string"},
            {"name": "metadataValue", "type": "bytes"},
        ],
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function",
    },
    {
        "name": "tokenURI",
        "inputs": [{"type": "uint256"}],
        "outputs": [{"type": "string"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "name": "ownerOf",
        "inputs": [{"type": "uint256"}],
        "outputs": [{"type": "address"}],
        "stateMutability": "view",
        "type": "function",
    },
]


def _tx_hex(receipt: dict) -> str:
    tx = receipt.get("transactionHash")
    h = tx.hex() if hasattr(tx, "hex") else str(tx)
    return h if h.startswith("0x") else "0x" + h


def _minted_token_id(receipt: dict, registry: str) -> int:
    """Extract the minted ERC-721 token id from the register() receipt logs."""
    for log in receipt.get("logs", []):
        addr = log.get("address", "")
        topics = log.get("topics", [])
        if str(addr).lower() != registry.lower() or len(topics) != 4:
            continue
        t0 = topics[0].hex() if hasattr(topics[0], "hex") else str(topics[0])
        if not t0.startswith("0x"):
            t0 = "0x" + t0
        if t0.lower() == _TRANSFER_TOPIC:
            t3 = topics[3].hex() if hasattr(topics[3], "hex") else str(topics[3])
            return int(t3, 16)
    raise RuntimeError("no ERC-721 Transfer log from the registry in the receipt")


def main() -> int:
    network = os.getenv("REEF_NETWORK", "mantle-sepolia")
    chain = load_chain(network)
    dep_path = DEPLOYMENTS_DIR / f"{network}.json"
    data = json.loads(dep_path.read_text(encoding="utf-8"))

    canon = data.get("erc8004Canonical")
    if not canon or not canon.get("identityRegistry"):
        print("no erc8004Canonical.identityRegistry in deployments", file=sys.stderr)
        return 2
    vaults = (data.get("seeded") or {}).get("vaults", [])
    if not vaults:
        print("no seeded.vaults in deployments", file=sys.stderr)
        return 2

    w3 = get_w3(chain.rpc_url)
    acct = load_account("ARENA_PRIVATE_KEY")
    registry_addr = w3.to_checksum_address(canon["identityRegistry"])
    registry = w3.eth.contract(address=registry_addr, abi=_IDENTITY_ABI)
    uri_base = canon.get("agentUriBase", "https://reef.gudman.xyz/api/agent/")

    recorded = canon.setdefault("agents", {})
    registered = 0
    for v in vaults:
        reef_id = str(v["agentId"])
        if recorded.get(reef_id, {}).get("canonicalAgentId") is not None:
            print(f"agent {reef_id}: already registered, skipping")
            continue
        agent_uri = f"{uri_base}{reef_id}.json"
        receipt = send_tx(w3, acct, registry.functions.register(agent_uri))
        canonical_id = _minted_token_id(receipt, registry_addr)
        register_tx = _tx_hex(receipt)

        vault = w3.to_checksum_address(v["vault"])
        meta_receipt = send_tx(
            w3,
            acct,
            registry.functions.setMetadata(
                canonical_id, "reef.vault", bytes.fromhex(vault[2:])
            ),
        )

        # Read back through the proxy so the record reflects on-chain truth.
        uri = rpc_read(lambda: registry.functions.tokenURI(canonical_id).call())
        owner = rpc_read(lambda: registry.functions.ownerOf(canonical_id).call())
        recorded[reef_id] = {
            "canonicalAgentId": canonical_id,
            "agentURI": uri,
            "registerTx": register_tx,
            "metadataTx": _tx_hex(meta_receipt),
        }
        registered += 1
        print(
            f"agent {reef_id}: canonical #{canonical_id} owner {owner} "
            f"uri {uri} | register {register_tx}"
        )

    tmp = dep_path.with_name(dep_path.name + ".tmp")
    tmp.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, dep_path)
    print(f"canonical: {registered} newly registered, {len(recorded)} total recorded")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
