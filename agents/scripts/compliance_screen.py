#!/usr/bin/env python
"""Compliance screen — GLM decides whether to KYC-attest an address, then attests it on-chain.

Takes a subject address + a claimed ISO-3166 numeric country code, asks Z.ai GLM for a screening
DECISION (approve/deny) and a one-sentence RATIONALE for whether to issue a KYC + accreditation
attestation (deterministic sanctioned-country rule if no GLM key, recorded honestly as
source="fallback"). The rationale is hashed (evidenceHash = keccak(rationale)) and committed
on-chain via ComplianceRegistry.attest() from the ISSUER key; the verbatim rationale + decision +
evidenceHash + tx are written to API_OUT_DIR/compliance.json so anyone can verify
keccak(rationale) == the on-chain evidenceHash.

Usage (from repo root, ZAI_* + COMPLIANCE_ISSUER_KEY|PRIVATE_KEY in .env):
    python -m agents.scripts.compliance_screen <address> [countryCode]
    COMPLIANCE_SUBJECT=0x... COMPLIANCE_COUNTRY=840 python -m agents.scripts.compliance_screen
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

from web3 import Web3

from agents.shared.client import get_w3, load_account, rpc_read, send_tx
from agents.shared.config import DEPLOYMENTS_DIR, REPO_ROOT, load_chain
from agents.shared.glm import GlmUnavailable, chat

# Inline-minimal ABI (attest + screen) — same approach as guard_snapshot._GUARD_ABI.
_COMPLIANCE_ABI = [
    {
        "name": "attest",
        "inputs": [
            {"name": "subject", "type": "address"},
            {"name": "kyc", "type": "bool"},
            {"name": "accredited", "type": "bool"},
            {"name": "country", "type": "uint16"},
            {"name": "expiresAt", "type": "uint64"},
            {"name": "evidenceHash", "type": "bytes32"},
        ],
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function",
    },
    {
        "name": "screen",
        "inputs": [{"type": "address"}],
        "outputs": [{"type": "bool"}, {"type": "string"}],
        "stateMutability": "view",
        "type": "function",
    },
]

# ISO-3166 numeric codes for sanctioned jurisdictions (DPRK, Iran, Syria, Cuba).
_SANCTIONED = {408, 364, 760, 192}

_SYSTEM = (
    "You are a compliance officer screening an address for a KYC + accreditation attestation "
    "before it may enter a gated on-chain RWA flow. Given the address and its claimed ISO-3166 "
    "numeric country code, decide whether to attest it. Deny any address claiming a sanctioned "
    "jurisdiction (e.g. 408 DPRK, 364 Iran, 760 Syria, 192 Cuba); otherwise approve. "
    'Reply ONLY with compact JSON: {"decision":"approve|deny","rationale":"one sentence justification"}.'
)


def _zai_cfg() -> tuple[str | None, str, str]:
    key = os.getenv("ZAI_API_KEY") or None
    base = os.getenv("ZAI_BASE_URL") or "https://api.z.ai/api/paas/v4"
    model = os.getenv("ZAI_MODEL") or "glm-4.7-flash"
    return key, base, model


def _screen_decision(subject: str, country: int) -> tuple[str, str, str, str]:
    """Return (decision, rationale, source, model). GLM if available, else deterministic rule."""
    key, base, model = _zai_cfg()
    prompt = (
        f"Address {subject} claims ISO-3166 country code {country}. "
        "Decide whether to issue a KYC + accreditation attestation."
    )
    try:
        out = chat(
            [
                {"role": "system", "content": _SYSTEM},
                {"role": "user", "content": prompt},
            ],
            api_key=key,
            base_url=base,
            model=model,
            temperature=0.2,
            timeout=55,
        )
        data = json.loads(out)
        decision = str(data["decision"]).strip().lower()
        rationale = str(data["rationale"]).strip()
        if decision not in ("approve", "deny") or not rationale:
            raise ValueError("unexpected GLM decision shape")
        return decision, rationale, "glm", model
    except (GlmUnavailable, ValueError, KeyError, json.JSONDecodeError):
        approved = country not in _SANCTIONED
        decision = "approve" if approved else "deny"
        rationale = f"Deterministic rule: country code {country} is " + (
            "not on the sanctioned list; KYC + accreditation attested."
            if approved
            else "a sanctioned jurisdiction; attestation denied."
        )
        return decision, rationale, "fallback", "deterministic-rule"


def main() -> int:
    network = os.getenv("REEF_NETWORK", "mantle-sepolia")
    out_dir = Path(os.getenv("API_OUT_DIR", str(REPO_ROOT / "ui" / "api")))

    args = sys.argv[1:]
    subject = args[0] if len(args) > 0 else os.getenv("COMPLIANCE_SUBJECT")
    country = (
        int(args[1]) if len(args) > 1 else int(os.getenv("COMPLIANCE_COUNTRY", "840"))
    )
    if not subject:
        print(
            "usage: python -m agents.scripts.compliance_screen <address> [countryCode]",
            file=sys.stderr,
        )
        return 2

    chain = load_chain(network)
    data = json.loads((DEPLOYMENTS_DIR / f"{network}.json").read_text(encoding="utf-8"))
    cr = data.get("complianceRegistry")
    if not cr or not cr.get("address"):
        print("no complianceRegistry.address in deployments", file=sys.stderr)
        return 2

    decision, rationale, source, model = _screen_decision(subject, country)
    approved = decision == "approve"

    w3 = get_w3(chain.rpc_url)
    key_env = (
        "COMPLIANCE_ISSUER_KEY" if os.getenv("COMPLIANCE_ISSUER_KEY") else "PRIVATE_KEY"
    )
    acct = load_account(key_env)
    registry = w3.eth.contract(
        address=w3.to_checksum_address(cr["address"]), abi=_COMPLIANCE_ABI
    )
    subject_cs = w3.to_checksum_address(subject)

    # evidenceHash = keccak(rationale) — same util a2a_trader.py uses; verifiable off-chain.
    evidence = Web3.keccak(text=rationale)
    expires_at = int(time.time()) + 365 * 24 * 3600

    receipt = send_tx(
        w3,
        acct,
        registry.functions.attest(
            subject_cs, approved, approved, country, expires_at, evidence
        ),
    )
    tx = receipt.get("transactionHash")
    tx_hex = tx.hex() if hasattr(tx, "hex") else str(tx)
    if not tx_hex.startswith("0x"):
        tx_hex = "0x" + tx_hex

    # Read the on-chain verdict back so the JSON reflects post-attestation truth.
    ok, reason = rpc_read(lambda: registry.functions.screen(subject_cs).call())

    doc = {
        "registry": cr["address"],
        "subject": subject_cs,
        "claimedCountry": country,
        "decision": decision,
        "kyc": approved,
        "accredited": approved,
        "rationale": rationale,  # verbatim: keccak(rationale) == evidenceHash
        "evidenceHash": Web3.to_hex(evidence),
        "expiresAt": expires_at,
        "source": source,
        "model": model,
        "tx": tx_hex,
        "screen": {"eligible": bool(ok), "reason": reason},
        "updatedAt": int(time.time()),
    }
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "compliance.json"
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(doc, indent=2), encoding="utf-8")
    os.replace(tmp, path)

    print(
        f"{subject_cs} [{source}] {decision} country={country} "
        f"screen={'ELIGIBLE' if ok else 'INELIGIBLE'} ({reason}) | tx {tx_hex}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
