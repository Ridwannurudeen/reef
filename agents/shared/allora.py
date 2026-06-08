"""Live Allora Network ETH/USD price prediction signal.

Wraps the Allora v2 consumer API (topic 13 = ETH/USD, verified live on chain slug
`ethereum-11155111`) so agents can ground decisions in a real decentralized
inference network's price prediction — alongside the spot market signal. Returns
None on any failure (missing key, network error) so the brain falls back to
NAV + market-signal only.
"""

from __future__ import annotations

import os
from typing import Any

from agents.allora_agent.agent import (
    _extract_prediction_value as extract_prediction,
)
from agents.allora_agent.agent import (
    fetch_allora_prediction,
)


def fetch_eth_prediction(timeout: float = 12.0) -> dict[str, Any] | None:
    """Return {asset, predictedPrice, topic, source} from Allora, or None on failure."""
    key = os.getenv("ALLORA_API_KEY")
    if not key:
        return None
    slug = os.getenv("ALLORA_CHAIN_SLUG") or "ethereum-11155111"
    topic = int(os.getenv("ALLORA_TOPIC_ID", "13") or "13")
    try:
        payload = fetch_allora_prediction(
            api_key=key, chain_slug=slug, topic_id=topic, timeout=timeout
        )
        val = extract_prediction(payload)
        if val is None or val <= 0:
            return None
        return {
            "asset": "ETH",
            "predictedPrice": float(val),
            "topic": topic,
            "source": "allora",
        }
    except Exception:  # noqa: BLE001 - best-effort; brain decides without it on failure
        return None
