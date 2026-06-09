#!/usr/bin/env python
"""Reef receipt loop — a cheap, deterministic cadence receipt per vault, committed on-chain.

For each seeded vault: read its on-chain state and publish an EIP-712-signed receipt whose
evidence hash = keccak(a small cadence record). This makes NO LLM call — it keeps every
vault's lastReceiptAt fresh (health stays green) and credits NAV-derived, high-water-mark
reputation without pressuring the free-tier rate limit. The live GLM decisions + real trades
(with verbatim rationale committed on-chain as the evidence hash) run in the rotating
`execute_decision` loop and are served at API_OUT_DIR/executions.json.

Usage (from repo root):
    python -m agents.scripts.receipt_tick
Cron (every 10 min):
    */10 * * * * cd /opt/reef/app && python -m agents.scripts.receipt_tick >> /var/log/reef-tick.log 2>&1
"""

from __future__ import annotations

import json
import os
import sys
import time

from agents.shared.client import get_w3, load_account, rpc_read, send_tx, vault_contract
from agents.shared.config import DEPLOYMENTS_DIR, load_chain
from agents.shared.receipt import build_evidence, sign_receipt


def main() -> int:
    network = os.getenv("REEF_NETWORK", "mantle-sepolia")
    period = int(os.getenv("RECEIPT_PERIOD_S", "600"))
    chain = load_chain(network)
    data = json.loads((DEPLOYMENTS_DIR / f"{network}.json").read_text(encoding="utf-8"))
    vaults = data.get("seeded", {}).get("vaults", [])
    if not vaults:
        print("no seeded vaults in deployment file", file=sys.stderr)
        return 2

    w3 = get_w3(chain.rpc_url)
    account = load_account()
    chain_id = w3.eth.chain_id
    published = 0
    failures = 0
    for v in vaults:
        vc = vault_contract(w3, v["vault"])
        try:
            agent_id = rpc_read(lambda: vc.functions.agentId().call())
            seq = rpc_read(lambda: vc.functions.nextReceiptSeq().call())
            # Cheap deterministic cadence receipt (no LLM call): keeps every vault's
            # lastReceiptAt fresh (health green) and credits NAV-derived reputation. The
            # GLM decisions + real trades live in the rotating execute_decision loop, so
            # this loop makes no LLM calls and never pressures the free-tier rate limit.
            record = {
                "agent": agent_id,
                "seq": seq,
                "ts": int(time.time()),
                "src": "cadence",
            }
            evidence, _ = build_evidence(record)
            args = sign_receipt(
                account.key,
                vault=vc.address,
                chain_id=chain_id,
                agent_id=agent_id,
                seq=seq,
                evidence_hash=evidence,
                claimed_delta=0,
                period=period,
            )
            send_tx(w3, account, vc.functions.publishReceipt(*args))
            published += 1
            print(f"agent {agent_id} cadence receipt seq={seq} published")
        except Exception as e:  # noqa: BLE001 - keep ticking the remaining vaults
            failures += 1
            print(f"vault {v['vault']} FAILED: {e}", file=sys.stderr)

    print(f"{published}/{len(vaults)} cadence receipts published")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
