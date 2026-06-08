"""Live Nansen Smart Money flow signal.

Wraps the Nansen Smart Money netflow API (verified: POST /smart-money/netflow,
`apiKey` header) to give agents a real read on whether sophisticated on-chain
capital is net accumulating or distributing risk assets over the last 24h — a
"smart money risk appetite" input alongside spot momentum and the Allora
prediction. Returns None on any failure (missing key, network, plan limit) so the
brain decides without it. Each call costs Nansen credits, so callers should cache
and run it at low cadence.
"""

from __future__ import annotations

import os
from typing import Any

import requests

_URL = "https://api.nansen.ai/api/v1/smart-money/netflow"
_STABLES = {"USDT", "USDC", "DAI", "USDE", "FRAX", "TUSD", "USDP", "PYUSD"}
_NEUTRAL_BAND_USD = 25_000


def _is_stable(row: dict[str, Any]) -> bool:
    if (row.get("token_symbol") or "").upper() in _STABLES:
        return True
    return any("stable" in (s or "").lower() for s in (row.get("token_sectors") or []))


def fetch_smart_money_flow(timeout: float = 20.0) -> dict[str, Any] | None:
    """Return {netFlow24hUsd, label, topInflow, tokensTracked, source} or None."""
    key = os.getenv("NANSEN_API_KEY")
    if not key:
        return None
    try:
        r = requests.post(
            _URL,
            headers={"apiKey": key, "Content-Type": "application/json"},
            json={"chains": ["ethereum"]},
            timeout=timeout,
        )
        if r.status_code >= 300:
            return None
        rows = [x for x in (r.json().get("data") or []) if not _is_stable(x)]
        if not rows:
            return None
        net = round(sum((x.get("net_flow_24h_usd") or 0) for x in rows))
        top = max(rows, key=lambda x: x.get("net_flow_24h_usd") or 0)
        if net > _NEUTRAL_BAND_USD:
            label = "accumulating"
        elif net < -_NEUTRAL_BAND_USD:
            label = "distributing"
        else:
            label = "neutral"
        return {
            "netFlow24hUsd": net,
            "label": label,
            "topInflow": top.get("token_symbol"),
            "tokensTracked": len(rows),
            "source": "nansen",
        }
    except Exception:  # noqa: BLE001 - best-effort; brain decides without it on failure
        return None
