#!/usr/bin/env python
"""A2A economy snapshot — the agent-to-agent signal marketplace, read straight from chain.

Reads the on-chain SignalMarket: every active listing (category, price, provider) flattened
with the provider's lifetime sales/revenue, plus the global totalSales/totalRevenueWei — all
in one getActiveListings() call (no log scanning). Writes API_OUT_DIR/a2a.json. Read-only —
safe on any cadence. Powers the dashboard "Agent-to-agent economy" panel and the transparency
proof card: autonomous agents buy and sell signals from each other, and the marketplace volume
is verifiable on-chain.

Usage: API_OUT_DIR=/opt/reef/web/api python -m agents.scripts.a2a_snapshot
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

from agents.shared.client import get_w3, rpc_read
from agents.shared.config import DEPLOYMENTS_DIR, REPO_ROOT, load_chain

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
        "name": "totalSales",
        "inputs": [],
        "outputs": [{"type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "name": "totalRevenueWei",
        "inputs": [],
        "outputs": [{"type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    },
]


def main() -> int:
    network = os.getenv("REEF_NETWORK", "mantle-sepolia")
    out_dir = Path(os.getenv("API_OUT_DIR", str(REPO_ROOT / "ui" / "api")))
    chain = load_chain(network)
    data = json.loads((DEPLOYMENTS_DIR / f"{network}.json").read_text(encoding="utf-8"))
    a2a = data.get("a2a")
    if not a2a:
        print("no a2a in deployments", file=sys.stderr)
        return 2
    names = a2a.get("providerNames", {})

    w3 = get_w3(chain.rpc_url)
    market = w3.eth.contract(
        address=w3.to_checksum_address(a2a["signalMarket"]), abi=_MARKET_ABI
    )

    rows = rpc_read(lambda: market.functions.getActiveListings().call())
    total_sales = int(rpc_read(lambda: market.functions.totalSales().call()))
    total_revenue = int(rpc_read(lambda: market.functions.totalRevenueWei().call()))

    listings = []
    for lid, provider_id, price, category, sales, revenue in rows:
        listings.append(
            {
                "id": int(lid),
                "providerAgentId": int(provider_id),
                "provider": names.get(
                    str(int(provider_id)), f"Agent {int(provider_id)}"
                ),
                "category": category,
                "priceWei": str(int(price)),
                "priceMnt": int(price) / 1e18,
                "sales": int(sales),
                "revenueWei": str(int(revenue)),
                "revenueMnt": int(revenue) / 1e18,
            }
        )
    # Busiest providers first, then highest revenue.
    listings.sort(key=lambda r: (r["sales"], r["revenueMnt"]), reverse=True)

    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "a2a.json"
    doc = {
        "signalMarket": a2a["signalMarket"],
        "explorer": f"{data['explorer']['mantlescan']}/address/{a2a['signalMarket']}",
        "totalSales": total_sales,
        "totalRevenueMnt": total_revenue / 1e18,
        "totalRevenueWei": str(total_revenue),
        "activeListings": len(listings),
        "listings": listings,
        "updatedAt": int(time.time()),
    }
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(doc, indent=2), encoding="utf-8")
    os.replace(tmp, path)

    print(
        f"A2A: {len(listings)} active listings | {total_sales} sales | {total_revenue / 1e18:.4f} MNT revenue"
    )
    for r in listings:
        print(
            f"  {r['provider']} [{r['category']}] {r['priceMnt']:.4f} MNT | {r['sales']} sales {r['revenueMnt']:.4f} MNT"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
