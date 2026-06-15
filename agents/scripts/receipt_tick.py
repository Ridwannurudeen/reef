#!/usr/bin/env python
"""Reef receipt loop — EIP-712 receipts per vault, committed on-chain.

For each seeded vault, publish an EIP-712-signed receipt. When a recent agent
decision exists for that agent (in API_OUT_DIR/executions.json), the receipt's
evidence hash is keccak256(the verbatim rationale string) so anyone can recompute
the hash and match the vault's on-chain `lastReceiptEvidenceHash`. When no decision
is available the receipt falls back to a cheap cadence record (keeps lastReceiptAt
fresh / health green and credits NAV-derived reputation). This loop is the SOLE
on-chain receipt publisher, so it never races the strict per-vault sequence. No LLM
call is made here.

A per-agent proof summary is written to API_OUT_DIR/proofs.json
({agentId: {seq, evidenceHash, rationaleHash, reasoning, txHash, proofStatus}}).

Usage (from repo root):
    API_OUT_DIR=/opt/reef/web/api python -m agents.scripts.receipt_tick
Cron (every 10 min):
    */10 * * * * cd /opt/reef/app && API_OUT_DIR=/opt/reef/web/api python -m agents.scripts.receipt_tick >> /var/log/reef-tick.log 2>&1
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

from eth_utils import keccak

from agents.shared.client import get_w3, load_account, rpc_read, send_tx, vault_contract
from agents.shared.config import DEPLOYMENTS_DIR, REPO_ROOT, load_chain
from agents.shared.receipt import build_evidence, sign_receipt


def _latest_rationales(out_dir: Path) -> dict[int, dict]:
    """Map agentId -> latest executions.json record that carries a non-empty rationale."""
    path = out_dir / "executions.json"
    if not path.exists():
        return {}
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (ValueError, OSError):
        return {}
    out: dict[int, dict] = {}
    for rec in doc.get("executions", []):  # newest first
        try:
            aid = int(rec.get("agent"))
        except (TypeError, ValueError):
            continue
        if aid in out:
            continue
        if (rec.get("reasoning") or "").strip():
            out[aid] = rec
    return out


def _atomic_write(path: Path, doc: dict) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(doc, indent=2), encoding="utf-8")
    os.replace(tmp, path)


def main() -> int:
    network = os.getenv("REEF_NETWORK", "mantle-sepolia")
    period = int(os.getenv("RECEIPT_PERIOD_S", "600"))
    bind_max_age = int(os.getenv("RECEIPT_BIND_MAX_AGE_S", "21600"))
    out_dir = Path(os.getenv("API_OUT_DIR", str(REPO_ROOT / "ui" / "api")))
    chain = load_chain(network)
    data = json.loads((DEPLOYMENTS_DIR / f"{network}.json").read_text(encoding="utf-8"))
    vaults = data.get("seeded", {}).get("vaults", [])
    if not vaults:
        print("no seeded vaults in deployment file", file=sys.stderr)
        return 2

    rationales = _latest_rationales(out_dir)
    w3 = get_w3(chain.rpc_url)
    account = load_account()
    chain_id = w3.eth.chain_id
    published = 0
    failures = 0
    proofs: dict[str, dict] = {}
    for v in vaults:
        vc = vault_contract(w3, v["vault"])
        try:
            agent_id = rpc_read(lambda vc=vc: vc.functions.agentId().call())
            seq = rpc_read(lambda vc=vc: vc.functions.nextReceiptSeq().call())
            rec = rationales.get(agent_id)
            # Only bind a FRESH rationale; a stale one falls back to a liveness
            # receipt so proofStatus "matched" never overstates decision freshness.
            fresh = (
                bool(rec) and (int(time.time()) - int(rec.get("ts", 0))) <= bind_max_age
            )
            reasoning = rec.get("reasoning") if (rec and fresh) else None
            bound = bool(reasoning and reasoning.strip())
            if bound:
                # Bind the on-chain evidence to the verbatim rationale.
                evidence = keccak(reasoning.encode("utf-8"))
            else:
                # No decision for this agent yet: cheap cadence receipt (liveness).
                evidence, _ = build_evidence(
                    {
                        "agent": agent_id,
                        "seq": seq,
                        "ts": int(time.time()),
                        "src": "cadence",
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
            receipt = send_tx(w3, account, vc.functions.publishReceipt(*args))
            tx_hash = w3.to_hex(receipt["transactionHash"])
            ev_hex = "0x" + evidence.hex()
            proofs[str(agent_id)] = {
                "seq": seq,
                "evidenceHash": ev_hex,
                "rationaleHash": ev_hex if bound else None,
                "reasoning": reasoning if bound else None,
                "source": (rec or {}).get("source") if bound else None,
                "model": (rec or {}).get("model") if bound else None,
                "txHash": tx_hash,
                "proofStatus": "matched" if bound else "liveness-only",
                "ts": int(time.time()),
            }
            published += 1
            print(
                f"agent {agent_id} {'rationale-bound' if bound else 'cadence'} receipt seq={seq} published"
            )
        except Exception as e:  # noqa: BLE001 - keep ticking the remaining vaults
            failures += 1
            print(f"vault {v['vault']} FAILED: {e}", file=sys.stderr)

    if proofs:
        out_dir.mkdir(parents=True, exist_ok=True)
        _atomic_write(
            out_dir / "proofs.json", {"agents": proofs, "updatedAt": int(time.time())}
        )

    print(f"{published}/{len(vaults)} receipts published")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
