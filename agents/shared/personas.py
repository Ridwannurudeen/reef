"""Five competing agent personas — each a distinct, real-data strategy.

Every persona reads the SAME live inputs (CoinGecko spot/momentum, Allora ETH
prediction, Nansen smart-money flow) but acts on a different edge, so the
leaderboard becomes a genuine benchmark of which on-chain AI strategy performs
best. Four are deterministic rules (reliable, no LLM rate limit); one synthesises
everything via Z.ai GLM. Each returns a Decision; the runner tags it with the
persona name and scores it against realised price over time.
"""

from __future__ import annotations

from collections.abc import Callable

from agents.allora_agent.strategies import Decision, _clip
from agents.shared.brain import decide_for_vault


def _implied_pct(ctx: dict) -> float | None:
    """Allora predicted price vs spot, in percent (None if either is missing)."""
    sig, pred = ctx.get("signal"), ctx.get("prediction")
    if not pred or not sig or not sig.get("price"):
        return None
    return (pred["predictedPrice"] - sig["price"]) / sig["price"] * 100


def allora_quant(ctx: dict) -> Decision:
    """Trade the gap between Allora's ETH prediction and spot."""
    implied = _implied_pct(ctx)
    if implied is None:
        return Decision("hold", 0, "No Allora prediction available.", "rule")
    bps = _clip(int(implied * 60))  # ~0.6 bps per implied bp of edge
    action = "increase" if implied > 0.5 else "decrease" if implied < -0.5 else "hold"
    pred = ctx["prediction"]["predictedPrice"]
    return Decision(
        action,
        bps if action != "hold" else 0,
        f"Allora predicts ETH ${pred:.0f} ({implied:+.2f}% vs spot) -> {action}.",
        "rule",
    )


def smart_money(ctx: dict) -> Decision:
    """Follow Nansen smart-money 24h netflow into risk assets."""
    flow = ctx.get("flow")
    if not flow:
        return Decision("hold", 0, "No Nansen smart-money read.", "rule")
    net = flow["netFlow24hUsd"]
    label = flow["label"]
    bps = _clip(int(net / 2000))  # scale net USD flow into a bounded delta
    action = (
        "increase"
        if label == "accumulating"
        else "decrease"
        if label == "distributing"
        else "hold"
    )
    return Decision(
        action,
        bps if action != "hold" else 0,
        f"Nansen smart money {label} (${net:,}) -> {action}.",
        "rule",
    )


def glm_synthesis(ctx: dict) -> Decision:
    """Let Z.ai GLM synthesise spot + Allora + Nansen over the vault's NAV state."""
    return decide_for_vault(
        ctx.get("agent_id", 0),
        ctx.get("nav", 10**18),
        ctx.get("hwm", 10**18),
        ctx.get("signal"),
        ctx.get("prediction"),
        ctx.get("flow"),
    )


def contrarian(ctx: dict) -> Decision:
    """Fade momentum extremes — sell strength, buy weakness."""
    sig = ctx.get("signal")
    if not sig:
        return Decision("hold", 0, "No market signal.", "rule")
    m = sig["change24hPct"]
    if m > 3.0:
        return Decision(
            "decrease",
            _clip(int(-m * 30)),
            f"Momentum {m:+.2f}% extended -> fade (trim).",
            "rule",
        )
    if m < -3.0:
        return Decision(
            "increase",
            _clip(int(-m * 30)),
            f"Momentum {m:+.2f}% oversold -> buy the dip.",
            "rule",
        )
    return Decision("hold", 0, f"Momentum {m:+.2f}% within range -> hold.", "rule")


def conservative(ctx: dict) -> Decision:
    """Defensive: only act on small, multi-signal-aligned moves."""
    sig, flow = ctx.get("signal"), ctx.get("flow")
    implied = _implied_pct(ctx)
    m = sig["change24hPct"] if sig else 0.0
    bull = m > 0 and (implied or 0) > 0 and (flow or {}).get("label") == "accumulating"
    bear = m < 0 and (implied or 0) < 0 and (flow or {}).get("label") == "distributing"
    if bull:
        return Decision(
            "increase", 40, "All signals aligned bullish -> small add.", "rule"
        )
    if bear:
        return Decision(
            "decrease", -40, "All signals aligned bearish -> small trim.", "rule"
        )
    return Decision("hold", 0, "Signals not aligned -> preserve capital.", "rule")


def momentum(ctx: dict) -> Decision:
    """Ride momentum extremes — buy strength, sell weakness (trend-following)."""
    sig = ctx.get("signal")
    if not sig:
        return Decision("hold", 0, "No market signal.", "rule")
    m = sig["change24hPct"]
    if m > 3.0:
        return Decision(
            "increase",
            _clip(int(m * 30)),
            f"Momentum {m:+.2f}% trending up -> ride (add).",
            "rule",
        )
    if m < -3.0:
        return Decision(
            "decrease",
            _clip(int(m * 30)),
            f"Momentum {m:+.2f}% breaking down -> cut.",
            "rule",
        )
    return Decision("hold", 0, f"Momentum {m:+.2f}% within range -> hold.", "rule")


# Passive baseline state: agentIds that have already entered full long exposure.
_HODL_ENTERED: set[int] = set()


def hodl(ctx: dict) -> Decision:
    """Passive buy & hold — reach full long once, then never trade (market baseline)."""
    aid = ctx.get("agent_id", 0)
    if aid in _HODL_ENTERED:
        return Decision("hold", 0, "Passive buy & hold baseline -> hold.", "rule")
    _HODL_ENTERED.add(aid)
    return Decision(
        "increase", 500, "Passive buy & hold baseline -> enter full long.", "rule"
    )


# agentId -> (display name, edge tagline, strategy fn). Order matches seeded vaults 1..5.
PERSONAS: dict[int, tuple[str, str, Callable[[dict], Decision]]] = {
    1: ("Allora Quant", "trades Allora's ETH price prediction vs spot", allora_quant),
    2: ("Smart Money", "follows Nansen smart-money netflow", smart_money),
    3: ("GLM Synthesis", "Z.ai GLM reasons over all signals", glm_synthesis),
    4: ("Contrarian", "fades momentum extremes", contrarian),
    5: ("Conservative", "acts only on aligned multi-signal moves", conservative),
}


# Mainnet FusionX benchmark roster (4 agents), kept SEPARATE from the live testnet
# PERSONAS above so the two pipelines never interfere. Driven by mainnet_keeper.py
# against real on-chain vaults: three active AI strategies vs a passive HODL baseline.
# Names MUST mirror script/DeployMainnetFusionX.s.sol _personaNames().
BENCHMARK_PERSONAS: dict[int, tuple[str, str, Callable[[dict], Decision]]] = {
    1: ("GLM Synthesis", "Z.ai GLM reasons over all signals", glm_synthesis),
    2: ("Momentum", "rides momentum extremes (trend-following)", momentum),
    3: ("Contrarian", "fades momentum extremes (mean-reversion)", contrarian),
    4: ("HODL", "passive buy & hold market baseline", hodl),
}
