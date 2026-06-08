#!/usr/bin/env python
"""Real-execution sweep: GLM decides per agent; on "increase" the agent executes a real swap.

For each seeded vault, ask Z.ai GLM for an allocation decision from on-chain NAV state. If the
action is "increase", execute a REAL FusionX V2 swap on Mantle Sepolia (native MNT -> USDC, no
real funds — faucet MNT), and record the decision + the real swap txHash to
API_OUT_DIR/executions.json. The swap txHash is independently verifiable on Mantlescan; the
matching decision rationale is committed on-chain by the receipt loop (`receipt_tick`), so the
pair (decision, on-chain trade) is fully auditable.

Scope (honest): agent-level execution proof — swaps acquire tokens to the operator wallet;
routing trades through a vault strategy adapter into NAV is a deeper follow-up. No on-chain
receipt is published here (the receipt loop owns that), so this never races the strict sequence.

Usage (from repo root, ZAI_* + PRIVATE_KEY in .env):
    API_OUT_DIR=/opt/reef/web/api python -m agents.scripts.execute_decision
Cron (every 20 min):
    5,25,45 * * * * cd /opt/reef/app && API_OUT_DIR=/opt/reef/web/api /usr/bin/python3 -m agents.scripts.execute_decision >> /var/log/reef-exec.log 2>&1
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

from agents.shared.brain import decide_for_vault
from agents.shared.client import get_w3, load_account, rpc_read, vault_contract
from agents.shared.config import DEPLOYMENTS_DIR, REPO_ROOT, load_chain
from agents.shared.dex import (
    load_dex,
    swap_native_for_token,
    swap_token_for_wmnt,
    token_balance,
)
from agents.shared.allora import fetch_eth_prediction
from agents.shared.nansen import fetch_smart_money_flow
from agents.shared.signal import fetch_signal


def main() -> int:
    network = os.getenv("REEF_NETWORK", "mantle-sepolia")
    exec_mnt = float(os.getenv("EXEC_MNT", "0.02"))
    model = os.getenv("ZAI_MODEL") or "glm-4.7-flash"
    out_dir = Path(os.getenv("API_OUT_DIR", str(REPO_ROOT / "ui" / "api")))

    chain = load_chain(network)
    data = json.loads((DEPLOYMENTS_DIR / f"{network}.json").read_text(encoding="utf-8"))
    vaults = data.get("seeded", {}).get("vaults", [])
    if not vaults:
        print("no seeded vaults", file=sys.stderr)
        return 2
    dex = load_dex(network)
    w3 = get_w3(chain.rpc_url)
    account = load_account()

    # Fetch the real market signal + Allora price prediction + Nansen smart-money flow once,
    # and process ONE rotating agent per run so a single GLM call/run stays under the rate limit.
    signal = fetch_signal("ETH")
    prediction = fetch_eth_prediction()
    flow = fetch_smart_money_flow()
    i = int(os.getenv("AGENT_INDEX", str((int(time.time()) // 600) % len(vaults))))
    selected = [vaults[i % len(vaults)]]

    records, traded, failures = [], 0, 0
    for v in selected:
        try:
            vc = vault_contract(w3, v["vault"])
            agent_id = rpc_read(lambda: vc.functions.agentId().call())
            nav = rpc_read(lambda: vc.functions.nav().call())
            hwm = rpc_read(lambda: vc.functions.highWaterNav().call())
            d = decide_for_vault(agent_id, nav, hwm, signal, prediction, flow)
            execution = None
            if d.action == "increase":
                # Increase exposure: buy the risk asset (real MNT -> USDC swap).
                execution = swap_native_for_token(
                    w3, account, dex, dex["usdc"], w3.to_wei(exec_mnt, "ether")
                )
                traded += 1
            elif d.action == "decrease":
                # De-risk: sell part of the held USDC back to the reserve (real swap), if any.
                bal = token_balance(w3, dex["usdc"], account.address)
                sell = bal // 4  # trim a quarter of the position
                if sell > 0:
                    execution = swap_token_for_wmnt(w3, account, dex, dex["usdc"], sell)
                    traded += 1
            records.append(
                {
                    "agent": agent_id,
                    "action": d.action,
                    "navDeltaBps": d.nav_delta_bps,
                    "reasoning": d.reasoning,
                    "source": d.source,
                    "model": model if d.source == "glm" else "deterministic-fallback",
                    "signal": signal,
                    "prediction": prediction,
                    "nansen": flow,
                    "execution": execution,
                    "ts": int(time.time()),
                }
            )
            tx = execution["txHash"][:14] + "…" if execution else "none"
            print(
                f"agent {agent_id} [{d.source}] {d.action} {d.nav_delta_bps}bps trade={tx}: {d.reasoning[:70]}"
            )
        except Exception as e:  # noqa: BLE001 - keep sweeping the rest
            failures += 1
            print(f"vault {v['vault']} FAILED: {e}", file=sys.stderr)

    if records:
        out_dir.mkdir(parents=True, exist_ok=True)
        path = out_dir / "executions.json"
        log = (
            json.loads(path.read_text(encoding="utf-8"))
            if path.exists()
            else {"executions": []}
        )
        log["executions"] = (records + log.get("executions", []))[:50]
        log["updatedAt"] = int(time.time())
        # Atomic write so a crash mid-write can't corrupt the audit log (also served statically).
        tmp = path.with_name(path.name + ".tmp")
        tmp.write_text(json.dumps(log, indent=2), encoding="utf-8")
        os.replace(tmp, path)
    print(f"swept {len(records)}/{len(vaults)} agents, {traded} real swaps executed")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
