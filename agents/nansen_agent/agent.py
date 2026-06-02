"""Nansen-fed Reef Sovereign agent (mock signal in v1).

Mirrors the Allora agent's structure but reads a smart-money-inflow value from
agents.nansen_agent.signals. Same GLM decision pattern + receipt publishing.
"""

from __future__ import annotations

import json
import logging
import time
from dataclasses import dataclass
from typing import Any

from agents.nansen_agent.signals import fetch_signal
from agents.shared import glm
from agents.shared.client import (
    get_w3,
    identity_contract,
    load_account,
    send_tx,
    vault_contract,
)
from agents.shared.config import load_agent_runtime, load_chain
from agents.shared.receipt import build_evidence

log = logging.getLogger("nansen_agent")

# Same caps as the Allora agent's strategies.py — keep them in sync if you tune.
MAX_NAV_DELTA_BPS = 500
MIN_NAV_DELTA_BPS = -500
VALID_ACTIONS = ("hold", "increase", "decrease")


@dataclass
class Decision:
    action: str
    nav_delta_bps: int
    reasoning: str
    source: str  # "glm" or "fallback"


def _clip(v: int) -> int:
    return max(MIN_NAV_DELTA_BPS, min(MAX_NAV_DELTA_BPS, int(v)))


def _parse_glm(text: str) -> Decision:
    """Extract a Decision from a GLM JSON response."""
    raw = text.strip()
    if raw.startswith("```"):
        raw = raw.strip("`")
        if raw.lower().startswith("json"):
            raw = raw[4:]
        raw = raw.strip()
    # Tolerate trailing prose by grabbing the first {...}.
    start = raw.find("{")
    end = raw.rfind("}")
    if start == -1 or end == -1 or end <= start:
        raise ValueError(f"no JSON object in GLM output: {text[:200]}")
    obj = json.loads(raw[start : end + 1])

    action = str(obj.get("action", "hold")).lower().strip()
    if action not in VALID_ACTIONS:
        action = "hold"
    return Decision(
        action=action,
        nav_delta_bps=_clip(obj.get("nav_delta_bps", 0)),
        reasoning=str(obj.get("reasoning", ""))[:500],
        source="glm",
    )


def _fallback(signal: dict[str, Any]) -> Decision:
    """Rule: scale the mock inflow by confidence; threshold to action."""
    raw_bps = int(signal.get("smart_money_inflow_bps", 0))
    confidence = float(signal.get("confidence", 0.0))
    bps = _clip(int(raw_bps * confidence))
    if bps > 30:
        action = "increase"
    elif bps < -30:
        action = "decrease"
    else:
        action = "hold"
    return Decision(
        action=action,
        nav_delta_bps=bps,
        reasoning=f"fallback: bps={raw_bps} * confidence={confidence}",
        source="fallback",
    )


def _build_messages(signal: dict[str, Any], last_seq: int) -> list[dict[str, str]]:
    system = (
        "You manage a Mantle yield vault that follows smart-money flows. "
        "You receive a Nansen-style signal and must decide whether to increase, "
        "decrease, or hold exposure. Reply with strict JSON: "
        '{"action": "hold|increase|decrease", "nav_delta_bps": int in [-500,500], '
        '"reasoning": "one short sentence"}.'
    )
    user = json.dumps(
        {"nansen_signal": signal, "last_receipt_seq": last_seq}, default=str
    )
    return [
        {"role": "system", "content": system},
        {"role": "user", "content": user},
    ]


def _get_decision(signal: dict[str, Any], last_seq: int, runtime) -> Decision:
    try:
        text = glm.chat(
            _build_messages(signal, last_seq),
            api_key=runtime.zai_api_key,
            base_url=runtime.zai_base_url,
            model=runtime.zai_model,
        )
        return _parse_glm(text)
    except (glm.GlmUnavailable, ValueError, json.JSONDecodeError) as e:
        log.warning("GLM unavailable, using fallback decision: %s", e)
        return _fallback(signal)


def run_once(w3, account, vault, identity, runtime, period_s: int) -> None:
    signal = fetch_signal()
    seq = vault.functions.nextReceiptSeq().call()
    decision = _get_decision(signal, seq, runtime)

    decision_record = {
        "agent": "nansen",
        "seq": seq,
        "signal": signal,
        "action": decision.action,
        "nav_delta_bps": decision.nav_delta_bps,
        "reasoning": decision.reasoning,
        "source": decision.source,
        "ts": int(time.time()),
    }
    evidence_hash, _ = build_evidence(decision_record)
    receipt_args = sign_receipt(
        account.key,
        vault=vault.address,
        chain_id=w3.eth.chain_id,
        agent_id=vault.functions.agentId().call(),
        seq=seq,
        evidence_hash=evidence_hash,
        claimed_delta=int(decision.nav_delta_bps),
        period=int(period_s),
    )

    log.info(
        "publishing receipt seq=%d action=%s nav_delta_bps=%d source=%s label=%s",
        seq,
        decision.action,
        decision.nav_delta_bps,
        decision.source,
        signal["label"],
    )
    receipt = send_tx(w3, account, vault.functions.publishReceipt(*receipt_args))
    cum, count = identity.functions.getSummary(vault.functions.agentId().call()).call()
    log.info(
        "tx %s mined in block %d status=%s | reputation cumulative=%s count=%d",
        receipt["transactionHash"].hex(),
        receipt["blockNumber"],
        receipt["status"],
        cum,
        count,
    )


def main() -> None:
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s [%(name)s] %(levelname)s: %(message)s"
    )
    chain = load_chain()
    runtime = load_agent_runtime()

    w3 = get_w3(chain.rpc_url)
    account = load_account()
    vault = vault_contract(w3, runtime.vault_address)
    identity = identity_contract(w3, chain.identity_address)

    log.info(
        "nansen_agent starting | chain=%s operator=%s vault=%s interval=%ds (mock Nansen signal)",
        chain.name,
        account.address,
        runtime.vault_address,
        runtime.poll_interval_s,
    )

    last_loop_ts = time.time()
    while True:
        now = time.time()
        period_s = max(1, int(now - last_loop_ts))
        last_loop_ts = now
        try:
            run_once(w3, account, vault, identity, runtime, period_s=period_s)
        except Exception as e:  # noqa: BLE001
            log.exception("cycle failed: %s", e)
        time.sleep(runtime.poll_interval_s)


if __name__ == "__main__":
    main()
