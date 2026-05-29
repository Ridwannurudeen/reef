"""Decision parsing + deterministic fallback for the Allora agent.

The GLM model is asked to return JSON of the form
    {"action": "hold"|"increase"|"decrease", "nav_delta_bps": int, "reasoning": str}
This module:
  - parses that JSON (resilient to surrounding text)
  - clips values into sane ranges
  - provides a rule-based fallback when GLM is unavailable
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any

# Hard caps so a runaway model can't push reputation into oblivion in a single
# receipt. ~5% per period is plenty for a 30-second cadence demo.
MAX_NAV_DELTA_BPS = 500
MIN_NAV_DELTA_BPS = -500
VALID_ACTIONS = ("hold", "increase", "decrease")


@dataclass
class Decision:
    action: str  # one of VALID_ACTIONS
    nav_delta_bps: int  # clipped to [MIN_NAV_DELTA_BPS, MAX_NAV_DELTA_BPS]
    reasoning: str
    source: str  # "glm" or "fallback"


def _extract_json_blob(raw: str) -> dict[str, Any]:
    """Pull the first {...} object out of the model output and json-load it."""
    raw = raw.strip()
    # Strip markdown fences if present.
    if raw.startswith("```"):
        raw = re.sub(r"^```(?:json)?", "", raw).strip()
        if raw.endswith("```"):
            raw = raw[:-3].strip()
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        pass
    match = re.search(r"\{.*\}", raw, flags=re.DOTALL)
    if not match:
        raise ValueError(f"no JSON object in model output: {raw[:200]}")
    return json.loads(match.group(0))


def _clip(v: int) -> int:
    return max(MIN_NAV_DELTA_BPS, min(MAX_NAV_DELTA_BPS, int(v)))


def decide(glm_response: str) -> Decision:
    """Parse a GLM JSON response into a Decision."""
    obj = _extract_json_blob(glm_response)
    action = str(obj.get("action", "hold")).lower().strip()
    if action not in VALID_ACTIONS:
        action = "hold"
    nav_delta = _clip(obj.get("nav_delta_bps", 0))
    reasoning = str(obj.get("reasoning", ""))[:500]
    return Decision(
        action=action, nav_delta_bps=nav_delta, reasoning=reasoning, source="glm"
    )


def fallback_decide(prediction_value: float, current_price: float | None) -> Decision:
    """Deterministic decision when GLM is unavailable.

    Rules: if the predicted price is materially above current, increase; below,
    decrease; otherwise hold. nav_delta scales with the percentage gap.
    """
    if current_price is None or current_price <= 0:
        # No reference price -> tiny positive bias proportional to log of prediction.
        return Decision(
            action="hold",
            nav_delta_bps=0,
            reasoning="fallback: no current price",
            source="fallback",
        )

    pct = (prediction_value - current_price) / current_price
    bps = _clip(int(pct * 10_000 * 0.25))  # 25% conviction
    if bps > 25:
        action = "increase"
    elif bps < -25:
        action = "decrease"
    else:
        action = "hold"
    return Decision(
        action=action,
        nav_delta_bps=bps,
        reasoning=f"fallback rule: pct={pct:.4%}",
        source="fallback",
    )
