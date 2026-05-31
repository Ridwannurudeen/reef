#!/usr/bin/env python
"""Reef keeper health check — flag AgentVaults with stalled receipts.

Reads the seeded vaults from deployments/<network>.json, checks how long since
each published its last on-chain receipt, prints a status line per vault, and
exits non-zero if any exceed the staleness threshold. Suitable for cron +
alerting (a non-zero exit can drive an email/Telegram notification).

Usage (from repo root):
    python -m agents.scripts.health                 # default 1h threshold
    STALE_AFTER_S=900 python -m agents.scripts.health
Cron (every 15 min, alert on failure):
    */15 * * * * cd /opt/reef/app && python -m agents.scripts.health || /usr/local/bin/reef-alert.sh
"""

from __future__ import annotations

import json
import os
import sys
import time

from agents.shared.client import get_w3, vault_contract
from agents.shared.config import DEPLOYMENTS_DIR, load_chain


def main() -> int:
    network = os.getenv("REEF_NETWORK", "mantle-sepolia")
    stale_after = int(os.getenv("STALE_AFTER_S", "3600"))

    chain = load_chain(network)
    data = json.loads((DEPLOYMENTS_DIR / f"{network}.json").read_text(encoding="utf-8"))
    vaults = data.get("seeded", {}).get("vaults", [])
    if not vaults:
        print("no seeded vaults in deployment file", file=sys.stderr)
        return 2

    w3 = get_w3(chain.rpc_url)
    now = int(time.time())
    stale = 0
    print(f"Reef health @ {chain.name} (stale threshold {stale_after}s)")
    for v in vaults:
        vc = vault_contract(w3, v["vault"])
        last = vc.functions.lastReceiptAt().call()
        seq = vc.functions.nextReceiptSeq().call()
        if last == 0:
            status, bad = "NO-RECEIPTS", True
        else:
            age = now - last
            bad = age > stale_after
            status = f"{'STALE' if bad else 'ok'} ({age}s ago)"
        if bad:
            stale += 1
        print(f"  agent {v['agentId']:>2} {v['vault']} seq={seq} {status}")

    print(f"{stale}/{len(vaults)} vault(s) stale")
    return 1 if stale else 0


if __name__ == "__main__":
    raise SystemExit(main())
