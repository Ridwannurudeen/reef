#!/usr/bin/env python
"""Mainnet Financial Turing Test — every live AI yield agent vs a passive HODL baseline.

The hackathon's namesake, run against the REAL Mantle-mainnet FusionX benchmark: can the
autonomous AI agents beat passively holding the asset, on a risk-adjusted basis? Pure transform
over the mainnet keeper's published feeds — mainnet-nav.json (per-agent NAV time-series) plus
mainnet-arena.json (per-agent edge/stance labels). No chain reads, no key. Idempotent: each run
re-scores the latest feeds, so re-runs over an unchanged feed produce an identical benchmark.

Each agent's raw NAV series is rebased to 1.0; we derive per-step returns and score paper ROI,
worst peak-to-trough drawdown, a Sharpe-like risk-adjusted return, the excess ROI over the HODL
baseline, and an information ratio (mean active return / tracking error vs HODL). Competitors are
ranked by Sharpe, then ROI; unscored entries sink to the bottom.

Writes API_OUT_DIR/mainnet-turing-bench.json: {asset, competitors:[...], state, updatedAt}.

Usage: API_OUT_DIR=/opt/reef/web/api python -m agents.scripts.mainnet_turing_bench
"""

from __future__ import annotations

import json
import os
import statistics
import sys
import time
from pathlib import Path

from agents.shared.config import REPO_ROOT

BASELINE_NAME = (
    "HODL"  # passive buy-and-hold competitor every AI agent is scored against
)


def _load(d: Path, name: str):
    p = d / name
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except (ValueError, OSError):  # missing / partial feed
        return None


def _stance(action: str | None) -> str | None:
    """Map a vault's exposure action to a directional stance label."""
    if action == "increase":
        return "long"
    if action == "decrease":
        return "short/cash"
    if action == "hold":
        return "flat"
    return None


def _series_returns(nav_series: list) -> tuple[list[float], list[float]]:
    """Rebase a raw NAV series to 1.0 and derive per-step returns r_t = nav_t/nav_{t-1} - 1."""
    vals = [float(v) for v in nav_series if v is not None]
    if len(vals) < 2 or not vals[0]:
        return [], []
    base = vals[0]
    norm = [v / base for v in vals]
    rets = [norm[i] / norm[i - 1] - 1.0 for i in range(1, len(norm)) if norm[i - 1]]
    return norm, rets


def _information_ratio(agent_rets, base_rets):
    k = min(len(agent_rets), len(base_rets))
    if k < 2:
        return None
    diff = [a - b for a, b in zip(agent_rets[-k:], base_rets[-k:])]
    sd = statistics.pstdev(diff)
    if sd == 0:
        return None
    return round(statistics.fmean(diff) / sd, 3)


def _metrics(series, returns):
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
    return {
        "navE18": str(int(nav * 10**18)),
        "paperRoiBps": roi_bps,
        "maxDrawdownBps": max_dd,
        "sharpe": sharpe,
        "samples": len(series),
    }


def main() -> int:
    out_dir = Path(os.getenv("API_OUT_DIR", str(REPO_ROOT / "ui" / "api")))
    nav_doc = _load(out_dir, "mainnet-nav.json")
    if not nav_doc or not nav_doc.get("agents"):
        print("no mainnet-nav.json feed; nothing to benchmark", file=sys.stderr)
        return 2

    arena = _load(out_dir, "mainnet-arena.json") or {}
    labels = {
        a.get("strategy"): a for a in arena.get("agents", []) if a.get("strategy")
    }
    now = int(time.time())

    # Flatten the per-agentId NAV dict to a list of {strategy, navSeries} competitors.
    entries = list(nav_doc["agents"].values())

    # The HODL baseline is the yardstick: rebase its NAV and derive its returns once.
    base_norm: list[float] = []
    base_rets: list[float] = []
    base_roi: float | None = None
    for e in entries:
        if e.get("strategy") == BASELINE_NAME:
            base_norm, base_rets = _series_returns(e.get("navSeries", []))
            base_roi = _metrics(base_norm, base_rets)["paperRoiBps"]
            break

    competitors = []
    for e in entries:
        name = e.get("strategy")
        if not name:
            continue
        norm, rets = _series_returns(e.get("navSeries", []))
        m = _metrics(norm, rets)
        lbl = labels.get(name, {})
        excess = (
            round(m["paperRoiBps"] - base_roi, 1)
            if m["paperRoiBps"] is not None and base_roi is not None
            else None
        )
        competitors.append(
            {
                "name": name,
                "kind": "human" if name == BASELINE_NAME else "ai",
                "edge": lbl.get("edge", ""),
                "stance": _stance(lbl.get("action")),
                "paperRoiBps": m["paperRoiBps"],
                "maxDrawdownBps": m["maxDrawdownBps"],
                "sharpe": m["sharpe"],
                "excessRoiBps": excess,
                "informationRatio": _information_ratio(rets, base_rets),
                "navE18": m["navE18"],
                "samples": m["samples"],
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

    state = "live" if any(c["samples"] >= 2 for c in competitors) else "accumulating"
    doc = {
        "asset": "ETH",
        "competitors": competitors,
        "state": state,
        "updatedAt": now,
    }
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "mainnet-turing-bench.json"
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(doc, indent=2), encoding="utf-8")
    os.replace(tmp, path)
    print(f"mainnet turing benchmark: {len(competitors)} competitors, state {state}")
    for r in competitors:
        print(
            f"  {r['name']} ({r['kind']}): sharpe {r['sharpe']} | ROI {r['paperRoiBps']}bps | "
            f"excess {r['excessRoiBps']}bps | IR {r['informationRatio']} | "
            f"maxDD {r['maxDrawdownBps']}bps | {r['samples']} samples"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
