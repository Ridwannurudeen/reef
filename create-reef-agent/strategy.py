"""Editable strategy function for a BYOA Reef agent.

The runtime passes a plain dict with on-chain vault state and live ReefGuard
status. Return action "increase", "decrease", or "hold" plus a signed rationale.
"""

from __future__ import annotations


def decide(state: dict) -> dict:
    nav = int(state["nav"])
    high_water_nav = int(state["highWaterNav"])
    idle = int(state["idle"])
    strategy_underlying = int(state["strategyUnderlying"])
    guard_allowed = bool(state["guardAllowed"])

    if strategy_underlying > 0 and nav < (high_water_nav * 9950) // 10000:
        return {
            "action": "decrease",
            "nav_delta_bps": -150,
            "reasoning": (
                "Reduce exposure: vault NAV is below the high-water mark, "
                "so this cycle realizes capital back to idle before the next receipt."
            ),
        }

    if guard_allowed and idle > 0:
        return {
            "action": "increase",
            "nav_delta_bps": 200,
            "reasoning": (
                "Increase exposure: ReefGuard clears the action and the vault "
                "has idle capital ready for the approved strategy."
            ),
        }

    return {
        "action": "hold",
        "nav_delta_bps": 0,
        "reasoning": (
            "Hold: either the guard is not clearing new exposure or the vault "
            "has no idle capital to deploy this cycle."
        ),
    }
