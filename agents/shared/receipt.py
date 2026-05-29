"""Receipt payload builder for AgentVault.publishReceipt.

The on-chain `publishReceipt(bytes)` expects abi.encode(
    uint256 seq,
    bytes32 evidenceHash,
    int256  navDelta,
    uint64  period,
).
"""

from __future__ import annotations

import json
from typing import Any

from eth_abi import encode as abi_encode
from eth_utils import keccak


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
    canonical_bytes = canonical_json(decision)
    digest = keccak(canonical_bytes)
    assert len(digest) == 32
    return digest, decision


def build_payload(seq: int, evidence_hash: bytes, nav_delta: int, period: int) -> bytes:
    """abi.encode(uint256, bytes32, int256, uint64) — matches AgentVault.publishReceipt."""
    if not isinstance(evidence_hash, (bytes, bytearray)) or len(evidence_hash) != 32:
        raise ValueError("evidence_hash must be 32 bytes")
    if seq < 0:
        raise ValueError("seq must be non-negative")
    if period <= 0:
        raise ValueError("period must be > 0 (contract requires)")
    if not -(2**255) <= nav_delta < 2**255:
        raise ValueError("nav_delta out of int256 range")
    if not 0 <= period < 2**64:
        raise ValueError("period out of uint64 range")

    return abi_encode(
        ["uint256", "bytes32", "int256", "uint64"],
        [seq, bytes(evidence_hash), nav_delta, period],
    )
