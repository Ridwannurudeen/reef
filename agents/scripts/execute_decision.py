#!/usr/bin/env python
"""Real-execution agent: GLM decides, the agent executes a real swap on Mantle, on the record.

For one seeded vault, ask Z.ai GLM for an allocation decision (from on-chain NAV state); if the
action is "increase", execute a REAL FusionX V2 swap on Mantle Sepolia (native MNT -> USDC, no
real funds), then publish an EIP-712 receipt whose evidence commits keccak(decision + execution)
on-chain, and append the record to API_OUT_DIR/executions.json. The swap txHash is independently
verifiable on Mantlescan; the rationale is verifiable against the on-chain evidence hash.

Scope (honest): this proves an AI agent making AND executing real on-chain trades on a Mantle-native
DEX. The swap acquires tokens to the operator wallet (agent-level execution); routing trades into
vault NAV via a strategy adapter is a deeper follow-up.

Usage (from repo root, with ZAI_* + PRIVATE_KEY in .env):
    python -m agents.scripts.execute_decision                 # first seeded vault
    AGENT_INDEX=1 EXEC_MNT=0.02 python -m agents.scripts.execute_decision
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path


from agents.shared.brain import decide_for_vault
from agents.shared.client import get_w3, load_account, rpc_read, send_tx, vault_contract
from agents.shared.config import DEPLOYMENTS_DIR, REPO_ROOT, load_chain
from agents.shared.dex import load_dex, swap_native_for_token
from agents.shared.receipt import build_evidence, sign_receipt


def main() -> int:
    network = os.getenv("REEF_NETWORK", "mantle-sepolia")
    idx = int(os.getenv("AGENT_INDEX", "0"))
    exec_mnt = float(os.getenv("EXEC_MNT", "0.02"))
    period = int(os.getenv("RECEIPT_PERIOD_S", "600"))
    model = os.getenv("ZAI_MODEL") or "glm-4.7-flash"
    out_dir = Path(os.getenv("API_OUT_DIR", str(REPO_ROOT / "ui" / "api")))

    chain = load_chain(network)
    data = json.loads((DEPLOYMENTS_DIR / f"{network}.json").read_text(encoding="utf-8"))
    vaults = data.get("seeded", {}).get("vaults", [])
    if not vaults:
        print("no seeded vaults", file=sys.stderr)
        return 2
    dex = load_dex(network)

    w3 = get_w3(chain.rpc_url)
    account = load_account()
    v = vaults[idx % len(vaults)]
    vc = vault_contract(w3, v["vault"])
    agent_id = rpc_read(lambda: vc.functions.agentId().call())
    nav = rpc_read(lambda: vc.functions.nav().call())
    hwm = rpc_read(lambda: vc.functions.highWaterNav().call())

    d = decide_for_vault(agent_id, nav, hwm)
    print(
        f"agent {agent_id} [{d.source}] decision: {d.action} {d.nav_delta_bps}bps — {d.reasoning[:90]}"
    )

    execution = None
    if d.action == "increase":
        amount_wei = w3.to_wei(exec_mnt, "ether")
        execution = swap_native_for_token(w3, account, dex, dex["usdc"], amount_wei)
        print(f"  EXECUTED real swap: {exec_mnt} MNT -> USDC tx {execution['txHash']}")
    else:
        print(f"  no trade (action={d.action}); recording decision only")

    record = {
        "agent": agent_id,
        "action": d.action,
        "navDeltaBps": d.nav_delta_bps,
        "reasoning": d.reasoning,
        "source": d.source,
        "model": model if d.source == "glm" else "deterministic-fallback",
        "execution": execution,
        "ts": int(time.time()),
    }
    # Commit keccak(record) on-chain as the receipt evidence (retry once on a seq race).
    for attempt in range(2):
        seq = rpc_read(lambda: vc.functions.nextReceiptSeq().call())
        evidence, _ = build_evidence({**record, "seq": seq})
        args = sign_receipt(
            account.key,
            vault=vc.address,
            chain_id=w3.eth.chain_id,
            agent_id=agent_id,
            seq=seq,
            evidence_hash=evidence,
            claimed_delta=d.nav_delta_bps,
            period=period,
        )
        try:
            receipt = send_tx(w3, account, vc.functions.publishReceipt(*args))
            record.update(
                seq=seq,
                evidenceHash="0x" + evidence.hex(),
                receiptTx=receipt["transactionHash"].hex(),
            )
            break
        except Exception as e:  # noqa: BLE001 - retry once if the cron raced the sequence
            if attempt == 0 and "bad seq" in str(e):
                continue
            print(f"receipt publish failed: {e}", file=sys.stderr)
            return 1

    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "executions.json"
    log = (
        json.loads(path.read_text(encoding="utf-8"))
        if path.exists()
        else {"executions": []}
    )
    log["executions"] = ([record] + log.get("executions", []))[:25]
    log["updatedAt"] = int(time.time())
    path.write_text(json.dumps(log, indent=2), encoding="utf-8")
    print(
        f"recorded decision+execution for agent {agent_id} (receipt seq {record.get('seq')})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
