#!/usr/bin/env python
"""TrustOracle snapshot — read the standalone on-chain Trust Score for each agent.

Calls TrustOracle.allScores() (one RPC) and writes API_OUT_DIR/trust-oracle.json with each
agent's on-chain Trust Score (0-100) + letter rating, alongside the off-chain scores.json value
and the delta — proving the public oracle reproduces the dashboard number (verifiable parity).
Read-only; powers the "Trust Oracle" proof card.

Usage: API_OUT_DIR=/opt/reef/web/api python -m agents.scripts.trustoracle_snapshot
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

from agents.shared.client import get_w3, rpc_read
from agents.shared.config import DEPLOYMENTS_DIR, REPO_ROOT, load_chain

_ORACLE_ABI = [
    {
        "name": "allScores",
        "inputs": [],
        "outputs": [{"type": "uint256[]"}, {"type": "uint256[]"}],
        "stateMutability": "view",
        "type": "function",
    }
]
WAD = 10**18


def _rating(wad: int) -> str:
    # Match src/TrustOracle.sol cutoffs (WAD): AAA>=0.85, AA>=0.70, A>=0.55, BBB>=0.40.
    if wad >= 85 * 10**16:
        return "AAA"
    if wad >= 70 * 10**16:
        return "AA"
    if wad >= 55 * 10**16:
        return "A"
    if wad >= 40 * 10**16:
        return "BBB"
    return "BB"


def main() -> int:
    network = os.getenv("REEF_NETWORK", "mantle-sepolia")
    out_dir = Path(os.getenv("API_OUT_DIR", str(REPO_ROOT / "ui" / "api")))
    chain = load_chain(network)
    data = json.loads((DEPLOYMENTS_DIR / f"{network}.json").read_text(encoding="utf-8"))
    to = data.get("trustOracle")
    if not to:
        print("no trustOracle in deployments", file=sys.stderr)
        return 2

    w3 = get_w3(chain.rpc_url)
    oracle = w3.eth.contract(
        address=w3.to_checksum_address(to["address"]), abi=_ORACLE_ABI
    )
    ids, wads = rpc_read(lambda: oracle.functions.allScores().call())

    # Off-chain reference (best-effort): scores.json is written by trust_score.py in the same dir.
    off: dict[int, float] = {}
    scores_path = out_dir / "scores.json"
    if scores_path.exists():
        try:
            sj = json.loads(scores_path.read_text(encoding="utf-8"))
            off = {
                int(a["agentId"]): float(a["trustScore"]) for a in sj.get("agents", [])
            }
        except (ValueError, KeyError):
            off = {}

    agents = []
    max_delta = 0.0
    for aid, wad in zip(ids, wads):
        aid = int(aid)
        on_chain = round(int(wad) / WAD * 100, 1)
        rec = {"agentId": aid, "scoreOnChain": on_chain, "rating": _rating(int(wad))}
        if aid in off:
            delta = round(abs(on_chain - off[aid]), 2)
            rec["scoreOffChain"] = off[aid]
            rec["deltaPct"] = delta
            max_delta = max(max_delta, delta)
        agents.append(rec)
        print(f"agent {aid}: {on_chain} ({rec['rating']})")

    agents.sort(key=lambda r: r["scoreOnChain"], reverse=True)
    doc = {
        "oracle": to["address"],
        "consumer": to.get("consumer"),
        "agents": agents,
        "maxDeltaPct": max_delta,
        "updatedAt": int(time.time()),
    }
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "trust-oracle.json"
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(doc, indent=2), encoding="utf-8")
    os.replace(tmp, path)
    print(f"wrote {path} (maxDelta {max_delta}%)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
