#!/usr/bin/env python
"""Agent Passport API — per-agent JSON endpoints composed from the published feeds.

Reads the already-published API_OUT_DIR feeds (scores.json, guard.json, allocator.json,
executions.json) and writes one file per agent at API_OUT_DIR/agent/<id>.json — the public
agent passport: trust score + rating + components, ReefGuard verdict, allocation under the
active mandate, and the latest decision/receipt. Plus agent/index.json listing the ids.
Pure transform — no chain reads, no key. This is the read side of the ReefGuard SDK:
GET /api/agent/<id>.json.

Usage: API_OUT_DIR=/opt/reef/web/api python -m agents.scripts.passport_snapshot
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

from agents.shared.config import REPO_ROOT


def _load(d: Path, name: str):
    p = d / name
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:  # noqa: BLE001 - missing/partial feed; treat as absent
        return None


def main() -> int:
    out_dir = Path(os.getenv("API_OUT_DIR", str(REPO_ROOT / "ui" / "api")))
    scores = (_load(out_dir, "scores.json") or {}).get("agents", [])
    if not scores:
        print("no scores.json; nothing to publish", file=sys.stderr)
        return 2
    guard = {
        str(g["agentId"]): g
        for g in (_load(out_dir, "guard.json") or {}).get("agents", [])
    }
    alloc_doc = _load(out_dir, "allocator.json") or {}
    alloc = {str(a["agentId"]): a for a in alloc_doc.get("agents", [])}
    exes = (_load(out_dir, "executions.json") or {}).get("executions", [])

    agent_dir = out_dir / "agent"
    agent_dir.mkdir(parents=True, exist_ok=True)
    ts = int(time.time())
    written = 0
    for s in scores:
        aid = str(s.get("agentId"))
        g = guard.get(aid)
        a = alloc.get(aid)
        latest = next((e for e in exes if str(e.get("agent")) == aid), None)
        doc = {
            "agentId": int(aid),
            "trustScore": s.get("trustScore"),
            "rating": s.get("rating"),
            "components": s.get("components"),
            "reputationE18": s.get("reputationE18"),
            "navE18": s.get("navE18"),
            "bondE18": s.get("bondE18"),
            "bonded": s.get("bonded"),
            "receiptAgeSec": s.get("receiptAgeSec"),
            "vault": s.get("vault"),
            "reefGuard": {"allowed": g.get("allowed"), "reason": g.get("reason")}
            if g
            else None,
            "allocation": (
                {
                    "qualified": a.get("qualified"),
                    "targetWeightBps": a.get("targetWeightBps"),
                }
                if a
                else None
            ),
            "activeMandate": alloc_doc.get("activeMandate"),
            "latestDecision": (
                {
                    "action": latest.get("action"),
                    "source": latest.get("source"),
                    "model": latest.get("model"),
                    "reasoning": latest.get("reasoning"),
                    "txHash": (latest.get("execution") or {}).get("txHash"),
                    "ts": latest.get("ts"),
                }
                if latest
                else None
            ),
            "updatedAt": ts,
        }
        path = agent_dir / f"{aid}.json"
        tmp = path.with_name(path.name + ".tmp")
        tmp.write_text(json.dumps(doc, indent=2), encoding="utf-8")
        os.replace(tmp, path)
        written += 1

    idx = {"agents": sorted(int(s.get("agentId")) for s in scores), "updatedAt": ts}
    ipath = agent_dir / "index.json"
    itmp = ipath.with_name(ipath.name + ".tmp")
    itmp.write_text(json.dumps(idx, indent=2), encoding="utf-8")
    os.replace(itmp, ipath)
    print(f"passport: wrote {written} agent files + index")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
