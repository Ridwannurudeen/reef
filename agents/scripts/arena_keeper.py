#!/usr/bin/env python
"""Arena keeper: make the strategy duel a REAL on-chain competition.

Each round (uses ARENA_PRIVATE_KEY, separate from the deployer-key crons so it never
races their nonces):
  1. Peg the raETH/raUSD pool to the live ETH price, so the vaults' positions mark to
     real ETH.
  2. For each competing vault, run its persona's decision and deploy/recall to move
     toward a target exposure.
  3. Publish a signed EIP-712 receipt so NAV growth above the high-water mark credits
     on-chain reputation.
  4. Write per-vault {strategy, action, nav, reputation, exposure} to API_OUT_DIR/arena.json.

The reputation leaderboard then reflects which strategy times ETH exposure best — real
on-chain performance, not a decision score.

Usage: API_OUT_DIR=/opt/reef/web/api python -m agents.scripts.arena_keeper
"""

from __future__ import annotations

import json
import math
import os
import sys
import time
from pathlib import Path

from agents.shared.allora import fetch_eth_prediction
from agents.shared.client import (
    get_w3,
    identity_contract,
    load_account,
    rpc_read,
    send_tx,
    vault_contract,
)
from agents.shared.config import DEPLOYMENTS_DIR, REPO_ROOT, load_chain
from agents.shared.nansen import fetch_smart_money_flow
from agents.shared.personas import PERSONAS
from agents.shared.receipt import build_evidence, evidence_uri_for_hash, sign_receipt
from agents.shared.signal import fetch_signal

ROUTER = "0x272465431A6b86E3B9E5b9bD33f5D103a3F59eDb"
EXPOSURE_STEP_BPS = 2000
DEADBAND_BPS = 500

_ERC20 = [
    {
        "name": "mint",
        "inputs": [{"type": "address"}, {"type": "uint256"}],
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function",
    },
    {
        "name": "approve",
        "inputs": [{"type": "address"}, {"type": "uint256"}],
        "outputs": [{"type": "bool"}],
        "stateMutability": "nonpayable",
        "type": "function",
    },
]
_PAIR = [
    {
        "name": "getReserves",
        "inputs": [],
        "outputs": [{"type": "uint112"}, {"type": "uint112"}, {"type": "uint32"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "name": "token0",
        "inputs": [],
        "outputs": [{"type": "address"}],
        "stateMutability": "view",
        "type": "function",
    },
]
_ROUTER = [
    {
        "name": "swapExactTokensForTokens",
        "inputs": [
            {"type": "uint256"},
            {"type": "uint256"},
            {"type": "address[]"},
            {"type": "address"},
            {"type": "uint256"},
        ],
        "outputs": [{"type": "uint256[]"}],
        "stateMutability": "nonpayable",
        "type": "function",
    },
]
_ADAPTER = [
    {
        "name": "totalUnderlying",
        "inputs": [],
        "outputs": [{"type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    },
]


def _peg(w3, acct, arena: dict, target: float) -> None:
    """Trade the pool to move raETH's price (raUSD per raETH) to the live ETH price."""
    usd = w3.to_checksum_address(arena["raUSD"])
    eth = w3.to_checksum_address(arena["raETH"])
    pc = w3.eth.contract(address=w3.to_checksum_address(arena["pair"]), abi=_PAIR)
    r0, r1, _ = rpc_read(lambda: pc.functions.getReserves().call())
    t0 = rpc_read(lambda: pc.functions.token0().call())
    u, e = (r0, r1) if t0.lower() == usd.lower() else (r1, r0)
    if e == 0:
        return
    price = u / e
    k = u * e
    if target > price * 1.002:  # raETH should be pricier -> buy raETH with raUSD
        amt, tok, path = int(math.sqrt(k * target) - u), usd, [usd, eth]
    elif target < price * 0.998:  # sell raETH for raUSD
        amt, tok, path = int(math.sqrt(k / target) - e), eth, [eth, usd]
    else:
        return
    if amt <= 0:
        return
    tk = w3.eth.contract(address=tok, abi=_ERC20)
    send_tx(w3, acct, tk.functions.mint(acct.address, amt))
    send_tx(w3, acct, tk.functions.approve(w3.to_checksum_address(ROUTER), amt))
    router = w3.eth.contract(address=w3.to_checksum_address(ROUTER), abi=_ROUTER)
    send_tx(
        w3,
        acct,
        router.functions.swapExactTokensForTokens(
            amt, 0, path, acct.address, int(time.time()) + 600
        ),
    )


def main() -> int:
    network = os.getenv("REEF_NETWORK", "mantle-sepolia")
    out_dir = Path(os.getenv("API_OUT_DIR", str(REPO_ROOT / "ui" / "api")))
    chain = load_chain(network)
    data = json.loads((DEPLOYMENTS_DIR / f"{network}.json").read_text(encoding="utf-8"))
    arena = data.get("arena")
    if not arena:
        print("no arena block in deployments", file=sys.stderr)
        return 2

    w3 = get_w3(chain.rpc_url)
    acct = load_account("ARENA_PRIVATE_KEY")
    identity = identity_contract(w3, arena["identity"])
    signal = fetch_signal("ETH")
    prediction = fetch_eth_prediction()
    flow = fetch_smart_money_flow()

    if signal and signal.get("price"):
        try:
            _peg(w3, acct, arena, float(signal["price"]))
        except Exception as e:  # noqa: BLE001 - keep going; positions still mark at last price
            print(f"peg failed: {e}", file=sys.stderr)

    results = []
    for v in arena["vaults"]:
        aid = int(v["agentId"])
        name, edge, fn = PERSONAS.get(aid, (f"Agent {aid}", "", None))
        if fn is None:
            continue
        vc = vault_contract(w3, v["vault"])
        ac = w3.eth.contract(address=w3.to_checksum_address(v["adapter"]), abi=_ADAPTER)
        nav = rpc_read(lambda vc=vc: vc.functions.nav().call())
        hwm = rpc_read(lambda vc=vc: vc.functions.highWaterNav().call())
        total = rpc_read(lambda vc=vc: vc.functions.totalAssets().call())
        deployed = rpc_read(lambda ac=ac: ac.functions.totalUnderlying().call())
        cur_bps = deployed * 10000 // total if total else 0

        d = fn(
            {
                "signal": signal,
                "prediction": prediction,
                "flow": flow,
                "agent_id": aid,
                "nav": nav,
                "hwm": hwm,
            }
        )
        if d.action == "increase":
            tgt = min(cur_bps + EXPOSURE_STEP_BPS, 9000)
        elif d.action == "decrease":
            tgt = max(cur_bps - EXPOSURE_STEP_BPS, 1000)
        else:
            tgt = cur_bps
        delta = total * tgt // 10000 - deployed
        if total and abs(delta) * 10000 // total >= DEADBAND_BPS:
            try:
                if delta > 0:
                    send_tx(
                        w3,
                        acct,
                        vc.functions.deployToStrategy(
                            w3.to_checksum_address(v["adapter"]), int(delta)
                        ),
                    )
                else:
                    send_tx(
                        w3,
                        acct,
                        vc.functions.recallFromStrategy(
                            w3.to_checksum_address(v["adapter"]), int(-delta)
                        ),
                    )
            except Exception as e:  # noqa: BLE001
                print(f"agent {aid} exposure tx failed: {e}", file=sys.stderr)

        seq = rpc_read(lambda vc=vc: vc.functions.nextReceiptSeq().call())
        decision_ts = int(time.time())
        ev, envelope = build_evidence(
            {
                "schema": "reef.receipt.v2",
                "agent": aid,
                "strategy": name,
                "action": d.action,
                "nav": str(nav),
                "ts": decision_ts,
            }
        )
        evidence_uri = evidence_uri_for_hash(ev)
        receipt_struct, signature = sign_receipt(
            acct.key,
            vault=v["vault"],
            chain_id=w3.eth.chain_id,
            agent_id=aid,
            seq=seq,
            evidence_hash=ev,
            claimed_delta=int(d.nav_delta_bps),
            period=600,
            decision_timestamp=decision_ts,
            valid_until=decision_ts + 600,
            decision_block=rpc_read(lambda: w3.eth.block_number),
            action_hash={
                "strategy": name,
                "action": d.action,
                "navDeltaBps": d.nav_delta_bps,
            },
            policy_hash={},
            execution_hash=envelope,
            post_state_hash={},
            outcome_hash={},
            evidence_uri=evidence_uri,
        )
        try:
            send_tx(w3, acct, vc.functions.publishReceipt(receipt_struct, signature))
        except Exception as e:  # noqa: BLE001
            print(f"agent {aid} receipt failed: {e}", file=sys.stderr)

        nav2 = rpc_read(lambda vc=vc: vc.functions.nav().call())
        new_dep = rpc_read(lambda ac=ac: ac.functions.totalUnderlying().call())
        new_total = rpc_read(lambda vc=vc: vc.functions.totalAssets().call())
        cum, _cnt = rpc_read(lambda: identity.functions.getSummary(aid).call())
        results.append(
            {
                "agentId": aid,
                "strategy": name,
                "edge": edge,
                "action": d.action,
                "reasoning": d.reasoning,
                "navE18": str(nav2),
                "reputation": str(cum),
                "exposureBps": (new_dep * 10000 // new_total) if new_total else 0,
                "vault": v["vault"],
            }
        )
        print(
            f"agent {aid} {name}: {d.action} exposure->{results[-1]['exposureBps']}bps nav {int(nav2) / 1e18:.5f} rep {cum}"
        )

    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "arena.json"
    doc = {
        "ethPrice": signal["price"] if signal else None,
        "agents": results,
        "updatedAt": int(time.time()),
    }
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(doc, indent=2), encoding="utf-8")
    os.replace(tmp, path)
    print(f"arena round: {len(results)} vaults")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
