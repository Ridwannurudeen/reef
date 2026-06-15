#!/usr/bin/env python
"""Reef proof verifier — recompute the rationale↔receipt binding, anyone, anywhere.

Reef commits each agent decision on-chain as evidenceHash = keccak256(verbatim
rationale). This script independently recomputes that hash from the published
rationale and checks it three ways:

  1. crypto:   keccak256(reasoning) == proofs.json evidenceHash
  2. on-chain: AgentVault.lastReceiptEvidenceHash() == proofs.json evidenceHash
  3. published: rationaleHash field == evidenceHash

It is READ-ONLY (no private key) and defaults to the live deployment, so a judge
can verify Reef's claims in one command without trusting our server.

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
        recomputed = "0x" + keccak(reasoning.encode("utf-8")).hex()
        crypto_ok = recomputed == evidence
        published_ok = p.get("rationaleHash") == evidence

        vault = vault_by_agent.get(agent_id)
        if vault is None:
            failures += 1
            print(f"agent {agent_id}: FAIL - no vault for agent in {network}.json")
            continue
        vc = vault_contract(w3, vault)
        onchain = rpc_read(lambda vc=vc: vc.functions.lastReceiptEvidenceHash().call())
        onchain_hex = "0x" + onchain.hex()
        onchain_ok = onchain_hex == evidence

        if crypto_ok and published_ok and onchain_ok:
            matched += 1
            print(
                f"agent {agent_id}: OK - keccak(rationale)==evidence==on-chain {evidence}"
            )
        else:
            failures += 1
            print(
                f"agent {agent_id}: FAIL - crypto={crypto_ok} published={published_ok} "
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
