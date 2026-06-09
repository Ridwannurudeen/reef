#!/usr/bin/env python
"""Strategy performance benchmark — a verifiable track record per autonomous strategy.

Each run reads the published feeds — agents.json (decision-accuracy scoreboard) and arena.json
(each on-chain strategy's live NAV) — appends a NAV sample per strategy to a capped history, and
recomputes ROI (vs the first sample) + max drawdown (worst peak-to-trough). Merges in directional
accuracy + rounds. Writes API_OUT_DIR/strategy-bench.json. Pure transform — no chain, no key.
Idempotent: a sample at an already-seen timestamp replaces the last one (re-runs don't inflate).

This is the "benchmark autonomous AI" thesis as a scoreboard: capital performance (ROI/drawdown)
next to decision quality (accuracy), per strategy, accumulating in public.

Usage: API_OUT_DIR=/opt/reef/web/api python -m agents.scripts.strategy_benchmark
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

from agents.shared.config import REPO_ROOT

MAX_SAMPLES = 240  # ~capped history per strategy


def _load(d: Path, name: str):
    p = d / name
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:  # noqa: BLE001 - missing/partial feed
        return None


def _roi_drawdown_bps(series: list[float]) -> tuple[float | None, float | None]:
    """ROI vs first sample, and worst peak-to-trough drawdown, both in bps."""
    if len(series) < 2 or series[0] <= 0:
        return (None, None)
    roi = (series[-1] / series[0] - 1.0) * 10_000.0
    peak = series[0]
    max_dd = 0.0
    for v in series:
        if v > peak:
            peak = v
        if peak > 0:
            dd = (peak - v) / peak * 10_000.0
            if dd > max_dd:
                max_dd = dd
    return (round(roi, 1), round(max_dd, 1))


def main() -> int:
    out_dir = Path(os.getenv("API_OUT_DIR", str(REPO_ROOT / "ui" / "api")))
    path = out_dir / "strategy-bench.json"
    prev = _load(out_dir, "strategy-bench.json") or {}

    scoreboard = (_load(out_dir, "agents.json") or {}).get("scoreboard", {})
    arena_agents = (_load(out_dir, "arena.json") or {}).get("agents", [])
    if not scoreboard and not arena_agents:
        print("no agents.json/arena.json feeds; nothing to benchmark", file=sys.stderr)
        return 2

    nav_by_name = {a.get("strategy"): a for a in arena_agents if a.get("strategy")}
    edge_by_name = {
        a.get("strategy"): a.get("edge", "") for a in arena_agents if a.get("strategy")
    }

    now = int(time.time())
    series = prev.get("_series", {})  # {name: [[ts, nav_float], ...]}

    names = list(dict.fromkeys(list(scoreboard.keys()) + list(nav_by_name.keys())))
    strategies = []
    for name in names:
        s = series.get(name, [])
        a = nav_by_name.get(name)
        if a and a.get("navE18"):
            nav = int(a["navE18"]) / 1e18
            if s and int(s[-1][0]) >= now:
                s[-1] = [now, nav]  # replace same/older-ts sample (idempotent)
            else:
                s.append([now, nav])
            s = s[-MAX_SAMPLES:]
            series[name] = s
        nav_floats = [pt[1] for pt in s]
        roi_bps, dd_bps = _roi_drawdown_bps(nav_floats)
        sb = scoreboard.get(name, {})
        strategies.append(
            {
                "name": name,
                "edge": edge_by_name.get(name, ""),
                "navE18": a["navE18"] if a and a.get("navE18") else None,
                "roiBps": roi_bps,
                "maxDrawdownBps": dd_bps,
                "accuracyPct": sb.get("accuracyPct"),
                "rounds": sb.get("rounds"),
                "samples": len(nav_floats),
            }
        )

    # Rank: highest decision accuracy first, then ROI.
    strategies.sort(
        key=lambda r: ((r["accuracyPct"] or 0), (r["roiBps"] or 0)), reverse=True
    )

    doc = {
        "strategies": strategies,
        "updatedAt": now,
        "_series": series,
    }
    out_dir.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(doc, indent=2), encoding="utf-8")
    os.replace(tmp, path)
    print(f"strategy benchmark: {len(strategies)} strategies")
    for r in strategies:
        print(
            f"  {r['name']}: acc {r['accuracyPct']}% ({r['rounds']} rds) | "
            f"ROI {r['roiBps']}bps | maxDD {r['maxDrawdownBps']}bps | {r['samples']} nav samples"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
