#!/usr/bin/env python
"""A2A trader: make the agent-to-agent signal market a REAL, growing on-chain economy.

Each run (uses ARENA_PRIVATE_KEY — the same key that wallets the A2A provider agents, so it
can also buy as a consumer agent; separate from the deployer-key crons so it never races
their nonces):
  1. Read the on-chain active listings.
  2. Pick the listing with the FEWEST lifetime sales (spreads volume across providers).
  3. Have a *different* agent buy it — one real purchaseSignal{value: price} tx, with a fresh
     evidence hash. Payment routes provider->wallet; the marketplace's on-chain
     salesOf/revenueOf/totalSales/totalRevenueWei advance.

So the "Signal market" panel shows genuine, growing agent-to-agent commerce — not a static
seed. Buying never credits reputation (vault-only model), so this can't farm trust.

Usage: API_OUT_DIR=/opt/reef/web/api python -m agents.scripts.a2a_trader
"""

from __future__ import annotations

import json
import os
import sys
import time

from web3 import Web3

from agents.shared.client import get_w3, load_account, rpc_read, send_tx
from agents.shared.config import DEPLOYMENTS_DIR, load_chain

_MARKET_ABI = [
    {
        "name": "getActiveListings",
        "inputs": [],
        "outputs": [
            {
                "type": "tuple[]",
                "components": [
                    {"name": "id", "type": "uint256"},
                    {"name": "providerAgentId", "type": "uint256"},
                    {"name": "priceWei", "type": "uint256"},
                    {"name": "category", "type": "string"},
                    {"name": "sales", "type": "uint256"},
                    {"name": "revenueWei", "type": "uint256"},
                ],
            }
        ],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "name": "purchaseSignal",
        "inputs": [
            {"type": "uint256"},
            {"type": "uint256"},
            {"type": "bytes32"},
        ],
        "outputs": [],
        "stateMutability": "payable",
        "type": "function",
    },
    {
        "name": "totalSales",
        "inputs": [],
        "outputs": [{"type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    },
]


def main() -> int:
    network = os.getenv("REEF_NETWORK", "mantle-sepolia")
    chain = load_chain(network)
    data = json.loads((DEPLOYMENTS_DIR / f"{network}.json").read_text(encoding="utf-8"))
    a2a = data.get("a2a")
    if not a2a:
        print("no a2a block in deployments", file=sys.stderr)
        return 2
    agent_ids = sorted(int(k) for k in a2a.get("providerNames", {}))
    if len(agent_ids) < 2:
        print("need >=2 agents to trade", file=sys.stderr)
        return 2

    w3 = get_w3(chain.rpc_url)
    acct = load_account("ARENA_PRIVATE_KEY")
    market = w3.eth.contract(
        address=w3.to_checksum_address(a2a["signalMarket"]), abi=_MARKET_ABI
    )

    rows = rpc_read(lambda: market.functions.getActiveListings().call())
    if not rows:
        print("no active listings", file=sys.stderr)
        return 1

    # Buy the least-sold listing (ties -> lowest listing id) to spread volume.
    rows.sort(key=lambda r: (int(r[4]), int(r[0])))
    listing_id, provider_id, price, category, sales, _rev = (
        int(rows[0][0]),
        int(rows[0][1]),
        int(rows[0][2]),
        rows[0][3],
        int(rows[0][4]),
        int(rows[0][5]),
    )
    # Consumer = a different agent than the provider (rotate through the registered agents).
    consumer_id = next((a for a in agent_ids if a != provider_id), None)
    if consumer_id is None:
        print("no eligible consumer agent", file=sys.stderr)
        return 1

    prev_total = int(rpc_read(lambda: market.functions.totalSales().call()))
    evidence = Web3.keccak(text=f"a2a:{listing_id}:{consumer_id}:{int(time.time())}")
    receipt = send_tx(
        w3,
        acct,
        market.functions.purchaseSignal(listing_id, consumer_id, evidence),
        value=price,
    )
    # The flaky public RPC can serve a stale (pre-tx) read right after mining; poll until it advances.
    total_sales = prev_total
    for _ in range(6):
        total_sales = int(rpc_read(lambda: market.functions.totalSales().call()))
        if total_sales > prev_total:
            break
        time.sleep(1)
    tx = receipt.get("transactionHash")
    tx_hex = tx.hex() if hasattr(tx, "hex") else str(tx)
    print(
        f"A2A trade: agent {consumer_id} bought listing {listing_id} "
        f"[{category}] from agent {provider_id} for {price / 1e18:.4f} MNT "
        f"(was {sales} sales) | totalSales now {total_sales} | tx {tx_hex}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
