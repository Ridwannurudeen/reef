#!/usr/bin/env python
"""Reef proof-bound rebalance — the unified, sole-publisher allocation loop.

For ONE agent vault, in a single atomic, on-chain-verifiable sequence:

  1. decide        — GLM (or deterministic fallback) picks an allocation action + rationale
  2. gate          — ReefGuard.canExecute(agentId, asset, sizeBps); if it refuses, STOP (no move)
  3. move capital  — deployToStrategy / recallFromStrategy through the vault's APPROVED adapter
                     (NAV-affecting; recall REALIZES gains into reputable NAV)
  4. bind proof    — publishReceipt with evidenceHash == keccak256(verbatim rationale), so
                     anyone can recompute the hash and match the vault's lastReceiptEvidenceHash
  5. reputation    — credited on-chain from REALIZED (donation-proof) NAV only

Unlike the legacy split (execute_decision swaps to the operator wallet off-chain; receipt_tick
binds the rationale later), this is the decision, the capital move, and the proof in ONE loop —
and it is the SOLE receipt publisher for the agent it runs on, so it must NOT run concurrently
with receipt_tick for that agent (pause that cron first).

Writes API_OUT_DIR/proofbound.json keyed by agentId with the full evidence trail.

Usage (crons paused; PRIVATE_KEY = the agent operator key):
    API_OUT_DIR=ui/api python -m agents.scripts.proofbound_rebalance
    DRY_RUN=1 python -m agents.scripts.proofbound_rebalance      # plan only, no txs
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

from eth_utils import keccak

from agents.shared.allora import fetch_eth_prediction
from agents.shared.brain import decide_for_vault
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
from agents.shared.nansen import fetch_smart_money_flow
from agents.shared.signal import fetch_signal


def _contract(w3, address, abi_name):
    return w3.eth.contract(
        address=w3.to_checksum_address(address), abi=load_abi(abi_name)
    )


def _atomic_write(path: Path, doc: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(doc, indent=2), encoding="utf-8")
    os.replace(tmp, path)


def main() -> int:
    network = os.getenv("REEF_NETWORK", "mantle-sepolia")
    period = int(os.getenv("RECEIPT_PERIOD_S", "600"))
    action_bps = int(os.getenv("ACTION_BPS", "2000"))  # default 20% of vault capital
    dry_run = os.getenv("DRY_RUN") == "1"
    out_dir = Path(os.getenv("API_OUT_DIR", str(REPO_ROOT / "ui" / "api")))

    chain = load_chain(network)
    data = json.loads((DEPLOYMENTS_DIR / f"{network}.json").read_text(encoding="utf-8"))
    seeded = data.get("seeded", {})
    _asset = seeded.get("asset")
    asset = _asset.get("address") if isinstance(_asset, dict) else _asset
    ya = seeded.get("yieldAdapter") or {}
    adapter = ya.get("address")
    # Target the vault that actually has an approved strategy adapter, unless overridden.
    target_vault = os.getenv("VAULT") or ya.get("vault")
    guard_addr = (data.get("reefGuard") or {}).get("address") or data.get("reefGuard")
    if not (asset and adapter and target_vault and guard_addr):
        print("missing asset/adapter/vault/reefGuard in deployments", file=sys.stderr)
        return 2

    w3 = get_w3(chain.rpc_url)
    account = load_account()
    vc = vault_contract(w3, target_vault)
    guard = _contract(w3, guard_addr, "ReefGuard")
    erc20 = _contract(w3, asset, "MockERC20")
    ident = identity_contract(w3, data["reef"]["AgentIdentity"])

    agent_id = rpc_read(lambda: vc.functions.agentId().call())
    nav_before = rpc_read(lambda: vc.functions.nav().call())
    hwm = rpc_read(lambda: vc.functions.highWaterNav().call())
    idle = rpc_read(
        lambda: erc20.functions.balanceOf(w3.to_checksum_address(target_vault)).call()
    )
    current_strategy = rpc_read(lambda: vc.functions.currentStrategy().call())

    signal = fetch_signal("ETH")
    prediction = fetch_eth_prediction()
    flow = fetch_smart_money_flow()
    d = decide_for_vault(agent_id, nav_before, hwm, signal, prediction, flow)

    # Size the action in bps of vault capital, clamped to the guard's max.
    max_bps = rpc_read(lambda: guard.functions.maxSizeBps().call())
    size_bps = max(1, min(action_bps, int(max_bps)))

    allowed, reason = rpc_read(
        lambda: guard.functions.canExecute(
            agent_id, w3.to_checksum_address(asset), size_bps
        ).call()
    )

    record: dict = {
        "agentId": agent_id,
        "vault": w3.to_checksum_address(target_vault),
        "action": d.action,
        "navDeltaBps": d.nav_delta_bps,
        "rationale": d.reasoning,
        "source": d.source,
        "guard": {"allowed": bool(allowed), "reason": reason, "sizeBps": size_bps},
        "navBefore": str(nav_before),
        "ts": int(time.time()),
    }
    print(
        f"agent {agent_id}: [{d.source}] {d.action} {d.nav_delta_bps}bps | guard={allowed} ({reason})"
    )
    print(f"  rationale: {d.reasoning[:90]}")

    if not allowed:
        record["proofStatus"] = "guard-refused"
        print("  -> ReefGuard refused; no capital moved, no receipt published.")
        _write(out_dir, agent_id, record)
        return 0

    deploy_amt = (idle * size_bps) // 10_000
    if dry_run:
        plan = "hold"
        if d.action == "increase" and deploy_amt > 0:
            plan = f"deployToStrategy({deploy_amt})"
        elif d.action == "decrease":
            plan = "recallFromStrategy(realize)"
        print(f"  DRY_RUN plan: gate OK -> {plan} -> publishReceipt(keccak(rationale))")
        record["proofStatus"] = "dry-run"
        return 0

    # --- 3. Move real capital through the approved adapter (NAV-affecting) ---
    if (
        d.action == "increase"
        and deploy_amt > 0
        and current_strategy
        in (
            "0x0000000000000000000000000000000000000000",
            w3.to_checksum_address(adapter),
        )
    ):
        r = send_tx(
            w3,
            account,
            vc.functions.deployToStrategy(w3.to_checksum_address(adapter), deploy_amt),
        )
        record["deployTx"] = w3.to_hex(r["transactionHash"])
        print(f"  deployToStrategy {deploy_amt} -> {record['deployTx']}")
    elif d.action == "decrease" and current_strategy == w3.to_checksum_address(adapter):
        underlying = rpc_read(
            lambda: (
                _contract(w3, adapter, "MockStrategyAdapter")
                .functions.totalUnderlying()
                .call()
            )
        )
        recall_amt = (underlying * size_bps) // 10_000
        if recall_amt > 0:
            r = send_tx(
                w3,
                account,
                vc.functions.recallFromStrategy(
                    w3.to_checksum_address(adapter), recall_amt
                ),
            )
            record["recallTx"] = w3.to_hex(r["transactionHash"])
            print(
                f"  recallFromStrategy {recall_amt} (realized) -> {record['recallTx']}"
            )

    # --- 4. Bind the verbatim rationale on-chain as the receipt evidence ---
    evidence = keccak(d.reasoning.encode("utf-8"))
    seq = rpc_read(lambda: vc.functions.nextReceiptSeq().call())
    from agents.shared.receipt import sign_receipt

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
    r = send_tx(w3, account, vc.functions.publishReceipt(*args))
    record["receiptTx"] = w3.to_hex(r["transactionHash"])
    record["seq"] = seq
    record["evidenceHash"] = "0x" + evidence.hex()

    # --- 5. Read the results + self-verify the binding on-chain ---
    on_chain_ev = rpc_read(lambda: vc.functions.lastReceiptEvidenceHash().call())
    nav_after = rpc_read(lambda: vc.functions.nav().call())
    rep_nav = rpc_read(lambda: vc.functions.reputableNav().call())
    rep, _ = rpc_read(lambda: ident.functions.getSummary(agent_id).call())
    bound = ("0x" + on_chain_ev.hex()) == record["evidenceHash"]
    record["navAfter"] = str(nav_after)
    record["reputableNav"] = str(rep_nav)
    record["reputation"] = str(rep)
    record["proofStatus"] = "bound" if bound else "MISMATCH"
    print(
        f"  receipt seq={seq} -> {record['receiptTx']} | bound={bound} "
        f"navAfter={nav_after} rep={rep}"
    )
    _write(out_dir, agent_id, record)
    return 0 if bound else 1


def _write(out_dir: Path, agent_id: int, record: dict) -> None:
    path = out_dir / "proofbound.json"
    doc = {"agents": {}, "updatedAt": int(time.time())}
    if path.exists():
        try:
            doc = json.loads(path.read_text(encoding="utf-8"))
            doc.setdefault("agents", {})
        except (ValueError, OSError):
            pass
    doc["agents"][str(agent_id)] = record
    doc["updatedAt"] = int(time.time())
    _atomic_write(path, doc)


if __name__ == "__main__":
    raise SystemExit(main())
