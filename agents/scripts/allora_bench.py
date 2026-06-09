#!/usr/bin/env python
"""Allora accuracy benchmark — score the decentralized inference network's ETH predictions
against the realized price on a fixed horizon, and accumulate a public hit-rate / error board.

Each run:
  1. Fetch Allora's current ETH/USD predicted price (topic 13) + the live CoinGecko spot.
  2. If a prior prediction is now older than the evaluation horizon, SCORE it against the
     current spot (the realized price): absolute error in bps + whether it called the
     direction (relative to the spot at prediction time) correctly. Accumulate MAE + hit-rate.
  3. Record the current prediction as the new pending one awaiting evaluation.

Read-only — no chain, no gas. Writes API_OUT_DIR/allora-bench.json. Idempotent: a prediction
is scored at most once (only after the horizon elapses), so frequent runs never double-count.
This is the hackathon's literal thesis — benchmarking autonomous AI, on a judge's own network.

Usage: API_OUT_DIR=/opt/reef/web/api python -m agents.scripts.allora_bench
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

from agents.shared.allora import fetch_eth_prediction
from agents.shared.config import REPO_ROOT
from agents.shared.signal import fetch_signal

HORIZON_SEC = int(os.getenv("ALLORA_BENCH_HORIZON", "3600") or "3600")
MAX_RECENT = 30


def main() -> int:
    out_dir = Path(os.getenv("API_OUT_DIR", str(REPO_ROOT / "ui" / "api")))
    path = out_dir / "allora-bench.json"
    prev: dict = {}
    if path.exists():
        try:
            prev = json.loads(path.read_text(encoding="utf-8"))
        except Exception:  # noqa: BLE001 - corrupt/partial file; start fresh
            prev = {}

    pred = fetch_eth_prediction()
    sig = fetch_signal("ETH")
    if not pred or not sig or not sig.get("price"):
        print(
            "allora or spot unavailable; leaving benchmark unchanged", file=sys.stderr
        )
        return 1
    now = int(time.time())
    predicted = float(pred["predictedPrice"])
    spot = float(sig["price"])

    board = prev.get("scoreboard") or {}
    samples = int(board.get("samples", 0))
    direction_hits = int(board.get("directionHits", 0))
    sum_abs_err_bps = float(board.get("sumAbsErrBps", 0.0))
    recent = prev.get("recent") or []
    pending = prev.get("pending")

    scored = None
    if pending and (now - int(pending.get("ts", now))) >= HORIZON_SEC:
        p_pred = float(pending["predictedPrice"])
        p_spot = float(pending["spotAtPrediction"])
        realized = spot
        err_bps = abs(p_pred - realized) / realized * 10000.0
        implied_dir = 1 if p_pred > p_spot else (-1 if p_pred < p_spot else 0)
        realized_dir = 1 if realized > p_spot else (-1 if realized < p_spot else 0)
        dir_correct = implied_dir != 0 and implied_dir == realized_dir
        samples += 1
        direction_hits += 1 if dir_correct else 0
        sum_abs_err_bps += err_bps
        scored = {
            "predictedPrice": round(p_pred, 2),
            "spotAtPrediction": round(p_spot, 2),
            "realizedSpot": round(realized, 2),
            "errBps": round(err_bps, 1),
            "dirCorrect": bool(dir_correct),
            "predictedAt": int(pending["ts"]),
            "evaluatedAt": now,
        }
        recent = ([scored] + recent)[:MAX_RECENT]
        pending = None

    # Start a fresh pending prediction if none is awaiting evaluation.
    if not pending:
        pending = {
            "predictedPrice": round(predicted, 2),
            "spotAtPrediction": round(spot, 2),
            "ts": now,
        }

    mae_bps = round(sum_abs_err_bps / samples, 1) if samples else None
    hit_rate = round(direction_hits / samples * 100.0, 1) if samples else None
    implied_bps = round((predicted - spot) / spot * 10000.0, 1)

    doc = {
        "topic": int(pred.get("topic", 13)),
        "asset": "ETH",
        "horizonSec": HORIZON_SEC,
        "current": {
            "predictedPrice": round(predicted, 2),
            "spot": round(spot, 2),
            "impliedBps": implied_bps,
            "ts": now,
        },
        "pending": pending,
        "scoreboard": {
            "samples": samples,
            "directionHits": direction_hits,
            "hitRatePct": hit_rate,
            "maeBps": mae_bps,
            "sumAbsErrBps": round(sum_abs_err_bps, 4),
        },
        "recent": recent,
        "updatedAt": now,
    }
    out_dir.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(doc, indent=2), encoding="utf-8")
    os.replace(tmp, path)
    msg = (
        f"Allora bench: predicted {predicted:.2f} vs spot {spot:.2f} "
        f"(implied {implied_bps:+.1f}bps) | samples {samples} hit-rate {hit_rate}% MAE {mae_bps}bps"
    )
    if scored:
        msg += f" | scored err {scored['errBps']}bps dir {'OK' if scored['dirCorrect'] else 'miss'}"
    print(msg)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
