#!/usr/bin/env python
"""Reef receipt loop — publish a fresh EIP-712-signed receipt to every seeded vault.

For each vault in deployments/<network>.json, signs a strict-sequence receipt with the
operator key (PRIVATE_KEY) and submits it. This advances on-chain cadence (lastReceiptAt),
so `agents.scripts.health` stays green, and credits reputation on any vault whose per-share
NAV set a new high since the last receipt (e.g. one wired to the MockYieldAdapter).

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
    failures = 0
    for v in vaults:
        vc = vault_contract(w3, v["vault"])
        try:
            agent_id = rpc_read(lambda: vc.functions.agentId().call())
            seq = rpc_read(lambda: vc.functions.nextReceiptSeq().call())
            evidence, _ = build_evidence(
                {
                    "agent": agent_id,
                    "seq": seq,
                    "ts": int(time.time()),
                    "src": "receipt-tick",
                }
            )
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
            print(f"agent {agent_id} vault {vc.address} receipt seq={seq} published")
        except Exception as e:  # noqa: BLE001 - keep ticking the remaining vaults
            failures += 1
            print(f"vault {v['vault']} FAILED: {e}", file=sys.stderr)

    print(f"{len(vaults) - failures}/{len(vaults)} receipts published")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
