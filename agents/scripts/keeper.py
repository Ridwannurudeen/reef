#!/usr/bin/env python
"""Reef keeper — runs the permissionless AgentIndex.rebalance() on a schedule.

`rebalance()` takes no privileged role (anyone may call it), so this is the
on-chain action a decentralized keeper fleet performs: it re-weights the index
across vaults by current reputation. Run it as a one-shot from cron, or as a
long-lived daemon with `--loop`. The index address comes from the pinned
deployment file (override with INDEX_ADDR); the signer is PRIVATE_KEY.

Usage (from repo root):
    python -m agents.scripts.keeper                 # single rebalance, then exit
    python -m agents.scripts.keeper --loop          # daemon, every KEEPER_INTERVAL_S
    INDEX_ADDR=0x... python -m agents.scripts.keeper
Cron (every 10 min):
    */10 * * * * cd /opt/reef/app && python -m agents.scripts.keeper >> keeper.log 2>&1
"""

from __future__ import annotations

import json
import os
import sys
import time

from agents.shared.client import get_w3, index_contract, load_account, rpc_read, send_tx
from agents.shared.config import DEPLOYMENTS_DIR, load_chain


def _index_address(network: str) -> str:
    addr = os.getenv("INDEX_ADDR")
    if not addr:
        data = json.loads(
            (DEPLOYMENTS_DIR / f"{network}.json").read_text(encoding="utf-8")
        )
        addr = data.get("reef", {}).get("AgentIndex", "")
    if not addr or int(addr, 16) == 0:
        raise RuntimeError(
            "AgentIndex address not set: fill deployments file or set INDEX_ADDR"
        )
    return addr


def rebalance_once(w3, account, index) -> bool:
    """Run one rebalance. Returns True on success, False on a handled failure."""
    count = rpc_read(lambda: index.functions.vaultCount().call())
    if count == 0:
        print("keeper: no vaults registered — skipping rebalance")
        return True
    try:
        receipt = send_tx(w3, account, index.functions.rebalance())
    except Exception as e:  # noqa: BLE001 - keep the daemon alive across transient failures
        print(f"keeper: rebalance failed: {e}", file=sys.stderr)
        return False
    alloc = rpc_read(lambda: index.functions.getAllocation().call())
    weights = ", ".join(f"agent{a[0]}={a[2]}bps" for a in alloc)
    print(
        f"keeper: rebalanced {count} vaults in tx {receipt['transactionHash'].hex()} -> {weights}"
    )
    return True


def main() -> int:
    network = os.getenv("REEF_NETWORK", "mantle-sepolia")
    loop = "--loop" in sys.argv
    interval = int(os.getenv("KEEPER_INTERVAL_S", "600"))

    chain = load_chain(network)
    w3 = get_w3(chain.rpc_url)
    account = load_account()
    index = index_contract(w3, _index_address(network))
    print(
        f"keeper: {chain.name} index={index.address} signer={account.address} loop={loop}"
    )

    if not loop:
        return 0 if rebalance_once(w3, account, index) else 1

    while True:
        rebalance_once(w3, account, index)
        time.sleep(interval)


if __name__ == "__main__":
    raise SystemExit(main())
