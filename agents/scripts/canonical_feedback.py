#!/usr/bin/env python
"""Publish Reef Trust Scores to Mantle's CANONICAL ERC-8004 Reputation Registry.

For each seeded agent registered in the canonical Identity Registry (see
canonical_register.py / deployments erc8004Canonical), this publishes the agent's
current Reef Trust Score (scores.json, 0-100 with 1 decimal) as ERC-8004 feedback —
giveFeedback(canonicalAgentId, score*10, 1, "trust-score", "reef", "", passportURI, 0) —
so the reputation Reef computes is PORTABLE: any Mantle protocol can read it from the
official registry, not just from Reef's own contracts.

Publisher = the deployer key (PRIVATE_KEY): the canonical registry rejects feedback from
the agent NFT's owner ("Self-feedback not allowed", verified on-chain), and the arena key
owns the NFTs — so the protocol account that runs the trust engine signs the feedback.

Diff-gated on-chain: the last feedback we published is read back from the registry
(getLastIndex/readFeedback) and a new one is sent only when the score changed — a cron
run in a quiet market costs zero gas. Also writes /api/canonical.json (per-agent
canonical id, feedback count, last published score) for the dashboard/transparency page.

Usage: API_OUT_DIR=/opt/reef/web/api python -m agents.scripts.canonical_feedback
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

from agents.shared.client import get_w3, load_account, rpc_read, send_tx
from agents.shared.config import DEPLOYMENTS_DIR, REPO_ROOT, load_chain

_ZERO_HASH = b"\x00" * 32

_REPUTATION_ABI = [
    {
        "name": "giveFeedback",
        "inputs": [
            {"name": "agentId", "type": "uint256"},
            {"name": "value", "type": "int128"},
            {"name": "valueDecimals", "type": "uint8"},
            {"name": "tag1", "type": "string"},
            {"name": "tag2", "type": "string"},
            {"name": "endpoint", "type": "string"},
            {"name": "feedbackURI", "type": "string"},
            {"name": "feedbackHash", "type": "bytes32"},
        ],
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function",
    },
    {
        "name": "getLastIndex",
        "inputs": [
            {"name": "agentId", "type": "uint256"},
            {"name": "client", "type": "address"},
        ],
        "outputs": [{"type": "uint64"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "name": "readFeedback",
        "inputs": [
            {"name": "agentId", "type": "uint256"},
            {"name": "client", "type": "address"},
            {"name": "index", "type": "uint64"},
        ],
        "outputs": [
            {"type": "int128"},
            {"type": "uint8"},
            {"type": "string"},
            {"type": "string"},
            {"type": "bool"},
        ],
        "stateMutability": "view",
        "type": "function",
    },
]


def main() -> int:
    network = os.getenv("REEF_NETWORK", "mantle-sepolia")
    chain = load_chain(network)
    data = json.loads((DEPLOYMENTS_DIR / f"{network}.json").read_text(encoding="utf-8"))
    canon = data.get("erc8004Canonical") or {}
    agents = canon.get("agents") or {}
    if not canon.get("reputationRegistry") or not agents:
        print(
            "no canonical registration in deployments; run canonical_register first",
            file=sys.stderr,
        )
        return 2

    out_dir = Path(os.getenv("API_OUT_DIR", str(REPO_ROOT / "ui" / "api")))
    scores_path = out_dir / "scores.json"
    if not scores_path.exists():
        print(f"no {scores_path}; run trust_score first", file=sys.stderr)
        return 2
    scores = {
        str(s["agentId"]): s
        for s in json.loads(scores_path.read_text(encoding="utf-8")).get("agents", [])
    }

    w3 = get_w3(chain.rpc_url)
    acct = load_account("PRIVATE_KEY")
    registry = w3.eth.contract(
        address=w3.to_checksum_address(canon["reputationRegistry"]),
        abi=_REPUTATION_ABI,
    )

    published = 0
    rows = []
    for reef_id, rec in sorted(agents.items(), key=lambda kv: int(kv[0])):
        canonical_id = rec.get("canonicalAgentId")
        score = (scores.get(reef_id) or {}).get("trustScore")
        if canonical_id is None or score is None:
            continue
        value = int(
            round(float(score) * 10)
        )  # 0-100, 1 decimal -> int128 with decimals=1

        last_index = int(
            rpc_read(
                lambda: registry.functions.getLastIndex(
                    canonical_id, acct.address
                ).call()
            )
        )
        last_value = None
        if last_index > 0:
            fb = rpc_read(
                lambda: registry.functions.readFeedback(
                    canonical_id, acct.address, last_index
                ).call()
            )
            if not fb[4]:  # not revoked
                last_value = int(fb[0])

        if last_value == value:
            print(
                f"agent {reef_id}: canonical #{canonical_id} score {score} unchanged, skipping"
            )
        else:
            receipt = send_tx(
                w3,
                acct,
                registry.functions.giveFeedback(
                    canonical_id,
                    value,
                    1,
                    "trust-score",
                    "reef",
                    "",
                    rec.get("agentURI", ""),
                    _ZERO_HASH,
                ),
            )
            tx = receipt.get("transactionHash")
            tx_hex = tx.hex() if hasattr(tx, "hex") else str(tx)
            if not tx_hex.startswith("0x"):
                tx_hex = "0x" + tx_hex
            last_index += 1
            published += 1
            print(
                f"agent {reef_id}: canonical #{canonical_id} published score "
                f"{score} ({'was ' + str(last_value / 10) if last_value is not None else 'first'}) | tx {tx_hex}"
            )
        rows.append(
            {
                "agentId": int(reef_id),
                "canonicalAgentId": canonical_id,
                "trustScore": score,
                "feedbackCount": last_index,
                "registerTx": rec.get("registerTx"),
            }
        )

    doc = {
        "identityRegistry": canon.get("identityRegistry"),
        "reputationRegistry": canon.get("reputationRegistry"),
        "publisher": acct.address,
        "agents": rows,
        "updatedAt": int(time.time()),
    }
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "canonical.json"
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(doc, indent=2), encoding="utf-8")
    os.replace(tmp, path)
    print(f"canonical feedback: {published} published, {len(rows)} agents snapshotted")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
