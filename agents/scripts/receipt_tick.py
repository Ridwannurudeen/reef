#!/usr/bin/env python
"""Reef receipt loop — a real LLM decision per vault, committed on-chain + verifiable.

For each seeded vault: read its on-chain NAV state, ask the configured LLM (Z.ai GLM by
default) for an allocation action + plain-English rationale, then publish an EIP-712-signed
receipt whose evidence hash = keccak(the decision record). The full rationale is written
verbatim to API_OUT_DIR/decisions.json, so anyone can recompute the hash and verify the
published reasoning matches what was committed on-chain. Advances cadence (health stays
green) and credits NAV-derived, high-water-mark reputation.

Usage (from repo root):
    python -m agents.scripts.receipt_tick
    API_OUT_DIR=/opt/reef/web/api python -m agents.scripts.receipt_tick   # publish rationale feed
Cron (every 10 min):
    */10 * * * * cd /opt/reef/app && API_OUT_DIR=/opt/reef/web/api python -m agents.scripts.receipt_tick >> /var/log/reef-tick.log 2>&1
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
from agents.shared.receipt import build_evidence, sign_receipt


def main() -> int:
    network = os.getenv("REEF_NETWORK", "mantle-sepolia")
    period = int(os.getenv("RECEIPT_PERIOD_S", "600"))
    model = os.getenv("ZAI_MODEL") or "glm-4.7-flash"
    out_dir = Path(os.getenv("API_OUT_DIR", str(REPO_ROOT / "ui" / "api")))
    chain = load_chain(network)
    data = json.loads((DEPLOYMENTS_DIR / f"{network}.json").read_text(encoding="utf-8"))
    vaults = data.get("seeded", {}).get("vaults", [])
    if not vaults:
        print("no seeded vaults in deployment file", file=sys.stderr)
        return 2

    w3 = get_w3(chain.rpc_url)
    account = load_account()
    chain_id = w3.eth.chain_id
    decisions = []
    failures = 0
    for v in vaults:
        vc = vault_contract(w3, v["vault"])
        try:
            agent_id = rpc_read(lambda: vc.functions.agentId().call())
            seq = rpc_read(lambda: vc.functions.nextReceiptSeq().call())
            nav = rpc_read(lambda: vc.functions.nav().call())
            hwm = rpc_read(lambda: vc.functions.highWaterNav().call())

            d = decide_for_vault(agent_id, nav, hwm)
            # The record IS the on-chain evidence preimage — publish it verbatim so the
            # rationale is verifiable: keccak(canonical_json(record)) == evidenceHash.
            record = {
                "agent": agent_id,
                "seq": seq,
                "action": d.action,
                "navDeltaBps": d.nav_delta_bps,
                "reasoning": d.reasoning,
                "source": d.source,
                "model": model if d.source == "glm" else "deterministic-fallback",
                "ts": int(time.time()),
            }
            evidence, _ = build_evidence(record)
            args = sign_receipt(
                account.key,
                vault=vc.address,
                chain_id=chain_id,
                agent_id=agent_id,
                seq=seq,
                evidence_hash=evidence,
                claimed_delta=d.nav_delta_bps,
                period=period,
            )
            receipt = send_tx(w3, account, vc.functions.publishReceipt(*args))
            decisions.append(
                {
                    **record,
                    "vault": vc.address,
                    "evidenceHash": "0x" + evidence.hex(),
                    "txHash": receipt["transactionHash"].hex(),
                }
            )
            print(
                f"agent {agent_id} [{d.source}] {d.action} {d.nav_delta_bps}bps seq={seq}: {d.reasoning[:80]}"
            )
        except Exception as e:  # noqa: BLE001 - keep ticking the remaining vaults
            failures += 1
            print(f"vault {v['vault']} FAILED: {e}", file=sys.stderr)

    if decisions:
        out_dir.mkdir(parents=True, exist_ok=True)
        (out_dir / "decisions.json").write_text(
            json.dumps(
                {"updatedAt": int(time.time()), "decisions": decisions}, indent=2
            ),
            encoding="utf-8",
        )
    print(f"{len(decisions)}/{len(vaults)} receipts published")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
