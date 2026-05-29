"""Mock Nansen smart-money signal.

v1 of the Reef reference stack cannot hit the real Nansen MCP without a paid
key, so this module produces a deterministic-but-noisy `smart_money_inflow_bps`
value derived from a public input (the current unix minute). Tests stay
reproducible because the seed is the minute, not the second.

TODO: replace with real Nansen MCP call once a key is provisioned. The expected
contract is `fetch_signal()` returning the same dict shape as this mock so the
agent loop does not need to change.
"""

from __future__ import annotations

import hashlib
import math
import time
from typing import Any

# Conservative band — basis points of inflow per period. ~3% max swing.
MAX_BPS = 300


def _deterministic_noise(seed: int) -> float:
    """Return a number in [-1.0, 1.0] derived from `seed` via SHA-256."""
    digest = hashlib.sha256(seed.to_bytes(8, "big", signed=False)).digest()
    # Take the first 8 bytes as an unsigned int, map to [-1, 1].
    n = int.from_bytes(digest[:8], "big", signed=False)
    return (n / (2**64 - 1)) * 2.0 - 1.0


def fetch_signal(now_unix: int | None = None) -> dict[str, Any]:
    """Return a mock Nansen-style smart-money signal.

    The output is the same shape we'd expect from a real Nansen MCP wrapper:
        {
          "smart_money_inflow_bps": int in [-MAX_BPS, MAX_BPS],
          "confidence": float in [0, 1],
          "label": "inflow" | "outflow" | "neutral",
          "ts": int unix seconds,
          "source": "mock",
        }
    """
    if now_unix is None:
        now_unix = int(time.time())
    minute = now_unix // 60

    # Slow sine for trend + deterministic hash noise for jitter.
    trend = math.sin(minute / 11.0) * 0.6
    jitter = _deterministic_noise(minute) * 0.4
    signal = trend + jitter  # in roughly [-1, 1]
    bps = max(-MAX_BPS, min(MAX_BPS, int(signal * MAX_BPS)))

    if bps > 40:
        label = "inflow"
    elif bps < -40:
        label = "outflow"
    else:
        label = "neutral"

    return {
        "smart_money_inflow_bps": bps,
        "confidence": round(min(1.0, abs(signal)), 4),
        "label": label,
        "ts": now_unix,
        "source": "mock",
    }
