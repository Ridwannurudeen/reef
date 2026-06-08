"""Real Nansen smart-money signal for the reference agent.

Reads live Smart Money 24h netflow via `agents.shared.nansen` (verified Nansen
API) and maps it to the `smart_money_inflow_bps` shape the Nansen agent's decision
rule expects. When no Nansen key is set (or the call fails), returns a neutral
signal so the reference agent still runs offline rather than fabricating data.
"""

from __future__ import annotations

import time
from typing import Any

from agents.shared.nansen import fetch_smart_money_flow

# Map net USD flow to a bounded basis-points reading: $1k net ~= 1 bp, capped at
# +/-300 bps (so ~$300k of net smart-money flow saturates the signal).
MAX_BPS = 300
_USD_PER_BPS = 1_000
_LABEL_MAP = {"accumulating": "inflow", "distributing": "outflow", "neutral": "neutral"}


def fetch_signal(now_unix: int | None = None) -> dict[str, Any]:
    """Return a live Nansen smart-money signal, or a neutral one if unavailable.

    Shape: {smart_money_inflow_bps, confidence, label, ts, source}.
    """
    if now_unix is None:
        now_unix = int(time.time())
    flow = fetch_smart_money_flow()
    if not flow:
        return {
            "smart_money_inflow_bps": 0,
            "confidence": 0.0,
            "label": "neutral",
            "ts": now_unix,
            "source": "nansen-unavailable",
        }
    bps = max(-MAX_BPS, min(MAX_BPS, round(flow["netFlow24hUsd"] / _USD_PER_BPS)))
    return {
        "smart_money_inflow_bps": bps,
        "confidence": round(min(1.0, abs(bps) / MAX_BPS), 4),
        "label": _LABEL_MAP.get(flow["label"], "neutral"),
        "ts": now_unix,
        "source": "nansen",
    }
