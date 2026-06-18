#!/usr/bin/env python
"""Veto proof packet — compose blocked, approved, execution, and receipt evidence.

Writes API_OUT_DIR/veto-proof.json for the homepage and transparency page. The
blocked/approved legs are read-only ReefGuard.eth_call checks; execution/receipt
legs are composed from proofbound.json + proofs.json and chain-read receipt state.

Usage: API_OUT_DIR=/opt/reef/web/api python -m agents.scripts.veto_proof_snapshot
"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path
from typing import Any

from eth_utils import keccak

from agents.shared.client import get_w3, rpc_read, vault_contract
from agents.shared.config import DEPLOYMENTS_DIR, REPO_ROOT, load_chain

_GUARD_ABI = [
    {
        "name": "canExecute",
        "inputs": [{"type": "uint256"}, {"type": "address"}, {"type": "uint256"}],
        "outputs": [{"type": "bool"}, {"type": "string"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "name": "maxSizeBps",
        "inputs": [],
        "outputs": [{"type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    },
]

CHECK_SIZE_BPS = 3000
BLOCKED_SIZE_MARGIN_BPS = 1500


def _load(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def _atomic_write(path: Path, doc: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(doc, indent=2), encoding="utf-8")
    os.replace(tmp, path)


def _asset_address(seeded: dict[str, Any]) -> str | None:
    raw = seeded.get("asset")
    return raw.get("address") if isinstance(raw, dict) else raw


def _explorer(data: dict[str, Any]) -> str:
    ex = data.get("explorer") or {}
    if isinstance(ex, str):
        return ex.rstrip("/")
    return str(ex.get("mantlescan") or ex.get("blockscout") or "").rstrip("/")


def _tx_url(base: str, tx: str | None) -> str | None:
    return f"{base}/tx/{tx}" if base and tx else None


def _address_url(base: str, address: str | None) -> str | None:
    return f"{base}/address/{address}" if base and address else None


def _call_doc(w3, guard, *, agent_id: int, asset: str, size_bps: int, chain_id: int):
    fn = guard.functions.canExecute(agent_id, asset, size_bps)
    allowed, reason = rpc_read(lambda: fn.call())
    return {
        "agentId": agent_id,
        "asset": asset,
        "sizeBps": size_bps,
        "allowed": bool(allowed),
        "reason": reason,
        "evidence": "read-only eth_call",
        "call": {
            "chainId": chain_id,
            "to": guard.address,
            "data": fn._encode_transaction_data(),
            "function": "canExecute(uint256,address,uint256)",
        },
    }


def _latest_record(records: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    items = [(aid, rec) for aid, rec in records.items() if isinstance(rec, dict)]
    if not items:
        return "", {}
    return max(items, key=lambda item: int(item[1].get("ts") or 0))


def _execution_doc(base: str, record: dict[str, Any]) -> dict[str, Any]:
    deploy_tx = record.get("deployTx")
    recall_tx = record.get("recallTx")
    tx = deploy_tx or recall_tx
    kind = (
        "deployToStrategy" if deploy_tx else "recallFromStrategy" if recall_tx else None
    )
    move_status = record.get("moveStatus") or "not-recorded"
    if tx:
        status = "transaction-backed"
    elif move_status in {"hold", "nothing-to-recall", "no-idle"}:
        status = "not-required"
    else:
        status = "not-recorded"
    return {
        "action": record.get("action"),
        "navDeltaBps": record.get("navDeltaBps"),
        "moveStatus": move_status,
        "status": status,
        "txHash": tx,
        "txUrl": _tx_url(base, tx),
        "function": kind,
        "adapter": record.get("adapter"),
        "adapterUrl": _address_url(base, record.get("adapter")),
        "note": "Latest compliant plan was hold, so no adapter movement transaction was required."
        if status == "not-required"
        else None,
    }


def _verifier_doc(
    w3, base: str, record: dict[str, Any], proof: dict[str, Any]
) -> dict[str, Any]:
    rationale = record.get("rationale") or proof.get("reasoning") or ""
    recomputed = "0x" + keccak(rationale.encode("utf-8")).hex() if rationale else None
    evidence = record.get("evidenceHash") or proof.get("evidenceHash")
    proof_hash = proof.get("rationaleHash")
    receipt_hash = record.get("onChainEvidenceHash") or proof.get("evidenceHash")
    chain_hash = None
    chain_read_error = None
    vault = record.get("vault")
    if vault:
        try:
            vc = vault_contract(w3, vault)
            chain_hash = (
                "0x"
                + rpc_read(lambda: vc.functions.lastReceiptEvidenceHash().call()).hex()
            )
        except Exception as exc:  # noqa: BLE001 - publish the failed read explicitly
            chain_read_error = str(exc)
    all_match = bool(
        recomputed
        and evidence
        and proof_hash
        and receipt_hash
        and chain_hash
        and recomputed.lower()
        == evidence.lower()
        == proof_hash.lower()
        == receipt_hash.lower()
        == chain_hash.lower()
    )
    return {
        "status": "matched" if all_match else "mismatch",
        "rationaleHash": recomputed,
        "evidenceHash": evidence,
        "proofRationaleHash": proof_hash,
        "receiptEvidenceHash": receipt_hash,
        "vaultEvidenceHash": chain_hash,
        "chainReadError": chain_read_error,
        "proofStatus": proof.get("proofStatus"),
        "receiptTx": record.get("receiptTx") or proof.get("txHash"),
        "receiptTxUrl": _tx_url(base, record.get("receiptTx") or proof.get("txHash")),
    }


def main() -> int:
    network = os.getenv("REEF_NETWORK", "mantle-sepolia")
    out_dir = Path(os.getenv("API_OUT_DIR", str(REPO_ROOT / "ui" / "api")))
    chain = load_chain(network)
    data = _load(DEPLOYMENTS_DIR / f"{network}.json")
    seeded = data.get("seeded") or {}
    rg = data.get("reefGuard") or {}
    asset = _asset_address(seeded) or rg.get("asset")
    if not asset or not rg.get("address"):
        raise RuntimeError("missing reefGuard or asset in deployment")

    proofbound = _load(out_dir / "proofbound.json").get("agents") or {}
    proofs = _load(out_dir / "proofs.json").get("agents") or {}
    guard_doc = _load(out_dir / "guard.json")
    blocked_seed = guard_doc.get("blockedAction") or {}
    latest_agent, latest = _latest_record(proofbound)
    agent_id = int(blocked_seed.get("agentId") or latest_agent or 1)
    record = proofbound.get(str(agent_id)) or latest
    if not record:
        raise RuntimeError("no proofbound record available")
    proof = proofs.get(str(agent_id)) or {}

    w3 = get_w3(chain.rpc_url)
    guard = w3.eth.contract(
        address=w3.to_checksum_address(rg["address"]), abi=_GUARD_ABI
    )
    asset = w3.to_checksum_address(asset)
    max_size_bps = int(rpc_read(lambda: guard.functions.maxSizeBps().call()))
    blocked_size_bps = int(
        blocked_seed.get("requestedSizeBps") or max_size_bps + BLOCKED_SIZE_MARGIN_BPS
    )
    approved_size_bps = int(
        blocked_seed.get("approvedSizeBps") or min(CHECK_SIZE_BPS, max_size_bps)
    )
    base = _explorer(data)

    blocked = _call_doc(
        w3,
        guard,
        agent_id=agent_id,
        asset=asset,
        size_bps=blocked_size_bps,
        chain_id=chain.chain_id,
    )
    approved = _call_doc(
        w3,
        guard,
        agent_id=agent_id,
        asset=asset,
        size_bps=approved_size_bps,
        chain_id=chain.chain_id,
    )

    doc = {
        "network": chain.name,
        "chainId": chain.chain_id,
        "agentId": agent_id,
        "vault": record.get("vault"),
        "vaultUrl": _address_url(base, record.get("vault")),
        "rationale": record.get("rationale") or proof.get("reasoning"),
        "source": record.get("source") or proof.get("source"),
        "model": record.get("model") or proof.get("model"),
        "blockedAction": blocked,
        "approvedAction": approved,
        "execution": _execution_doc(base, record),
        "receipt": {
            "seq": record.get("seq") or proof.get("seq"),
            "txHash": record.get("receiptTx") or proof.get("txHash"),
            "txUrl": _tx_url(base, record.get("receiptTx") or proof.get("txHash")),
            "evidenceHash": record.get("evidenceHash") or proof.get("evidenceHash"),
            "onChainEvidenceHash": record.get("onChainEvidenceHash"),
            "proofStatus": record.get("proofStatus") or proof.get("proofStatus"),
        },
        "verifier": _verifier_doc(w3, base, record, proof),
        "labels": {
            "blockedAction": "read-only eth_call; no transaction sent",
            "approvedAction": "read-only eth_call; no transaction sent",
            "execution": "transaction-backed only when deployTx or recallTx is present",
            "receipt": "on-chain AgentVault.publishReceipt transaction",
        },
        "updatedAt": int(time.time()),
    }
    _atomic_write(out_dir / "veto-proof.json", doc)
    print(
        "veto-proof: "
        f"agent {agent_id} blocked={blocked['allowed']} approved={approved['allowed']} "
        f"verifier={doc['verifier']['status']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
