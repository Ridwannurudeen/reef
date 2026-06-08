#!/usr/bin/env python
"""Reef Trust Score — a Moody's-style credit rating for autonomous agents.

Computes one 0-100 score per agent from data already emitted on-chain, so the
ranking is verifiable, not asserted:
  - reputation  (40%) : ERC-8004 cumulative NAV-derived reputation (vs cohort best)
  - freshness   (20%) : how recently the agent published a signed receipt
  - drawdown    (20%) : NAV vs its all-time high-water mark (less drawdown = better)
  - bond        (20%) : skin-in-the-game posted in ReputationBond

Writes API_OUT_DIR/scores.json: per-agent {trustScore, rating, components, bonded, ...}.
Read-only (no txs) — safe to run on any cadence. Powers the Agent Passport + the
trust-weighted Allocator.

Usage: API_OUT_DIR=/opt/reef/web/api python -m agents.scripts.trust_score
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

from agents.shared.client import get_w3, identity_contract, rpc_read, vault_contract
from agents.shared.config import DEPLOYMENTS_DIR, REPO_ROOT, load_chain

_BOND_ABI = [
    {
        "name": "bondOf",
        "inputs": [{"type": "uint256"}],
        "outputs": [{"type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    }
]

FRESH_WINDOW_S = 86_400  # receipt older than 24h scores 0 on freshness
BOND_TARGET = 50 * 10**18  # full marks at the cohort's standard 50e18 bond
WEIGHTS = {"reputation": 0.40, "freshness": 0.20, "drawdown": 0.20, "bond": 0.20}


def _rating(score: float) -> str:
    if score >= 85:
        return "AAA"
    if score >= 70:
        return "AA"
    if score >= 55:
        return "A"
    if score >= 40:
        return "BBB"
    return "BB"


def main() -> int:
    network = os.getenv("REEF_NETWORK", "mantle-sepolia")
    out_dir = Path(os.getenv("API_OUT_DIR", str(REPO_ROOT / "ui" / "api")))
    chain = load_chain(network)
    data = json.loads((DEPLOYMENTS_DIR / f"{network}.json").read_text(encoding="utf-8"))
    vaults = data.get("seeded", {}).get("vaults", [])
    if not vaults:
        print("no seeded vaults", file=sys.stderr)
        return 2
    bond_addr = (data.get("seeded", {}).get("reputationBond") or {}).get("address")

    w3 = get_w3(chain.rpc_url)
    identity = identity_contract(w3, data["reef"]["AgentIdentity"])
    bond = (
        w3.eth.contract(address=w3.to_checksum_address(bond_addr), abi=_BOND_ABI)
        if bond_addr
        else None
    )
    now = int(time.time())

    raw = []
    for v in vaults:
        aid = int(v["agentId"])
        vc = vault_contract(w3, v["vault"])
        cum, _cnt = rpc_read(
            lambda vc=vc, aid=aid: identity.functions.getSummary(aid).call()
        )
        nav = rpc_read(lambda vc=vc: vc.functions.nav().call())
        hwm = rpc_read(lambda vc=vc: vc.functions.highWaterNav().call())
        last = rpc_read(lambda vc=vc: vc.functions.lastReceiptAt().call())
        bonded = (
            rpc_read(lambda aid=aid: bond.functions.bondOf(aid).call()) if bond else 0
        )
        raw.append(
            {
                "agentId": aid,
                "vault": v["vault"],
                "rep": max(0, int(cum)),
                "nav": int(nav),
                "hwm": int(hwm),
                "last": int(last),
                "bond": int(bonded),
            }
        )

    max_rep = max((r["rep"] for r in raw), default=0) or 1
    agents = []
    for r in raw:
        rep_c = r["rep"] / max_rep
        age = max(0, now - r["last"]) if r["last"] else FRESH_WINDOW_S
        fresh_c = max(0.0, 1.0 - age / FRESH_WINDOW_S)
        dd = max(0.0, (r["hwm"] - r["nav"]) / r["hwm"]) if r["hwm"] else 0.0
        dd_c = max(0.0, 1.0 - min(dd * 5, 1.0))  # 20% drawdown -> 0
        bond_c = min(1.0, r["bond"] / BOND_TARGET)
        score = 100 * (
            WEIGHTS["reputation"] * rep_c
            + WEIGHTS["freshness"] * fresh_c
            + WEIGHTS["drawdown"] * dd_c
            + WEIGHTS["bond"] * bond_c
        )
        agents.append(
            {
                "agentId": r["agentId"],
                "vault": r["vault"],
                "trustScore": round(score, 1),
                "rating": _rating(score),
                "bonded": r["bond"] > 0,
                "components": {
                    "reputation": round(rep_c, 3),
                    "freshness": round(fresh_c, 3),
                    "drawdown": round(dd_c, 3),
                    "bond": round(bond_c, 3),
                },
                "receiptAgeSec": age,
                "navE18": str(r["nav"]),
                "reputationE18": str(r["rep"]),
                "bondE18": str(r["bond"]),
            }
        )

    agents.sort(key=lambda a: a["trustScore"], reverse=True)
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "scores.json"
    doc = {"agents": agents, "weights": WEIGHTS, "updatedAt": now}
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(doc, indent=2), encoding="utf-8")
    os.replace(tmp, path)
    for a in agents:
        print(
            f"agent {a['agentId']}: {a['trustScore']} ({a['rating']}) bonded={a['bonded']}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
