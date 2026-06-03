"""Free, key-less market signal (CoinGecko) to ground agent decisions in real data.

Returns a live price + 24h momentum for an asset so the LLM agent has a genuine reason
to increase/decrease exposure — turning it from a hold-at-NAV bot into a market-reacting
trader. Network failures return None; the brain then decides from on-chain state alone.
"""

from __future__ import annotations

from typing import Any

import requests

_IDS = {"ETH": "ethereum", "BTC": "bitcoin"}


def fetch_signal(asset: str = "ETH", timeout: float = 12.0) -> dict[str, Any] | None:
    """Return {asset, price, change24hPct, source} from CoinGecko, or None on failure."""
    cg_id = _IDS.get(asset.upper(), "ethereum")
    url = "https://api.coingecko.com/api/v3/simple/price"
    params = {"ids": cg_id, "vs_currencies": "usd", "include_24hr_change": "true"}
    try:
        r = requests.get(url, params=params, timeout=timeout)
        if r.status_code >= 300:
            return None
        d = r.json()[cg_id]
        return {
            "asset": asset.upper(),
            "price": float(d["usd"]),
            "change24hPct": round(float(d.get("usd_24h_change", 0.0)), 3),
            "source": "coingecko",
        }
    except Exception:  # noqa: BLE001 - signal is best-effort; brain falls back to NAV-only
        return None
