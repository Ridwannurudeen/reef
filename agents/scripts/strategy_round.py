#!/usr/bin/env python
"""Competing-strategies round: five personas decide from the same real inputs, scored over time.

Each run: fetch the shared live inputs (CoinGecko spot/momentum, Allora ETH prediction,
Nansen smart-money flow) once, then for each seeded vault run its persona to get a
differentiated decision. Before overwriting, score the PREVIOUS round's calls against the
realised ETH move since then and accumulate a per-strategy accuracy scoreboard, so the
leaderboard is a genuine benchmark of which on-chain AI strategy is right most often.

Writes API_OUT_DIR/agents.json: {inputs, agents:[...], scoreboard:{...}, round, updatedAt}.

Usage: API_OUT_DIR=/opt/reef/web/api python -m agents.scripts.strategy_round
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

from agents.shared.allora import fetch_eth_prediction
from agents.shared.client import get_w3, rpc_read, vault_contract
from agents.shared.config import DEPLOYMENTS_DIR, REPO_ROOT, load_chain
from agents.shared.nansen import fetch_smart_money_flow
from agents.shared.personas import PERSONAS
from agents.shared.signal import fetch_signal


def _score_prev(prev: dict, spot_now: float) -> dict:
    """Score the previous round's decisions against the realised ETH move, accumulate."""
    board = prev.get("scoreboard", {}) if prev else {}
    prev_spot = (prev.get("inputs") or {}).get("spot") if prev else None
    if not prev or not prev_spot or not spot_now:
        return board
    move = (spot_now - prev_spot) / prev_spot
    for a in prev.get("agents", []):
        name = a.get("strategy")
        if not name:
            continue
        rec = board.setdefault(name, {"rounds": 0, "correct": 0})
        action = a.get("action")
        if action == "increase":
            correct = move > 0
        elif action == "decrease":
            correct = move < 0
        else:  # hold is "correct" when the market was roughly flat
            correct = abs(move) < 0.003
        rec["rounds"] += 1
        rec["correct"] += 1 if correct else 0
        rec["accuracyPct"] = round(100 * rec["correct"] / rec["rounds"], 1)
    return board


def main() -> int:
    network = os.getenv("REEF_NETWORK", "mantle-sepolia")
    out_dir = Path(os.getenv("API_OUT_DIR", str(REPO_ROOT / "ui" / "api")))
    chain = load_chain(network)
    data = json.loads((DEPLOYMENTS_DIR / f"{network}.json").read_text(encoding="utf-8"))
    vaults = {
        int(v["agentId"]): v["vault"] for v in data.get("seeded", {}).get("vaults", [])
    }
    if not vaults:
        print("no seeded vaults", file=sys.stderr)
        return 2

    signal = fetch_signal("ETH")
    prediction = fetch_eth_prediction()
    flow = fetch_smart_money_flow()
    w3 = get_w3(chain.rpc_url)

    agents = []
    for agent_id, (name, edge, fn) in PERSONAS.items():
        nav = hwm = 10**18
        vault_addr = vaults.get(agent_id)
        if vault_addr:
            try:
                vc = vault_contract(w3, vault_addr)
                nav = rpc_read(lambda vc=vc: vc.functions.nav().call())
                hwm = rpc_read(lambda vc=vc: vc.functions.highWaterNav().call())
            except Exception as e:  # noqa: BLE001 - keep the round going
                print(f"agent {agent_id} read failed: {e}", file=sys.stderr)
        ctx = {
            "signal": signal,
            "prediction": prediction,
            "flow": flow,
            "agent_id": agent_id,
            "nav": nav,
            "hwm": hwm,
        }
        d = fn(ctx)
        agents.append(
            {
                "agentId": agent_id,
                "strategy": name,
                "edge": edge,
                "action": d.action,
                "navDeltaBps": d.nav_delta_bps,
                "reasoning": d.reasoning,
                "source": d.source,
                "navE18": str(nav),
            }
        )
        print(f"agent {agent_id} {name}: {d.action} {d.nav_delta_bps}bps [{d.source}]")

    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "agents.json"
    prev = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    spot = signal["price"] if signal else None
    scoreboard = _score_prev(prev, spot)
    inputs = {
        "spot": spot,
        "momentumPct": signal["change24hPct"] if signal else None,
        "alloraPred": prediction["predictedPrice"] if prediction else None,
        "nansen": flow["label"] if flow else None,
    }
    doc = {
        "inputs": inputs,
        "agents": agents,
        "scoreboard": scoreboard,
        "round": (prev.get("round", 0) + 1) if prev else 1,
        "updatedAt": int(time.time()),
    }
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(doc, indent=2), encoding="utf-8")
    os.replace(tmp, path)
    print(
        f"round {doc['round']}: {len(agents)} agents, scoreboard {len(scoreboard)} strategies"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
