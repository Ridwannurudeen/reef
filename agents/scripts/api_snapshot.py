#!/usr/bin/env python
"""Reef public API — snapshot on-chain state to static JSON (the agent-intelligence layer).

Reads the live index / identity / vaults / bond / seasons and writes a single
`reef.json` (meta + index + ranked agents + season standings) to API_OUT_DIR
(default <repo>/ui/api). Served statically (e.g. reef.gudman.xyz/api/reef.json) and
refreshed by cron, it makes Reef queryable: top agents, reputation, receipts,
season winners — no backend required.

Usage (from repo root):
    python -m agents.scripts.api_snapshot
    API_OUT_DIR=/opt/reef/web/api python -m agents.scripts.api_snapshot
"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path

from web3 import Web3

from agents.shared.client import (
    get_w3,
    identity_contract,
    index_contract,
    load_abi,
    rpc_read,
    vault_contract,
)
from agents.shared.config import DEPLOYMENTS_DIR, REPO_ROOT, load_chain

_SIDE = {0: "Human", 1: "AI"}


def main() -> int:
    network = os.getenv("REEF_NETWORK", "mantle-sepolia")
    out_dir = Path(os.getenv("API_OUT_DIR", str(REPO_ROOT / "ui" / "api")))
    out_dir.mkdir(parents=True, exist_ok=True)

    chain = load_chain(network)
    data = json.loads((DEPLOYMENTS_DIR / f"{network}.json").read_text(encoding="utf-8"))
    reef = data["reef"]
    seeded = data.get("seeded", {})
    w3 = get_w3(chain.rpc_url)

    idx = index_contract(w3, reef["AgentIndex"])
    idn = identity_contract(w3, reef["AgentIdentity"])
    bond_addr = seeded.get("reputationBond", {}).get("address", "")
    season_addr = seeded.get("seasons", {}).get("address", "")
    bond = (
        w3.eth.contract(
            address=Web3.to_checksum_address(bond_addr), abi=load_abi("ReputationBond")
        )
        if _nz(bond_addr)
        else None
    )
    seasons = (
        w3.eth.contract(
            address=Web3.to_checksum_address(season_addr), abi=load_abi("Seasons")
        )
        if _nz(season_addr)
        else None
    )

    alloc = rpc_read(lambda: idx.functions.getAllocation().call())
    agents = []
    for a in alloc:
        agent_id, vault_addr, weight_bps, deployed = a[0], a[1], a[2], a[3]
        vc = vault_contract(w3, vault_addr)
        cum, count = rpc_read(lambda: idn.functions.getSummary(agent_id).call())
        agents.append(
            {
                "agentId": agent_id,
                "vault": vault_addr,
                "weightBps": weight_bps,
                "deployed": str(deployed),
                "nav": str(rpc_read(lambda: vc.functions.nav().call())),
                "highWaterNav": str(
                    rpc_read(lambda: vc.functions.highWaterNav().call())
                ),
                "reputation": str(cum),
                "receiptCount": count,
                "lastReceiptAt": rpc_read(lambda: vc.functions.lastReceiptAt().call()),
                "bond": str(rpc_read(lambda: bond.functions.bondOf(agent_id).call()))
                if bond
                else "0",
                "seasonScore": str(
                    rpc_read(lambda: seasons.functions.scoreOf(0, agent_id).call())
                )
                if seasons
                else "0",
                "side": _SIDE.get(
                    rpc_read(lambda: seasons.functions.sideOf(0, agent_id).call()), "?"
                )
                if seasons
                else "?",
            }
        )
    agents.sort(key=lambda x: int(x["reputation"]), reverse=True)

    season = None
    if seasons:
        hw = rpc_read(lambda: seasons.functions.winner(0, 0).call())
        aw = rpc_read(lambda: seasons.functions.winner(0, 1).call())
        season = {
            "seasonId": 0,
            "humanWinner": {"agentId": hw[0], "score": str(hw[1])},
            "aiWinner": {"agentId": aw[0], "score": str(aw[1])},
        }

    snapshot = {
        "meta": {
            "network": chain.name,
            "chainId": chain.chain_id,
            "updatedAt": int(time.time()),
            "contracts": {
                "AgentIdentity": reef["AgentIdentity"],
                "AgentIndex": reef["AgentIndex"],
                "ReputationBond": bond_addr,
                "Seasons": season_addr,
            },
        },
        "index": {
            "totalAssets": str(rpc_read(lambda: idx.functions.totalAssets().call())),
            "totalSupply": str(rpc_read(lambda: idx.functions.totalSupply().call())),
            "vaultCount": rpc_read(lambda: idx.functions.vaultCount().call()),
        },
        "agents": agents,
        "season": season,
    }

    (out_dir / "reef.json").write_text(json.dumps(snapshot, indent=2), encoding="utf-8")
    print(f"wrote {out_dir / 'reef.json'} ({len(agents)} agents)")
    return 0


def _nz(addr: str) -> bool:
    return bool(addr) and int(addr, 16) != 0


if __name__ == "__main__":
    raise SystemExit(main())
