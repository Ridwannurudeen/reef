#!/usr/bin/env python
"""Reef proof-bound rebalance: the unified, sole-publisher allocation loop.

For every seeded agent vault, in one sequential cron-safe pass:

  1. decide       - GLM (or deterministic fallback) picks an allocation action
  2. gate         - ReefGuard.canExecute(agentId, asset, sizeBps) checks policy
  3. move capital - deployToStrategy / recallFromStrategy through the approved adapter
  4. bind proof   - publishReceipt with evidenceHash == keccak256(verbatim rationale)
  5. reputation   - credited on-chain from realized, donation-proof NAV only

This replaces the legacy execute_decision + receipt_tick split. It is the SOLE
receipt publisher for seeded vaults, so it must not run concurrently with
receipt_tick for the same vaults.

Writes:
  API_OUT_DIR/proofbound.json - full rebalance evidence keyed by agentId
  API_OUT_DIR/proofs.json     - verifier-friendly rationale/receipt bindings

Usage (crons paused; PRIVATE_KEY = the agent operator key):
    API_OUT_DIR=ui/api python -m agents.scripts.proofbound_rebalance
    DRY_RUN=1 python -m agents.scripts.proofbound_rebalance
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path
from typing import Any

from eth_utils import keccak

from agents.allora_agent.strategies import (
    MAX_NAV_DELTA_BPS,
    MIN_NAV_DELTA_BPS,
    VALID_ACTIONS,
    Decision,
    fallback_decide,
)
from agents.shared.allora import fetch_eth_prediction
from agents.shared.client import (
    get_w3,
    identity_contract,
    load_abi,
    load_account,
    rpc_read,
    send_tx,
    vault_contract,
)
from agents.shared.config import DEPLOYMENTS_DIR, REPO_ROOT, load_chain
from agents.shared.glm import GlmUnavailable, chat
from agents.shared.nansen import fetch_smart_money_flow
from agents.shared.receipt import build_evidence, sign_receipt
from agents.shared.signal import fetch_signal

ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"


def _contract(w3, address, abi_name):
    return w3.eth.contract(
        address=w3.to_checksum_address(address), abi=load_abi(abi_name)
    )


def _atomic_write(path: Path, doc: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(doc, indent=2), encoding="utf-8")
    os.replace(tmp, path)


def _safe_fetch(label: str, fn):
    try:
        return fn()
    except Exception as e:  # noqa: BLE001 - external data must not stall receipts
        print(f"{label} unavailable: {e}", file=sys.stderr)
        return None


def _is_zero(address: str | None) -> bool:
    return not address or address.lower() == ZERO_ADDRESS


def _same_address(a: str | None, b: str | None) -> bool:
    return bool(a and b) and a.lower() == b.lower()


def _hex(w3, value) -> str:
    return w3.to_hex(value).lower()


def _asset_address(seeded: dict[str, Any]) -> str | None:
    raw = seeded.get("asset")
    return raw.get("address") if isinstance(raw, dict) else raw


def _json_object(raw: str) -> dict[str, Any]:
    raw = raw.strip()
    if raw.startswith("```"):
        raw = raw.removeprefix("```json").removeprefix("```").strip()
        if raw.endswith("```"):
            raw = raw[:-3].strip()
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        start = raw.find("{")
        end = raw.rfind("}")
        if start == -1 or end == -1 or end < start:
            raise
        return json.loads(raw[start : end + 1])


def _clip_bps(value: Any) -> int:
    return max(MIN_NAV_DELTA_BPS, min(MAX_NAV_DELTA_BPS, int(value)))


def _decision_from_obj(obj: dict[str, Any]) -> Decision:
    action = str(obj.get("action", "hold")).lower().strip()
    if action not in VALID_ACTIONS:
        action = "hold"
    reasoning = str(obj.get("reasoning", "")).strip()[:500]
    if not reasoning:
        reasoning = "GLM returned an empty rationale."
    return Decision(
        action=action,
        nav_delta_bps=_clip_bps(obj.get("nav_delta_bps", 0)),
        reasoning=reasoning,
        source="glm",
    )


def _fallback_for_state(state: dict[str, Any]) -> Decision:
    return fallback_decide(
        prediction_value=int(state["highWaterNav"]) / 1e18,
        current_price=int(state["nav"]) / 1e18,
    )


def _forced_decision() -> Decision | None:
    forced = os.getenv("PROOFBOUND_FORCE_DECISION")
    if not forced:
        return None

    action = str(forced).strip().lower()
    if action not in VALID_ACTIONS:
        print(
            f"Invalid PROOFBOUND_FORCE_DECISION={forced}; expected increase|hold|decrease",
            file=sys.stderr,
        )
        return None

    try:
        nav_delta = int(os.getenv("PROOFBOUND_FORCE_NAV_DELTA_BPS", "0"))
    except ValueError:
        print(
            "Invalid PROOFBOUND_FORCE_NAV_DELTA_BPS; using 0",
            file=sys.stderr,
        )
        nav_delta = 0
    reasoning = os.getenv("PROOFBOUND_FORCE_REASON") or f"forced scenario: {action}"
    return Decision(
        action=action,
        nav_delta_bps=_clip_bps(nav_delta),
        reasoning=reasoning,
        source="fallback",
    )


def _zai_cfg() -> tuple[str | None, str, str]:
    return (
        os.getenv("ZAI_API_KEY") or None,
        os.getenv("ZAI_BASE_URL") or "https://api.z.ai/api/paas/v4",
        os.getenv("ZAI_MODEL") or "glm-4.7-flash",
    )


def _decide_all(
    states: list[dict[str, Any]],
    signal: dict | None,
    prediction: dict | None,
    flow: dict | None,
) -> dict[int, Decision]:
    forced = _forced_decision()
    if forced is not None:
        return {int(s["agentId"]): forced for s in states}

    fallbacks = {int(s["agentId"]): _fallback_for_state(s) for s in states}
    key, base, model = _zai_cfg()
    if not key:
        return fallbacks

    vaults = []
    for state in states:
        nav = int(state["nav"]) / 1e18
        hwm = int(state["highWaterNav"]) / 1e18
        drawdown_bps = 0 if hwm <= 0 else max(0, round((hwm - nav) / hwm * 10_000))
        vaults.append(
            {
                "agentId": int(state["agentId"]),
                "nav": round(nav, 8),
                "highWaterNav": round(hwm, 8),
                "drawdownBps": drawdown_bps,
            }
        )

    prompt = {
        "task": "Return one allocation decision for every agentId. Increase exposure when the market setup is favorable, decrease when risk is worsening, otherwise hold. Reputation only accrues on new realized NAV highs.",
        "schema": {
            "decisions": [
                {
                    "agentId": "number",
                    "action": "increase|hold|decrease",
                    "nav_delta_bps": "integer from -500 to 500",
                    "reasoning": "one sentence",
                }
            ]
        },
        "vaults": vaults,
        "market": signal,
        "allora": prediction,
        "nansen": flow,
    }
    try:
        raw = chat(
            [
                {
                    "role": "system",
                    "content": "You are an autonomous Mantle yield agent coordinator. Reply ONLY with compact JSON matching the requested schema.",
                },
                {"role": "user", "content": json.dumps(prompt, default=str)},
            ],
            api_key=key,
            base_url=base,
            model=model,
            temperature=0.3,
            timeout=55,
        )
        doc = _json_object(raw)
    except (GlmUnavailable, ValueError, json.JSONDecodeError) as e:
        print(f"GLM batch unavailable: {e}", file=sys.stderr)
        return fallbacks

    decisions = fallbacks.copy()
    raw_decisions = doc.get("decisions", [])
    if not isinstance(raw_decisions, list):
        print("GLM batch response missing decisions array", file=sys.stderr)
        return fallbacks

    for item in raw_decisions:
        if not isinstance(item, dict):
            continue
        try:
            agent_id = int(item.get("agentId"))
        except (TypeError, ValueError):
            continue
        if agent_id in decisions:
            decisions[agent_id] = _decision_from_obj(item)
    return decisions


def _adapter_candidates(vault_info: dict[str, Any], seeded: dict[str, Any]) -> list[str]:
    candidates: list[str] = []
    for key in ("strategyAdapter", "adapter"):
        if vault_info.get(key):
            candidates.append(vault_info[key])

    ya = seeded.get("yieldAdapter") or {}
    if _same_address(ya.get("vault"), vault_info.get("vault")) and ya.get("address"):
        candidates.append(ya["address"])

    seen: set[str] = set()
    out: list[str] = []
    for candidate in candidates:
        lower = str(candidate).lower()
        if lower not in seen:
            seen.add(lower)
            out.append(candidate)
    return out


def _validated_adapter(w3, vault_addr: str, adapter: str, asset: str) -> str | None:
    try:
        ac = _contract(w3, adapter, "MockStrategyAdapter")
        adapter_vault = rpc_read(lambda: ac.functions.vault().call())
        adapter_asset = rpc_read(lambda: ac.functions.asset().call())
    except Exception as e:  # noqa: BLE001 - candidate is not a compatible adapter
        print(f"adapter {adapter} rejected: {e}", file=sys.stderr)
        return None
    if not _same_address(adapter_vault, vault_addr):
        print(
            f"adapter {adapter} rejected: vault mismatch {adapter_vault} != {vault_addr}",
            file=sys.stderr,
        )
        return None
    if not _same_address(adapter_asset, asset):
        print(
            f"adapter {adapter} rejected: asset mismatch {adapter_asset} != {asset}",
            file=sys.stderr,
        )
        return None
    return w3.to_checksum_address(adapter)


def _adapter_for_vault(
    w3,
    vault_info: dict[str, Any],
    seeded: dict[str, Any],
    current_strategy: str,
    asset: str,
) -> str | None:
    candidates = _adapter_candidates(vault_info, seeded)
    if not _is_zero(current_strategy):
        candidates.append(current_strategy)

    seen: set[str] = set()
    for candidate in candidates:
        if not candidate:
            continue
        lower = str(candidate).lower()
        if lower in seen:
            continue
        seen.add(lower)
        adapter = _validated_adapter(w3, vault_info["vault"], candidate, asset)
        if adapter is not None:
            return adapter
    return None


def _publish_receipt(w3, account, vc, agent_id: int, evidence: bytes, period: int):
    seq = rpc_read(lambda: vc.functions.nextReceiptSeq().call())
    args = sign_receipt(
        account.key,
        vault=vc.address,
        chain_id=w3.eth.chain_id,
        agent_id=agent_id,
        seq=seq,
        evidence_hash=evidence,
        claimed_delta=0,
        period=period,
    )
    receipt = send_tx(w3, account, vc.functions.publishReceipt(*args))
    return seq, w3.to_hex(receipt["transactionHash"])


def _wait_for_evidence(w3, vc, expected: str) -> tuple[str, bool]:
    on_chain = ZERO_ADDRESS
    for i in range(8):
        on_chain = _hex(
            w3, rpc_read(lambda: vc.functions.lastReceiptEvidenceHash().call())
        )
        if on_chain == expected:
            return on_chain, True
        if i < 7:
            time.sleep(2)
    return on_chain, False


def _proof_record(record: dict[str, Any]) -> dict[str, Any]:
    return {
        "seq": record.get("seq"),
        "evidenceHash": record.get("evidenceHash"),
        "rationaleHash": record.get("evidenceHash")
        if record.get("proofStatus") == "bound"
        else None,
        "reasoning": record.get("rationale")
        if record.get("proofStatus") == "bound"
        else None,
        "source": record.get("source")
        if record.get("proofStatus") == "bound"
        else None,
        "model": record.get("model")
        if record.get("proofStatus") == "bound"
        else None,
        "txHash": record.get("receiptTx"),
        "proofStatus": "matched"
        if record.get("proofStatus") == "bound"
        else record.get("proofStatus"),
        "ts": record.get("ts"),
    }


def _process_vault(
    *,
    w3,
    account,
    vault_info: dict[str, Any],
    seeded: dict[str, Any],
    asset: str,
    guard,
    ident,
    decisions: dict[int, Decision],
    action_bps: int,
    period: int,
    dry_run: bool,
) -> tuple[int, dict[str, Any], dict[str, Any] | None]:
    vc = vault_contract(w3, vault_info["vault"])
    erc20 = _contract(w3, asset, "MockERC20")
    agent_id = rpc_read(lambda: vc.functions.agentId().call())
    nav_before = rpc_read(lambda: vc.functions.nav().call())
    hwm = rpc_read(lambda: vc.functions.highWaterNav().call())
    idle = rpc_read(
        lambda: erc20.functions.balanceOf(w3.to_checksum_address(vault_info["vault"])).call()
    )
    current_strategy = rpc_read(lambda: vc.functions.currentStrategy().call())
    adapter = _adapter_for_vault(w3, vault_info, seeded, current_strategy, asset)

    decision = decisions.get(
        agent_id,
        fallback_decide(prediction_value=hwm / 1e18, current_price=nav_before / 1e18),
    )
    max_bps = int(rpc_read(lambda: guard.functions.maxSizeBps().call()))
    size_bps = 0 if decision.action == "hold" else max(1, min(action_bps, max_bps))
    allowed, reason = rpc_read(
        lambda: guard.functions.canExecute(
            agent_id, w3.to_checksum_address(asset), size_bps
        ).call()
    )

    model = (
        os.getenv("ZAI_MODEL") or "glm-4.7-flash"
        if decision.source == "glm"
        else "deterministic-fallback"
    )
    record: dict[str, Any] = {
        "agentId": agent_id,
        "vault": w3.to_checksum_address(vault_info["vault"]),
        "adapter": adapter,
        "action": decision.action,
        "navDeltaBps": decision.nav_delta_bps,
        "rationale": decision.reasoning,
        "source": decision.source,
        "model": model if decision.source == "glm" else "deterministic-fallback",
        "guard": {"allowed": bool(allowed), "reason": reason, "sizeBps": size_bps},
        "navBefore": str(nav_before),
        "currentStrategy": current_strategy,
        "idle": str(idle),
        "ts": int(time.time()),
    }
    print(
        f"agent {agent_id}: [{decision.source}] {decision.action} "
        f"{decision.nav_delta_bps}bps | guard={allowed} ({reason})"
    )
    print(f"  rationale: {decision.reasoning[:90]}")

    if not allowed:
        record["moveStatus"] = "guard-refused"
    elif decision.action == "increase":
        deploy_amt = (idle * size_bps) // 10_000
        if adapter is None:
            record["moveStatus"] = "no-adapter"
        elif deploy_amt <= 0:
            record["moveStatus"] = "no-idle"
        elif not (
            _is_zero(current_strategy) or _same_address(current_strategy, adapter)
        ):
            record["moveStatus"] = "different-active-strategy"
        elif dry_run:
            record["moveStatus"] = f"dry-run deployToStrategy({deploy_amt})"
        else:
            receipt = send_tx(
                w3,
                account,
                vc.functions.deployToStrategy(w3.to_checksum_address(adapter), deploy_amt),
            )
            record["deployTx"] = w3.to_hex(receipt["transactionHash"])
            record["moveStatus"] = "deployed"
            print(f"  deployToStrategy {deploy_amt} -> {record['deployTx']}")
    elif decision.action == "decrease":
        if _is_zero(current_strategy):
            record["moveStatus"] = "nothing-to-recall"
        else:
            recall_adapter = w3.to_checksum_address(current_strategy)
            ac = _contract(w3, recall_adapter, "MockStrategyAdapter")
            underlying = rpc_read(lambda: ac.functions.totalUnderlying().call())
            recall_amt = (underlying * size_bps) // 10_000
            record["strategyUnderlying"] = str(underlying)
            if recall_amt <= 0:
                record["moveStatus"] = "nothing-to-recall"
            elif dry_run:
                record["moveStatus"] = f"dry-run recallFromStrategy({recall_amt})"
            else:
                receipt = send_tx(
                    w3,
                    account,
                    vc.functions.recallFromStrategy(recall_adapter, recall_amt),
                )
                record["recallTx"] = w3.to_hex(receipt["transactionHash"])
                record["moveStatus"] = "recalled"
                print(
                    f"  recallFromStrategy {recall_amt} (realized) -> {record['recallTx']}"
                )
    else:
        record["moveStatus"] = "hold"

    if dry_run:
        record["proofStatus"] = "dry-run"
        print("  DRY_RUN plan: gate -> move decision -> publishReceipt(keccak(rationale))")
        return agent_id, record, None

    if account is None:
        raise RuntimeError("missing account for live receipt publishing")

    reasoning = decision.reasoning.strip()
    if reasoning:
        evidence = keccak(reasoning.encode("utf-8"))
        record["evidenceSource"] = "rationale"
    else:
        evidence, _ = build_evidence(
            {"agent": agent_id, "seq": rpc_read(lambda: vc.functions.nextReceiptSeq().call()), "ts": int(time.time()), "src": "cadence"}
        )
        record["evidenceSource"] = "cadence"

    seq, receipt_tx = _publish_receipt(w3, account, vc, agent_id, evidence, period)
    record["receiptTx"] = receipt_tx
    record["seq"] = seq
    record["evidenceHash"] = _hex(w3, evidence)

    on_chain_ev, bound = _wait_for_evidence(w3, vc, record["evidenceHash"])
    nav_after = rpc_read(lambda: vc.functions.nav().call())
    rep_nav = rpc_read(lambda: vc.functions.reputableNav().call())
    rep, _ = rpc_read(lambda: ident.functions.getSummary(agent_id).call())
    record["onChainEvidenceHash"] = on_chain_ev
    record["navAfter"] = str(nav_after)
    record["reputableNav"] = str(rep_nav)
    record["reputation"] = str(rep)
    record["proofStatus"] = "bound" if bound else "MISMATCH"
    print(
        f"  receipt seq={seq} -> {receipt_tx} | bound={bound} "
        f"navAfter={nav_after} rep={rep}"
    )
    return agent_id, record, _proof_record(record)


def _write_outputs(
    out_dir: Path, proofbound: dict[str, dict[str, Any]], proofs: dict[str, dict[str, Any]]
) -> None:
    now = int(time.time())
    _atomic_write(out_dir / "proofbound.json", {"agents": proofbound, "updatedAt": now})
    _atomic_write(out_dir / "proofs.json", {"agents": proofs, "updatedAt": now})


def main() -> int:
    network = os.getenv("REEF_NETWORK", "mantle-sepolia")
    period = int(os.getenv("RECEIPT_PERIOD_S", "600"))
    action_bps = int(os.getenv("ACTION_BPS", "2000"))
    dry_run = os.getenv("DRY_RUN") == "1"
    out_dir = Path(os.getenv("API_OUT_DIR", str(REPO_ROOT / "ui" / "api")))

    chain = load_chain(network)
    data = json.loads((DEPLOYMENTS_DIR / f"{network}.json").read_text(encoding="utf-8"))
    seeded = data.get("seeded", {})
    asset = _asset_address(seeded)
    vaults = seeded.get("vaults", [])
    guard_addr = (data.get("reefGuard") or {}).get("address") or data.get("reefGuard")
    if not (asset and vaults and guard_addr):
        print("missing asset/vaults/reefGuard in deployments", file=sys.stderr)
        return 2

    w3 = get_w3(chain.rpc_url)
    account = None if dry_run else load_account()
    guard = _contract(w3, guard_addr, "ReefGuard")
    ident = identity_contract(w3, data["reef"]["AgentIdentity"])
    signal = _safe_fetch("market signal", lambda: fetch_signal("ETH"))
    prediction = _safe_fetch("Allora prediction", fetch_eth_prediction)
    flow = _safe_fetch("Nansen flow", fetch_smart_money_flow)
    states: list[dict[str, Any]] = []
    for vault_info in vaults:
        try:
            vc = vault_contract(w3, vault_info["vault"])
            states.append(
                {
                    "agentId": rpc_read(lambda vc=vc: vc.functions.agentId().call()),
                    "nav": rpc_read(lambda vc=vc: vc.functions.nav().call()),
                    "highWaterNav": rpc_read(
                        lambda vc=vc: vc.functions.highWaterNav().call()
                    ),
                }
            )
        except Exception as e:  # noqa: BLE001 - process_vault reports the full failure later
            print(
                f"vault {vault_info.get('vault')} state unavailable for GLM batch: {e}",
                file=sys.stderr,
            )
    decisions = _decide_all(states, signal, prediction, flow)

    proofbound: dict[str, dict[str, Any]] = {}
    proofs: dict[str, dict[str, Any]] = {}
    failures = 0
    for vault_info in vaults:
        try:
            agent_id, record, proof = _process_vault(
                w3=w3,
                account=account,
                vault_info=vault_info,
                seeded=seeded,
                asset=asset,
                guard=guard,
                ident=ident,
                decisions=decisions,
                action_bps=action_bps,
                period=period,
                dry_run=dry_run,
            )
            proofbound[str(agent_id)] = record
            if proof is not None:
                proofs[str(agent_id)] = proof
        except Exception as e:  # noqa: BLE001 - keep processing remaining vaults
            failures += 1
            agent_id = str(vault_info.get("agentId", "?"))
            print(f"vault {vault_info.get('vault')} FAILED: {e}", file=sys.stderr)
            proofbound[agent_id] = {
                "agentId": vault_info.get("agentId"),
                "vault": vault_info.get("vault"),
                "proofStatus": "failed",
                "error": str(e),
                "ts": int(time.time()),
            }

    if not dry_run and proofbound:
        _write_outputs(out_dir, proofbound, proofs)

    print(
        f"{len(proofs) if not dry_run else len(proofbound)}/{len(vaults)} "
        f"{'dry-run plans' if dry_run else 'proof-bound receipts'} processed"
    )
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
