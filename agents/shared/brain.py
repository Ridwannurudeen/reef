"""The agent 'brain': a real GLM decision from a vault's on-chain state.

Given a vault's current per-share NAV and high-water mark, ask the configured LLM
(Z.ai GLM by default, but any OpenAI-compatible endpoint via ZAI_BASE_URL/ZAI_MODEL)
for an allocation action + plain-English rationale. Falls back to a deterministic
rule when no key/endpoint is available, so the loop never stalls. The returned
Decision is recorded both on-chain (as the receipt's evidence hash) and off-chain
(published verbatim by the API), so the rationale is verifiable against the chain.
"""

from __future__ import annotations

import os

from agents.allora_agent.strategies import Decision, decide, fallback_decide
from agents.shared.glm import GlmUnavailable, chat

_SYSTEM = (
    "You are an autonomous on-chain yield agent on Mantle managing a sovereign vault. "
    "Each period you choose an allocation action and briefly justify it. "
    'Reply ONLY with compact JSON: {"action":"increase|hold|decrease","nav_delta_bps":int,"reasoning":"one sentence"}. '
    "nav_delta_bps is your intended exposure change in basis points, between -500 and 500."
)


def _zai_cfg() -> tuple[str | None, str, str]:
    key = os.getenv("ZAI_API_KEY") or None
    base = os.getenv("ZAI_BASE_URL") or "https://api.z.ai/api/paas/v4"
    model = os.getenv("ZAI_MODEL") or "glm-4.7-flash"
    return key, base, model


def decide_for_vault(agent_id: int, nav_1e18: int, high_water_1e18: int) -> Decision:
    """Make a real LLM allocation decision from the vault's on-chain NAV state."""
    nav = nav_1e18 / 1e18
    hwm = high_water_1e18 / 1e18
    drawdown_bps = 0 if hwm <= 0 else max(0, round((hwm - nav) / hwm * 10_000))
    prompt = (
        f"Agent #{agent_id}. Per-share NAV={nav:.6f}, all-time high NAV={hwm:.6f}, "
        f"current drawdown={drawdown_bps} bps. Reputation is credited only for NEW NAV highs, "
        f"so favor durable gains over chasing volatility. Decide your next allocation action."
    )
    key, base, model = _zai_cfg()
    try:
        out = chat(
            [
                {"role": "system", "content": _SYSTEM},
                {"role": "user", "content": prompt},
            ],
            api_key=key,
            base_url=base,
            model=model,
            temperature=0.3,
            timeout=30,
        )
        d = decide(out)  # parses JSON, clips ranges, source="glm"
        return d
    except (GlmUnavailable, ValueError):
        # Deterministic fallback: lean to recovering toward the high-water mark.
        return fallback_decide(prediction_value=hwm, current_price=nav)
