#!/usr/bin/env python
"""Reef proof verifier - recompute the v2 evidence-envelope binding.

Reef commits each agent decision on-chain as evidenceHash = keccak256(canonical
evidenceEnvelope). This script independently recomputes that envelope hash and
also checks the embedded rationale hash:

  1. crypto:   keccak256(canonical evidenceEnvelope) == proofs.json evidenceHash
  2. crypto:   keccak256(reasoning) == proofs.json rationaleHash
  3. on-chain: AgentVault.lastReceiptEvidenceHash() == proofs.json evidenceHash

It is READ-ONLY (no private key) and defaults to the live deployment, so a judge
can verify Reef's envelope integrity in one command without trusting our server.

Usage:
    python -m agents.scripts.verify_proof              # live api + public RPC
    REEF_API_URL=http://localhost:8000/api/proofs.json python -m agents.scripts.verify_proof
    API_OUT_DIR=/opt/reef/web/api python -m agents.scripts.verify_proof   # local file
"""

from __future__ import annotations

import json
import os
import sys
import urllib.request
from pathlib import Path

from eth_utils import keccak

from agents.shared.client import get_w3, rpc_read, vault_contract
from agents.shared.config import DEPLOYMENTS_DIR
from agents.shared.receipt import canonical_json

DEFAULT_API_URL = "https://reef.gudman.xyz/api/proofs.json"


def _load_proofs() -> dict:
    """Load proofs.json from a local API_OUT_DIR if present, else fetch the live URL."""
    local_dir = os.getenv("API_OUT_DIR")
    if local_dir:
        path = Path(local_dir) / "proofs.json"
        if path.exists():
            return json.loads(path.read_text(encoding="utf-8"))
    url = os.getenv("REEF_API_URL", DEFAULT_API_URL)
    with urllib.request.urlopen(url, timeout=30) as resp:  # noqa: S310 - fixed https endpoint
        return json.loads(resp.read().decode("utf-8"))


def main() -> int:
    network = os.getenv("REEF_NETWORK", "mantle-sepolia")
    deployment = json.loads(
        (DEPLOYMENTS_DIR / f"{network}.json").read_text(encoding="utf-8")
    )
    vault_by_agent = {
        int(v["agentId"]): v["vault"]
        for v in deployment.get("seeded", {}).get("vaults", [])
    }
    proofs = _load_proofs().get("agents", {})
    if not proofs:
        print("no proofs published yet", file=sys.stderr)
        return 2

    w3 = get_w3(deployment["rpc"])
    matched = 0
    failures = 0
    liveness = 0
    for agent_id_str, p in sorted(proofs.items(), key=lambda kv: int(kv[0])):
        agent_id = int(agent_id_str)
        if p.get("proofStatus") != "matched":
            liveness += 1
            print(f"agent {agent_id}: liveness-only receipt (no bound rationale)")
            continue
        reasoning = p.get("reasoning") or ""
        evidence = p.get("evidenceHash") or ""
        rationale_hash = "0x" + keccak(reasoning.encode("utf-8")).hex()
        rationale_ok = p.get("rationaleHash") == rationale_hash
        envelope = p.get("evidenceEnvelope")
        if isinstance(envelope, dict):
            recomputed = "0x" + keccak(canonical_json(envelope)).hex()
            envelope_ok = recomputed == evidence
        else:
            recomputed = None
            envelope_ok = False

        vault = vault_by_agent.get(agent_id)
        if vault is None:
            failures += 1
            print(f"agent {agent_id}: FAIL - no vault for agent in {network}.json")
            continue
        vc = vault_contract(w3, vault)
        onchain = rpc_read(lambda vc=vc: vc.functions.lastReceiptEvidenceHash().call())
        onchain_hex = "0x" + onchain.hex()
        onchain_ok = onchain_hex == evidence

        if envelope_ok and rationale_ok and onchain_ok:
            matched += 1
            print(
                f"agent {agent_id}: OK - envelope==evidence==on-chain {evidence}; rationale={rationale_hash}"
            )
        else:
            failures += 1
            print(
                f"agent {agent_id}: FAIL - envelope={envelope_ok} rationale={rationale_ok} "
                f"on-chain={onchain_ok} (recomputed={recomputed} evidence={evidence} "
                f"chain={onchain_hex})"
            )

    print(
        f"\n{matched} matched proof(s) verified, {liveness} liveness-only, {failures} failed"
    )
    if matched and not failures:
        print("REEF_PROOF_VALID")
        return 0
    print("REEF_PROOF_INVALID")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
