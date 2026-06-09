#!/usr/bin/env python
"""Allocator snapshot — the trust-weighted capital allocation, read straight from chain.

Reads the on-chain Allocator for the active mandate and, per agent, its on-chain Trust
Score, whether it *qualifies* under the mandate, and the capital it is allocated. Writes
API_OUT_DIR/allocator.json. Read-only — safe on any cadence. Powers the dashboard
"Allocator mandate" panel and the transparency proof card: an institutional LP picks a
mandate (risk profile) and capital flows to qualifying agents weighted by verifiable trust.

Usage: API_OUT_DIR=/opt/reef/web/api python -m agents.scripts.allocator_snapshot
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

from agents.shared.client import get_w3, rpc_read, vault_contract
from agents.shared.config import DEPLOYMENTS_DIR, REPO_ROOT, load_chain

_ALLOCATOR_ABI = [
    {
        "name": "previewTargets",
        "inputs": [],
        "outputs": [
            {"type": "address[]"},
            {"type": "uint256[]"},
            {"type": "bool[]"},
            {"type": "uint256[]"},
        ],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "name": "trustScoreOf",
        "inputs": [{"type": "address"}],
        "outputs": [{"type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "name": "totalAssets",
        "inputs": [],
        "outputs": [{"type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "name": "activeMandate",
        "inputs": [],
        "outputs": [{"type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "name": "mandateCount",
        "inputs": [],
        "outputs": [{"type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "name": "mandates",
        "inputs": [{"type": "uint256"}],
        "outputs": [{"type": "string"}, {"type": "uint256"}, {"type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    },
]


def _pct(score_wad: int) -> float:
    # Trust Score is WAD (1e18 == 100/100); render as a 0-100 figure like the off-chain rating.
    # FLOOR to 1 decimal (not round) so a displayed score never crosses a mandate threshold the
    # on-chain contract doesn't — keeps the dashboard's client-side qualification == on-chain.
    return (int(score_wad) // 10**15) / 10


def _mandate(alloc, i: int) -> dict:
    name, min_trust, cap = rpc_read(lambda i=i: alloc.functions.mandates(i).call())
    return {
        "id": i,
        "name": name,
        "minTrustScorePct": _pct(int(min_trust)),
        "maxWeightBps": int(cap),
    }


def main() -> int:
    network = os.getenv("REEF_NETWORK", "mantle-sepolia")
    out_dir = Path(os.getenv("API_OUT_DIR", str(REPO_ROOT / "ui" / "api")))
    chain = load_chain(network)
    data = json.loads((DEPLOYMENTS_DIR / f"{network}.json").read_text(encoding="utf-8"))
    alloc_meta = data.get("allocator")
    if not alloc_meta:
        print("no allocator in deployments", file=sys.stderr)
        return 2
    vaults = data.get("seeded", {}).get("vaults", [])
    by_vault = {v["vault"].lower(): int(v["agentId"]) for v in vaults}

    w3 = get_w3(chain.rpc_url)
    alloc = w3.eth.contract(
        address=w3.to_checksum_address(alloc_meta["address"]), abi=_ALLOCATOR_ABI
    )

    active = rpc_read(lambda: alloc.functions.activeMandate().call())
    count = rpc_read(lambda: alloc.functions.mandateCount().call())
    mandates = [_mandate(alloc, i) for i in range(count)]
    total = int(rpc_read(lambda: alloc.functions.totalAssets().call()))
    vaddrs, scores, qualified, targets = rpc_read(
        lambda: alloc.functions.previewTargets().call()
    )

    agents = []
    for addr, score, ok, target in zip(vaddrs, scores, qualified, targets):
        vc = vault_contract(w3, addr)
        nav = int(rpc_read(lambda vc=vc: vc.functions.nav().call()))
        agents.append(
            {
                "agentId": by_vault.get(addr.lower()),
                "vault": addr,
                "trustScorePct": _pct(int(score)),
                "qualified": bool(ok),
                "targetE18": str(int(target)),
                "targetWeightBps": (int(target) * 10_000 // total) if total else 0,
                "navE18": str(nav),
            }
        )
    agents.sort(key=lambda a: a["trustScorePct"], reverse=True)

    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "allocator.json"
    doc = {
        "allocator": alloc_meta["address"],
        "activeMandate": int(active),
        "mandates": mandates,
        "totalAssetsE18": str(total),
        "agents": agents,
        "updatedAt": int(time.time()),
    }
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(doc, indent=2), encoding="utf-8")
    os.replace(tmp, path)
    am = mandates[active] if active < len(mandates) else None
    print(
        f"mandate: {am['name'] if am else '?'} | qualifying {sum(a['qualified'] for a in agents)}/{len(agents)} | total {total / 1e18:.2f}"
    )
    for a in agents:
        print(
            f"  agent {a['agentId']}: {a['trustScorePct']} {'QUALIFIED' if a['qualified'] else 'excluded'} target {int(a['targetE18']) / 1e18:.2f}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
