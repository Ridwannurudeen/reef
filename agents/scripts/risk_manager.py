#!/usr/bin/env python
"""Automated, signal-driven risk management on the live DEX-backed-NAV vault.

This is the AI x RWA "automated risk management" loop. Each run:
  1. reads the real ETH market signal (CoinGecko 24h momentum),
  2. maps it through a TRANSPARENT exposure-band policy to a target exposure %,
  3. reads the vault's current on-chain exposure (deployed-into-DEX vs idle reserve),
  4. executes a REAL on-chain recall (de-risk) or deploy (re-risk) to hit the target.

Every action is logged to API_OUT_DIR/risk.json with the signal, policy band, the
before/after exposure, and the verifiable txHash. When the market deteriorates the
agent reduces on-chain exposure to the volatile leg and moves capital to the idle
reserve — protecting the vault. The policy is a deterministic, auditable rule (risk
management you can verify), not a black box.

Operates on the standalone DEX-NAV vault (deployments `dexNavDemo`), isolated from
the seeded leaderboard. Requires PRIVATE_KEY (the vault operator) in .env.

Usage (repo root):
    API_OUT_DIR=/opt/reef/web/api python -m agents.scripts.risk_manager
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

from agents.shared.client import (
    get_w3,
    load_account,
    rpc_read,
    send_tx,
    vault_contract,
)
from agents.shared.config import DEPLOYMENTS_DIR, REPO_ROOT, load_chain
from agents.shared.signal import fetch_signal

# Minimal adapter ABI (only the mark-to-market read is needed here) so this script
# has no dependency on the compiled forge artifact being present on the host.
_ADAPTER_ABI = [
    {
        "name": "totalUnderlying",
        "inputs": [],
        "outputs": [{"name": "", "type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    }
]

# Transparent exposure-band policy: 24h momentum (%) -> target exposure (bps of vault assets).
_BANDS = [
    (-6.0, 2000, "risk-off (momentum <= -6%)"),
    (-3.0, 4000, "defensive (-6% < momentum <= -3%)"),
    (3.0, 6000, "neutral (-3% < momentum < +3%)"),
    (float("inf"), 8000, "risk-on (momentum >= +3%)"),
]


def policy(momentum: float) -> tuple[int, str]:
    """Map 24h momentum to a (target exposure bps, band label)."""
    for ceiling, bps, label in _BANDS:
        if momentum <= ceiling:
            return bps, label
    return 8000, _BANDS[-1][2]


def main() -> int:
    network = os.getenv("REEF_NETWORK", "mantle-sepolia")
    out_dir = Path(os.getenv("API_OUT_DIR", str(REPO_ROOT / "ui" / "api")))
    deadband_bps = int(
        os.getenv("RISK_DEADBAND_BPS", "300")
    )  # ignore drift < 3% of assets

    chain = load_chain(network)
    data = json.loads((DEPLOYMENTS_DIR / f"{network}.json").read_text(encoding="utf-8"))
    demo = data.get("dexNavDemo")
    if not demo:
        print("no dexNavDemo block in deployments", file=sys.stderr)
        return 2
    vault_addr, adapter_addr = demo["agentVault"], demo["fusionXAdapter"]

    # The public Sepolia RPCs flake intermittently on connect; retry the whole
    # failover list a few times before giving up.
    w3 = None
    for attempt in range(5):
        try:
            w3 = get_w3(chain.rpc_url)
            break
        except RuntimeError:
            if attempt == 4:
                raise
            time.sleep(1.5 * (attempt + 1))
    account = load_account()
    adapter_addr = w3.to_checksum_address(adapter_addr)
    vault = vault_contract(w3, vault_addr)
    adapter = w3.eth.contract(address=adapter_addr, abi=_ADAPTER_ABI)

    # Optional stress/demo scenario: drive the policy from an injected momentum so the
    # on-chain de-risk/re-risk loop can be exercised when the live market is calm. It is
    # tagged source="scenario" + scenario=true and is NEVER presented as a live reading.
    forced = os.getenv("RISK_FORCE_MOMENTUM")
    scenario = forced is not None
    signal = fetch_signal("ETH")
    if scenario:
        base = signal or {"asset": "ETH", "price": 0.0, "source": "scenario"}
        signal = {**base, "change24hPct": float(forced), "source": "scenario"}
    elif not signal:
        print("no market signal; holding", file=sys.stderr)
        return 0
    momentum = signal["change24hPct"]
    target_bps, band = policy(momentum)

    total = rpc_read(lambda: vault.functions.totalAssets().call())
    deployed = rpc_read(lambda: adapter.functions.totalUnderlying().call())
    nav_before = rpc_read(lambda: vault.functions.nav().call())
    if total == 0:
        print("vault empty; nothing to manage", file=sys.stderr)
        return 0

    cur_bps = deployed * 10000 // total
    target_deployed = total * target_bps // 10000
    delta = target_deployed - deployed  # >0 deploy more (re-risk), <0 recall (de-risk)

    action, amount, tx = "hold", 0, None
    if abs(delta) * 10000 // total >= deadband_bps:
        amount = abs(delta)
        if delta < 0:
            action = "de-risk"
            receipt = send_tx(
                w3, account, vault.functions.recallFromStrategy(adapter_addr, amount)
            )
        else:
            action = "re-risk"
            receipt = send_tx(
                w3, account, vault.functions.deployToStrategy(adapter_addr, amount)
            )
        tx = w3.to_hex(receipt["transactionHash"])

    # After a tx the flaky public RPC can briefly serve pre-tx state; poll until the
    # deployed amount reflects the action so the logged exposure is accurate.
    new_deployed = rpc_read(lambda: adapter.functions.totalUnderlying().call())
    if action != "hold":
        for _ in range(8):
            if new_deployed != deployed:
                break
            time.sleep(1.5)
            new_deployed = rpc_read(lambda: adapter.functions.totalUnderlying().call())
    new_total = rpc_read(lambda: vault.functions.totalAssets().call())
    nav_after = rpc_read(lambda: vault.functions.nav().call())
    new_bps = new_deployed * 10000 // new_total if new_total else 0

    if action == "hold":
        rationale = (
            f"ETH 24h momentum {momentum:+.2f}% -> {band}; target exposure "
            f"{target_bps / 100:.0f}%. Already within deadband (exposure {cur_bps / 100:.1f}%), no action."
        )
    else:
        rationale = (
            f"ETH 24h momentum {momentum:+.2f}% -> {band}; target exposure {target_bps / 100:.0f}%. "
            f"{action} {amount / 1e18:.2f}: exposure {cur_bps / 100:.1f}% -> {new_bps / 100:.1f}%."
        )
    print(rationale)

    event = {
        "ts": int(time.time()),
        "vault": vault_addr,
        "signal": signal,
        "momentumPct": momentum,
        "band": band,
        "scenario": scenario,
        "targetBps": target_bps,
        "prevExposureBps": cur_bps,
        "newExposureBps": new_bps,
        "action": action,
        "amount": str(amount),
        "txHash": tx,
        "navBefore": str(nav_before),
        "navAfter": str(nav_after),
        "rationale": rationale,
    }
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "risk.json"
    log = (
        json.loads(path.read_text(encoding="utf-8"))
        if path.exists()
        else {
            "policy": "momentum-band exposure targets: 20/40/60/80% at -6/-3/+3% bands",
            "events": [],
        }
    )
    log["vault"] = vault_addr
    log["events"] = ([event] + log.get("events", []))[:50]
    log["updatedAt"] = int(time.time())
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(log, indent=2), encoding="utf-8")
    os.replace(tmp, path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
