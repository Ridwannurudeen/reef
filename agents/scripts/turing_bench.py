#!/usr/bin/env python
"""Financial Turing Test — one risk-adjusted benchmark of AI strategies vs a human baseline.

The hackathon's namesake: can autonomous AI beat passively holding the asset, on a risk-adjusted
basis? This unifies the three scattered scoreboards (strategy_round accuracy, strategy_benchmark
ROI/drawdown, allora_bench) onto ONE paper-trading basis. Every competitor — the 5 strategy
personas, Allora's prediction, and a Human buy-and-hold baseline — takes a directional position
each round; we mark it to the realised ETH move and accumulate hit-rate, ROI, max drawdown and a
Sharpe-like risk-adjusted return. Pure transform over agents.json + allora-bench.json (no chain,
no key). Idempotent: the paper book only advances when a new strategy round is observed.

Writes API_OUT_DIR/turing-bench.json: {asset, inputs, competitors:[...], updatedAt}.

Usage: API_OUT_DIR=/opt/reef/web/api python -m agents.scripts.turing_bench
"""

from __future__ import annotations

import json
import os
import statistics
import sys
import time
from pathlib import Path

from agents.shared.config import REPO_ROOT

MAX_SAMPLES = 240  # capped paper-NAV / returns history per competitor
FLAT_BAND = (
    0.003  # |move| below this counts the round as "flat" (matches strategy_round)
)


def _load(d: Path, name: str):
    p = d / name
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except (ValueError, OSError):  # missing / partial feed
        return None


def _position(action: str) -> int:
    """A directional call -> a unit paper position: long (+1), short/cash (-1), flat (0)."""
    if action == "increase":
        return 1
    if action == "decrease":
        return -1
    return 0


def _metrics(series: list[float], returns: list[float], hits: dict) -> dict:
    nav = series[-1] if series else 1.0
    roi_bps = round((nav - 1.0) * 10_000.0, 1) if series else None
    max_dd = None
    if len(series) >= 2:
        peak = series[0]
        max_dd = 0.0
        for v in series:
            if v > peak:
                peak = v
            if peak > 0:
                dd = (peak - v) / peak * 10_000.0
                if dd > max_dd:
                    max_dd = dd
        max_dd = round(max_dd, 1)
    sharpe = None
    if len(returns) >= 2:
        sd = statistics.pstdev(returns)
        if sd > 0:
            sharpe = round(statistics.fmean(returns) / sd, 3)
    rounds = hits.get("rounds", 0)
    hit_rate = round(100.0 * hits.get("correct", 0) / rounds, 1) if rounds else None
    return {
        "navE18": str(int(nav * 10**18)),
        "paperRoiBps": roi_bps,
        "maxDrawdownBps": max_dd,
        "sharpe": sharpe,
        "hitRatePct": hit_rate,
        "rounds": rounds,
        "samples": len(series),
    }


def main() -> int:
    out_dir = Path(os.getenv("API_OUT_DIR", str(REPO_ROOT / "ui" / "api")))
    agents_doc = _load(out_dir, "agents.json")
    if not agents_doc or not agents_doc.get("agents"):
        print("no agents.json feed; nothing to benchmark", file=sys.stderr)
        return 2
    allora = _load(out_dir, "allora-bench.json") or {}
    prev = _load(out_dir, "turing-bench.json") or {}
    state = prev.get("_state", {})

    spot = (agents_doc.get("inputs") or {}).get("spot")
    cur_round = int(agents_doc.get("round", 0))
    now = int(time.time())

    # --- Define this round's competitors and their directional positions ---
    # 5 strategy personas (from the live round) + Allora (implied direction) + Human (buy-and-hold).
    comp = {}  # name -> {kind, edge, position}
    for a in agents_doc["agents"]:
        name = a.get("strategy")
        if not name:
            continue
        comp[name] = {
            "kind": "ai",
            "edge": a.get("edge", ""),
            "position": _position(a.get("action")),
        }
    implied_bps = (allora.get("current") or {}).get("impliedBps")
    if implied_bps is not None:
        ap = 1 if implied_bps > 0 else (-1 if implied_bps < 0 else 0)
        comp["Allora"] = {
            "kind": "ai",
            "edge": "decentralized inference prediction",
            "position": ap,
        }
    comp["Human (buy & hold)"] = {
        "kind": "human",
        "edge": "passively holds ETH",
        "position": 1,
    }

    books = state.get("books", {})  # name -> {series, returns, hits, lastPos}
    prev_spot = state.get("prevSpot")
    last_round = int(state.get("lastRound", -1))

    # --- Advance the paper book once per NEW strategy round (idempotent otherwise) ---
    advanced = False
    if spot and prev_spot and cur_round > last_round:
        move = (spot - prev_spot) / prev_spot
        advanced = True
        for name, b in books.items():
            pos = b.get("lastPos", 0)
            r = pos * move
            nav = (b["series"][-1] if b.get("series") else 1.0) * (1 + r)
            b.setdefault("series", []).append(round(nav, 12))
            b["series"] = b["series"][-MAX_SAMPLES:]
            b.setdefault("returns", []).append(r)
            b["returns"] = b["returns"][-MAX_SAMPLES:]
            h = b.setdefault("hits", {"rounds": 0, "correct": 0})
            if pos > 0:
                correct = move > 0
            elif pos < 0:
                correct = move < 0
            else:
                correct = abs(move) < FLAT_BAND
            h["rounds"] += 1
            h["correct"] += 1 if correct else 0

    # --- Record this round's positions for next time; seed any new competitor ---
    for name, c in comp.items():
        b = books.setdefault(
            name, {"series": [], "returns": [], "hits": {"rounds": 0, "correct": 0}}
        )
        b["lastPos"] = c["position"]
    # Drop competitors no longer present (e.g. Allora feed gone).
    for name in list(books.keys()):
        if name not in comp:
            del books[name]

    competitors = []
    for name, c in comp.items():
        b = books[name]
        m = _metrics(b.get("series", []), b.get("returns", []), b.get("hits", {}))
        pos = c["position"]
        competitors.append(
            {
                "name": name,
                "kind": c["kind"],
                "edge": c["edge"],
                "stance": "long" if pos > 0 else ("short/cash" if pos < 0 else "flat"),
                **m,
            }
        )

    # Rank by risk-adjusted return (Sharpe), then ROI; unscored competitors last.
    competitors.sort(
        key=lambda r: (
            (r["sharpe"] if r["sharpe"] is not None else -1e9),
            (r["paperRoiBps"] or 0),
        ),
        reverse=True,
    )

    doc = {
        "asset": "ETH",
        "inputs": {
            "spot": spot,
            "momentumPct": (agents_doc.get("inputs") or {}).get("momentumPct"),
            "round": cur_round,
        },
        "competitors": competitors,
        "updatedAt": now,
        "_state": {
            "books": books,
            "prevSpot": spot if spot else prev_spot,
            "lastRound": cur_round if advanced or last_round < 0 else last_round,
        },
    }
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "turing-bench.json"
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(doc, indent=2), encoding="utf-8")
    os.replace(tmp, path)
    print(
        f"turing benchmark: {len(competitors)} competitors, round {cur_round}, advanced={advanced}"
    )
    for r in competitors:
        print(
            f"  {r['name']}: sharpe {r['sharpe']} | ROI {r['paperRoiBps']}bps | "
            f"maxDD {r['maxDrawdownBps']}bps | hit {r['hitRatePct']}% ({r['rounds']} rds)"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
