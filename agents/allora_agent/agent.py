"""Allora-fed Reef Sovereign agent.

Loop:
  1. Fetch the configured Allora topic prediction.
  2. Ask GLM-5.1 (or fallback) for an action + nav_delta_bps.
  3. abi.encode the receipt and call AgentVault.publishReceipt.
  4. Print tx hash + new reputation summary.
"""

from __future__ import annotations

import json
import logging
import time
from typing import Any

import requests

from agents.allora_agent.strategies import Decision, decide, fallback_decide
from agents.shared import glm
from agents.shared.client import (
    get_w3,
    identity_contract,
    load_account,
    send_tx,
    vault_contract,
)
from agents.shared.config import load_agent_runtime, load_chain
from agents.shared.receipt import build_evidence, sign_receipt

log = logging.getLogger("allora_agent")


def fetch_allora_prediction(
    *, api_key: str | None, chain_slug: str, topic_id: int, timeout: float = 15.0
) -> dict[str, Any]:
    """Fetch the latest inference for an Allora topic.

    Endpoint: https://api.allora.network/v2/allora/consumer/{chainSlug}?allora_topic_id={id}
    `chainSlug` is a string like "ethereum-11155111" (NOT a numeric chain id).
    Source: https://docs.allora.network/devs/consumers/allora-api-endpoint
    """
    if not api_key:
        raise RuntimeError("ALLORA_API_KEY not set")
    url = f"https://api.allora.network/v2/allora/consumer/{chain_slug}"
    headers = {"x-api-key": api_key, "Accept": "application/json"}
    params = {"allora_topic_id": str(topic_id)}
    resp = requests.get(url, headers=headers, params=params, timeout=timeout)
    if resp.status_code >= 300:
        raise RuntimeError(f"Allora returned {resp.status_code}: {resp.text[:300]}")
    return resp.json()


def _extract_prediction_value(payload: dict[str, Any]) -> float | None:
    """Best-effort extraction of a numeric inference from the Allora response."""
    # The v2 consumer response wraps the inference; field naming has shifted across
    # versions. Try the common locations in order.
    candidates = [
        ("data", "inference_data", "network_inference_normalized"),
        ("data", "inference_data", "network_inference"),
        ("data", "network_inference_normalized"),
        ("data", "network_inference"),
        ("inference_data", "network_inference_normalized"),
        ("network_inference_normalized",),
        ("network_inference",),
    ]
    for path in candidates:
        cur: Any = payload
        ok = True
        for key in path:
            if isinstance(cur, dict) and key in cur:
                cur = cur[key]
            else:
                ok = False
                break
        if ok:
            try:
                return float(cur)
            except (TypeError, ValueError):
                continue
    return None


def _build_messages(
    prediction_payload: dict[str, Any], last_seq: int
) -> list[dict[str, str]]:
    system = (
        "You are a portfolio manager for an autonomous Mantle yield vault. "
        "You receive an Allora price prediction and must decide whether to increase, "
        "decrease, or hold exposure. Reply with strict JSON: "
        '{"action": "hold|increase|decrease", "nav_delta_bps": int between -500 and 500, '
        '"reasoning": "one short sentence"}.'
    )
    user = json.dumps(
        {
            "allora_response": prediction_payload,
            "last_receipt_seq": last_seq,
        },
        default=str,
    )
    return [
        {"role": "system", "content": system},
        {"role": "user", "content": user},
    ]


def _get_decision(
    prediction_payload: dict[str, Any], last_seq: int, runtime
) -> Decision:
    """Ask GLM; fall back to a deterministic rule on failure."""
    try:
        text = glm.chat(
            _build_messages(prediction_payload, last_seq),
            api_key=runtime.zai_api_key,
            base_url=runtime.zai_base_url,
            model=runtime.zai_model,
        )
        return decide(text)
    except (glm.GlmUnavailable, ValueError) as e:
        log.warning("GLM unavailable, using fallback decision: %s", e)
        pred_val = _extract_prediction_value(prediction_payload) or 0.0
        return fallback_decide(pred_val, current_price=pred_val)


def run_once(w3, account, vault, identity, runtime, period_s: int) -> None:
    """Execute one full cycle: fetch -> decide -> publish."""
    try:
        prediction = fetch_allora_prediction(
            api_key=runtime.allora_api_key,
            chain_slug=runtime.allora_chain_slug,
            topic_id=runtime.allora_topic_id,
        )
    except (requests.RequestException, RuntimeError) as e:
        log.error("Allora fetch failed: %s", e)
        return

    seq = vault.functions.nextReceiptSeq().call()
    decision = _get_decision(prediction, seq, runtime)

    decision_record = {
        "agent": "allora",
        "seq": seq,
        "allora_topic_id": runtime.allora_topic_id,
        "allora_chain_slug": runtime.allora_chain_slug,
        "prediction": prediction,
        "action": decision.action,
        "nav_delta_bps": decision.nav_delta_bps,
        "reasoning": decision.reasoning,
        "source": decision.source,
        "ts": int(time.time()),
    }
    evidence_hash, _ = build_evidence(decision_record)
    # nav_delta_bps is a basis-points delta in [-500, 500]; the on-chain navDelta
    # is an int256, so we publish the bps integer directly (no scaling needed for
    # the toy paper-mode loop; production would scale to 18 decimals).
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
        "publishing receipt seq=%d action=%s nav_delta_bps=%d source=%s",
        seq,
        decision.action,
        decision.nav_delta_bps,
        decision.source,
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
        "allora_agent starting | chain=%s operator=%s vault=%s topic=%d interval=%ds",
        chain.name,
        account.address,
        runtime.vault_address,
        runtime.allora_topic_id,
        runtime.poll_interval_s,
    )

    last_loop_ts = time.time()
    while True:
        now = time.time()
        period_s = max(1, int(now - last_loop_ts))
        last_loop_ts = now
        try:
            run_once(w3, account, vault, identity, runtime, period_s=period_s)
        except Exception as e:  # noqa: BLE001 — loop must keep running
            log.exception("cycle failed: %s", e)
        time.sleep(runtime.poll_interval_s)


if __name__ == "__main__":
    main()
