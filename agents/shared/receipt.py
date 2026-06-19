"""EIP-712 receipt signing for AgentVault.publishReceipt.

The on-chain `publishReceipt((...), bytes signature)` verifies a typed-data
signature recovered to the agent's operator. The signed receipt binds a complete
off-chain evidence envelope by hash, an action/policy/execution/outcome context,
a decision timestamp, an expiry, and a content-addressed evidence URI hash.
"""

from __future__ import annotations

import json
import os
import time
from typing import Any

from eth_abi import encode
from eth_account import Account
from eth_utils import keccak

ZERO_HASH = b"\x00" * 32

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
        {"name": "contextHash", "type": "bytes32"},
        {"name": "decisionTimestamp", "type": "uint64"},
        {"name": "validUntil", "type": "uint64"},
        {"name": "period", "type": "uint64"},
        {"name": "decisionBlock", "type": "uint256"},
        {"name": "claimedDelta", "type": "int256"},
    ],
}


def canonical_json(obj: Any) -> bytes:
    """Deterministic JSON encoding: sorted keys, no whitespace, UTF-8."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), default=str).encode(
        "utf-8"
    )


def build_evidence(decision: dict[str, Any]) -> tuple[bytes, dict[str, Any]]:
    """Hash a canonical evidence envelope into a bytes32 evidence hash.

    Returns the 32-byte keccak digest and the canonical envelope dict.
    """
    digest = keccak(canonical_json(decision))
    assert len(digest) == 32
    return digest, decision


def _bytes32(value: Any) -> bytes:
    if value is None:
        return ZERO_HASH
    if isinstance(value, bytes):
        if len(value) != 32:
            raise ValueError("bytes32 value must be 32 bytes")
        return value
    if isinstance(value, bytearray):
        if len(value) != 32:
            raise ValueError("bytes32 value must be 32 bytes")
        return bytes(value)
    if isinstance(value, str):
        if value.startswith("0x"):
            raw = bytes.fromhex(value[2:])
            if len(raw) != 32:
                raise ValueError("hex bytes32 value must be 32 bytes")
            return raw
        return keccak(value.encode("utf-8"))
    return keccak(canonical_json(value))


def context_hash(
    *,
    action_hash: Any = None,
    policy_hash: Any = None,
    execution_hash: Any = None,
    post_state_hash: Any = None,
    outcome_hash: Any = None,
    evidence_uri_hash: Any,
) -> bytes:
    """Match AgentVault._contextHash for receipt typed data."""
    return keccak(
        encode(
            ["bytes32", "bytes32", "bytes32", "bytes32", "bytes32", "bytes32"],
            [
                _bytes32(action_hash),
                _bytes32(policy_hash),
                _bytes32(execution_hash),
                _bytes32(post_state_hash),
                _bytes32(outcome_hash),
                _bytes32(evidence_uri_hash),
            ],
        )
    )


def evidence_uri_for_hash(evidence_hash: bytes) -> str:
    """Build a durable evidence URI from REEF_EVIDENCE_BASE_URI.

    Live publishing must point at content-addressed storage, not mutable VPS JSON.
    Accepted bases are `ipfs://...` and `ar://...`.
    """
    if not isinstance(evidence_hash, (bytes, bytearray)) or len(evidence_hash) != 32:
        raise ValueError("evidence_hash must be 32 bytes")
    base = os.getenv("REEF_EVIDENCE_BASE_URI")
    if not base:
        raise RuntimeError(
            "REEF_EVIDENCE_BASE_URI must be set to an ipfs:// or ar:// base"
        )
    if not (base.startswith("ipfs://") or base.startswith("ar://")):
        raise RuntimeError("REEF_EVIDENCE_BASE_URI must start with ipfs:// or ar://")
    return f"{base.rstrip('/')}/{bytes(evidence_hash).hex()}"


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
    decision_timestamp: int | None = None,
    valid_until: int | None = None,
    decision_block: int = 0,
    action_hash: Any = None,
    policy_hash: Any = None,
    execution_hash: Any = None,
    post_state_hash: Any = None,
    outcome_hash: Any = None,
    evidence_uri: str | None = None,
) -> tuple[dict[str, Any], bytes]:
    """EIP-712-sign a Receipt; return (receiptStruct, signature)."""
    if not isinstance(evidence_hash, (bytes, bytearray)) or len(evidence_hash) != 32:
        raise ValueError("evidence_hash must be 32 bytes")
    if seq < 0 or not 0 <= period < 2**64 or not -(2**255) <= claimed_delta < 2**255:
        raise ValueError("receipt field out of range")
    decision_timestamp = (
        int(time.time()) if decision_timestamp is None else int(decision_timestamp)
    )
    valid_until = (
        decision_timestamp + int(period) if valid_until is None else int(valid_until)
    )
    if not 0 <= decision_timestamp < 2**64 or not 0 <= valid_until < 2**64:
        raise ValueError("receipt timestamp out of range")
    if valid_until < decision_timestamp:
        raise ValueError("valid_until before decision_timestamp")
    if decision_block < 0:
        raise ValueError("decision_block out of range")

    evidence_uri = evidence_uri or evidence_uri_for_hash(bytes(evidence_hash))
    evidence_uri_hash = keccak(evidence_uri.encode("utf-8"))
    action_hash_b = _bytes32(action_hash)
    policy_hash_b = _bytes32(policy_hash)
    execution_hash_b = _bytes32(execution_hash)
    post_state_hash_b = _bytes32(post_state_hash)
    outcome_hash_b = _bytes32(outcome_hash)
    context_hash_b = context_hash(
        action_hash=action_hash_b,
        policy_hash=policy_hash_b,
        execution_hash=execution_hash_b,
        post_state_hash=post_state_hash_b,
        outcome_hash=outcome_hash_b,
        evidence_uri_hash=evidence_uri_hash,
    )
    receipt = {
        "agentId": int(agent_id),
        "seq": int(seq),
        "evidenceHash": bytes(evidence_hash),
        "actionHash": action_hash_b,
        "policyHash": policy_hash_b,
        "executionHash": execution_hash_b,
        "postStateHash": post_state_hash_b,
        "outcomeHash": outcome_hash_b,
        "evidenceUriHash": evidence_uri_hash,
        "decisionTimestamp": int(decision_timestamp),
        "validUntil": int(valid_until),
        "period": int(period),
        "decisionBlock": int(decision_block),
        "claimedDelta": int(claimed_delta),
    }

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
            "contextHash": context_hash_b,
            "decisionTimestamp": int(decision_timestamp),
            "validUntil": int(valid_until),
            "period": int(period),
            "decisionBlock": int(decision_block),
            "claimedDelta": int(claimed_delta),
        },
    }
    signed = Account.sign_typed_data(private_key, full_message=typed)
    return receipt, bytes(signed.signature)
