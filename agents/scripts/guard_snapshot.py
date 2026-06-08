#!/usr/bin/env python
"""ReefGuard snapshot — query the on-chain policy gate for each agent.

Calls ReefGuard.canExecute(agentId, asset, sizeBps) for each seeded agent and writes
API_OUT_DIR/guard.json {guard, policy, agents:[{agentId, allowed, reason}]}. Read-only;
powers the "ReefGuard verdict" shown on each Agent Passport so anyone can see whether a
given agent is currently cleared to act, and why.

Usage: API_OUT_DIR=/opt/reef/web/api python -m agents.scripts.guard_snapshot
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

from agents.shared.client import get_w3, rpc_read
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
        "name": "minBond",
        "inputs": [],
        "outputs": [{"type": "uint256"}],
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


def main() -> int:
    network = os.getenv("REEF_NETWORK", "mantle-sepolia")
    out_dir = Path(os.getenv("API_OUT_DIR", str(REPO_ROOT / "ui" / "api")))
    chain = load_chain(network)
    data = json.loads((DEPLOYMENTS_DIR / f"{network}.json").read_text(encoding="utf-8"))
    rg = data.get("reefGuard")
    if not rg:
        print("no reefGuard in deployments", file=sys.stderr)
        return 2
    vaults = data.get("seeded", {}).get("vaults", [])

    w3 = get_w3(chain.rpc_url)
    guard = w3.eth.contract(
        address=w3.to_checksum_address(rg["address"]), abi=_GUARD_ABI
    )
    asset = w3.to_checksum_address(rg["asset"])

    agents = []
    for v in vaults:
        aid = int(v["agentId"])
        ok, reason = rpc_read(
            lambda aid=aid: guard.functions.canExecute(
                aid, asset, CHECK_SIZE_BPS
            ).call()
        )
        agents.append({"agentId": aid, "allowed": bool(ok), "reason": reason})
        print(f"agent {aid}: {'ALLOW' if ok else 'DENY'} ({reason})")

    policy = {
        "minBondE18": str(rpc_read(lambda: guard.functions.minBond().call())),
        "maxSizeBps": rpc_read(lambda: guard.functions.maxSizeBps().call()),
        "asset": asset,
        "checkSizeBps": CHECK_SIZE_BPS,
    }
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "guard.json"
    doc = {
        "guard": rg["address"],
        "policy": policy,
        "agents": agents,
        "updatedAt": int(time.time()),
    }
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(doc, indent=2), encoding="utf-8")
    os.replace(tmp, path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
