"""EIP-712 receipt signing for AgentVault.publishReceipt.

The on-chain `publishReceipt(uint256 seq, bytes32 evidenceHash, int256 claimedDelta,
uint64 period, bytes signature)` verifies a typed-data signature recovered to the
agent's operator. Anyone (a keeper/relayer) may submit the signed receipt, so agents
need not hold gas. The domain is per-vault (verifyingContract = the vault), matching
`AgentVault`'s `_buildDomainSeparator`.
"""

from __future__ import annotations

import json
from typing import Any

from eth_account import Account
from eth_utils import keccak

_RECEIPT_TYPES = {
    "EIP712Domain": [
        {"name": "name", "type": "string"},
        {"name": "version", "type": "string"},
        {"name": "chainId", "type": "uint256"},
        {"name": "verifyingContract", "type": "address"},
    ],
    "Receipt": [
        {"name": "agentId", "type": "uint256"},
        {"name": "seq", "type": "uint256"},
        {"name": "evidenceHash", "type": "bytes32"},
        {"name": "claimedDelta", "type": "int256"},
        {"name": "period", "type": "uint64"},
    ],
}


def canonical_json(obj: Any) -> bytes:
    """Deterministic JSON encoding: sorted keys, no whitespace, UTF-8."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), default=str).encode(
        "utf-8"
    )


def build_evidence(decision: dict[str, Any]) -> tuple[bytes, dict[str, Any]]:
    """Hash a decision dict into a bytes32 evidence hash.

    Returns the 32-byte keccak digest and the canonical decision dict (handy for
    off-chain logs / IPFS pinning later).
    """
    digest = keccak(canonical_json(decision))
    assert len(digest) == 32
    return digest, decision


def sign_receipt(
    private_key,
    *,
    vault: str,
    chain_id: int,
    agent_id: int,
    seq: int,
    evidence_hash: bytes,
    claimed_delta: int,
    period: int,
) -> tuple[int, bytes, int, int, bytes]:
    """EIP-712-sign a Receipt; return the publishReceipt args tuple
    (seq, evidenceHash, claimedDelta, period, signature)."""
    if not isinstance(evidence_hash, (bytes, bytearray)) or len(evidence_hash) != 32:
        raise ValueError("evidence_hash must be 32 bytes")
    if seq < 0 or not 0 <= period < 2**64 or not -(2**255) <= claimed_delta < 2**255:
        raise ValueError("receipt field out of range")

    typed = {
        "types": _RECEIPT_TYPES,
        "primaryType": "Receipt",
        "domain": {
            "name": "Reef AgentVault",
            "version": "1",
            "chainId": int(chain_id),
            "verifyingContract": vault,
        },
        "message": {
            "agentId": int(agent_id),
            "seq": int(seq),
            "evidenceHash": bytes(evidence_hash),
            "claimedDelta": int(claimed_delta),
            "period": int(period),
        },
    }
    signed = Account.sign_typed_data(private_key, full_message=typed)
    return (
        int(seq),
        bytes(evidence_hash),
        int(claimed_delta),
        int(period),
        bytes(signed.signature),
    )
