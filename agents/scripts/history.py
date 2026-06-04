#!/usr/bin/env python
"""Reef analytics layer — roll the point-in-time snapshot into a persistent time-series.

Post-processes `reef.json` (written by api_snapshot) into `history.json`: an append-only
series of compact samples plus a derived `analytics` block (index NAV trend, per-agent
reputation gain, top mover over the retained window). Pure transform — no chain reads — so
it is safe to run in the same cron right after `api_snapshot`. Samples accumulate from first
run onward, so the history is real on-chain data sampled at cron cadence.

Usage (from repo root):
    python -m agents.scripts.history
    API_OUT_DIR=/opt/reef/web/api python -m agents.scripts.history
"""

from __future__ import annotations

import json
import os
from pathlib import Path

from agents.shared.config import REPO_ROOT

MAX_POINTS = 720  # ~30 days at hourly cadence


def _index_nav(total_assets: str, total_supply: str) -> str:
    ts = int(total_supply)
    return str(int(total_assets) * 10**18 // ts if ts else 10**18)


def _point(snapshot: dict) -> dict:
    idx = snapshot["index"]
    return {
        "ts": snapshot["meta"]["updatedAt"],
        "indexNav": _index_nav(idx["totalAssets"], idx["totalSupply"]),
        "totalAssets": idx["totalAssets"],
        "agents": {
            str(a["agentId"]): {
                "nav": a["nav"],
                "reputation": a["reputation"],
                "deployed": a["deployed"],
            }
            for a in snapshot["agents"]
        },
    }


def _bps(old: str, new: str) -> int:
    o = int(old)
    return (int(new) - o) * 10_000 // o if o else 0


def _analytics(points: list[dict]) -> dict:
    first, last = points[0], points[-1]
    agents = []
    for aid, cur in last["agents"].items():
        prev = first["agents"].get(aid)
        base = prev if prev else cur
        agents.append(
            {
                "agentId": int(aid),
                "reputationGain": str(int(cur["reputation"]) - int(base["reputation"])),
                "navChangeBps": _bps(base["nav"], cur["nav"]),
            }
        )
    top = max(agents, key=lambda a: int(a["reputationGain"]), default=None)
    return {
        "windowSeconds": max(0, last["ts"] - first["ts"]),
        "samples": len(points),
        "indexNavChangeBps": _bps(first["indexNav"], last["indexNav"]),
        # Only a genuine gainer is a "top mover"; an all-flat/loss window has none.
        "topMover": top["agentId"] if top and int(top["reputationGain"]) > 0 else None,
        "agents": agents,
    }


def roll(snapshot: dict, prev_points: list[dict]) -> tuple[list[dict], dict]:
    """Pure: fold a fresh snapshot into the retained series and recompute analytics.

    A sample whose timestamp is not newer than the last one replaces it (stale re-run or a
    clock step-back), so the series stays monotonic and never inflates.
    """
    point = _point(snapshot)
    points = list(prev_points)
    # Only a strictly newer sample extends the series; an equal-or-older timestamp (re-run on a
    # stale snapshot, or a clock step-back) replaces the last point, so the series stays
    # monotonic and never inflates.
    if points and point["ts"] <= points[-1]["ts"]:
        points[-1] = point
    else:
        points.append(point)
    points = points[-MAX_POINTS:]
    return points, _analytics(points)


def main() -> int:
    out_dir = Path(os.getenv("API_OUT_DIR", str(REPO_ROOT / "ui" / "api")))
    snapshot = json.loads((out_dir / "reef.json").read_text(encoding="utf-8"))

    hist_path = out_dir / "history.json"
    prev = []
    if hist_path.exists():
        prev = json.loads(hist_path.read_text(encoding="utf-8")).get("points", [])

    points, analytics = roll(snapshot, prev)
    out = {
        "updatedAt": snapshot["meta"]["updatedAt"],
        "analytics": analytics,
        "points": points,
    }
    # Atomic write: the accumulated series is the only copy, and the file is served statically.
    # write-temp-then-rename avoids a torn file from a crash or a concurrent mid-write read.
    tmp = hist_path.with_name(hist_path.name + ".tmp")
    tmp.write_text(json.dumps(out, indent=2), encoding="utf-8")
    os.replace(tmp, hist_path)
    print(
        f"wrote {hist_path} ({len(points)} samples, window {analytics['windowSeconds']}s)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
