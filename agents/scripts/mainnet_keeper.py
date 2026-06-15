#!/usr/bin/env python
"""Mainnet keeper: drive the Reef benchmark of REAL on-chain AI yield agents.

Each round drives the 4 benchmark AgentVaults live on Mantle mainnet. Per agent:
  1. Run the persona's decision over the SAME shared signals (CoinGecko spot/momentum,
     Allora ETH prediction, Nansen smart-money flow).
  2. Translate the decision into a TARGET exposure and deploy/recall real USDC<->WMNT
     through the vault's FusionXAdapter to move toward it. The HODL agent deploys to
     full exposure once and then never trades.
  3. Publish a signed EIP-712 receipt so NAV growth above the high-water mark credits
     on-chain reputation.
  4. Read each vault's real nav() and append to a capped NAV time-series in
     API_OUT_DIR/mainnet-nav.json, plus a per-agent {nav, reputation, exposure} snapshot in
     API_OUT_DIR/mainnet-arena.json. These are namespaced so they never collide with the
     live testnet arena_keeper's arena.json / nav.json.

Unlike the testnet arena keeper there is NO price-peg step: the FusionX USDC/WMNT pool
is a real market and marks positions on its own.

Per-agent signers: AGENT<agentId>_PRIVATE_KEY if set, else PRIVATE_KEY.

Usage: REEF_NETWORK=mantle-mainnet API_OUT_DIR=/opt/reef/web/api python -m agents.scripts.mainnet_keeper
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

from agents.allora_agent.strategies import Decision
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
from agents.shared.personas import BENCHMARK_PERSONAS
from agents.shared.receipt import build_evidence, sign_receipt
from agents.shared.signal import fetch_signal

EXPOSURE_STEP_BPS = 2000
DEADBAND_BPS = 500
HODL_TARGET_BPS = (
    9500  # "full" exposure; sits outside the deadband so HODL never re-trades
)
NAV_SERIES_CAP = 500  # ring-buffer length for the per-agent NAV time-series

# Resolve a persona by its display name (the benchmark entries carry a `persona` string).
_PERSONA_BY_NAME: dict[str, tuple[str, str, object]] = {
    p[0]: p for p in BENCHMARK_PERSONAS.values()
}

_ADAPTER = [
    {
        "name": "totalUnderlying",
        "inputs": [],
        "outputs": [{"type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    },
]


def _agent_account(agent_id: int):
    """Load this agent's signer: AGENT<id>_PRIVATE_KEY if present, else PRIVATE_KEY."""
    env = f"AGENT{agent_id}_PRIVATE_KEY"
    return load_account(env if os.getenv(env) else "PRIVATE_KEY")


def _load_nav_doc(path: Path) -> dict:
    """Read the existing NAV time-series doc, tolerating a missing/corrupt file."""
    if path.exists():
        try:
            doc = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(doc, dict) and isinstance(doc.get("agents"), dict):
                return doc
        except (json.JSONDecodeError, OSError):
            pass
    return {"agents": {}}


def _atomic_write(path: Path, doc: dict) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(doc, indent=2), encoding="utf-8")
    os.replace(tmp, path)


def main() -> int:
    network = os.getenv("REEF_NETWORK", "mantle-mainnet")
    out_dir = Path(os.getenv("API_OUT_DIR", str(REPO_ROOT / "api")))
    chain = load_chain(network)
    data = json.loads((DEPLOYMENTS_DIR / f"{network}.json").read_text(encoding="utf-8"))

    benchmark = data.get("benchmark")
    vaults = (benchmark or {}).get("vaults")
    if not vaults:
        print(
            "no benchmark.vaults block in deployments — nothing to drive",
            file=sys.stderr,
        )
        return 2

    w3 = get_w3(chain.rpc_url)
    identity_addr = benchmark.get("identity") or data.get("reef", {}).get(
        "AgentIdentity"
    )
    identity = (
        identity_contract(w3, identity_addr)
        if identity_addr and int(identity_addr, 16) != 0
        else None
    )

    signal = fetch_signal("ETH")
    prediction = fetch_eth_prediction()
    flow = fetch_smart_money_flow()

    results = []
    nav_path = out_dir / "mainnet-nav.json"
    nav_doc = _load_nav_doc(nav_path)
    series = nav_doc["agents"]
    now = int(time.time())

    for v in vaults:
        aid = int(v["agentId"])
        persona = v.get("persona", "")
        if persona == "HODL":
            name, edge, fn = "HODL", "buy-and-hold full-exposure benchmark", None
        else:
            name, edge, fn = _PERSONA_BY_NAME.get(persona, (persona, "", None))
            if fn is None:
                print(
                    f"agent {aid}: unknown persona {persona!r}, skipping",
                    file=sys.stderr,
                )
                continue

        acct = _agent_account(aid)
        vc = vault_contract(w3, v["vault"])
        ac = w3.eth.contract(address=w3.to_checksum_address(v["adapter"]), abi=_ADAPTER)
        nav = rpc_read(lambda vc=vc: vc.functions.nav().call())
        hwm = rpc_read(lambda vc=vc: vc.functions.highWaterNav().call())
        total = rpc_read(lambda vc=vc: vc.functions.totalAssets().call())
        deployed = rpc_read(lambda ac=ac: ac.functions.totalUnderlying().call())
        cur_bps = deployed * 10000 // total if total else 0

        if fn is None:  # HODL: deploy to full exposure once, then hold forever
            d = Decision(
                "hold", 0, "Buy-and-hold benchmark: full exposure, no trading.", "rule"
            )
            tgt = HODL_TARGET_BPS
        else:
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
        ev, _ = build_evidence(
            {
                "agent": aid,
                "strategy": name,
                "action": d.action,
                "nav": str(nav),
                "ts": now,
            }
        )
        args = sign_receipt(
            acct.key,
            vault=v["vault"],
            chain_id=w3.eth.chain_id,
            agent_id=aid,
            seq=seq,
            evidence_hash=ev,
            claimed_delta=int(d.nav_delta_bps),
            period=600,
        )
        try:
            send_tx(w3, acct, vc.functions.publishReceipt(*args))
        except Exception as e:  # noqa: BLE001
            print(f"agent {aid} receipt failed: {e}", file=sys.stderr)

        nav2 = rpc_read(lambda vc=vc: vc.functions.nav().call())
        new_dep = rpc_read(lambda ac=ac: ac.functions.totalUnderlying().call())
        new_total = rpc_read(lambda vc=vc: vc.functions.totalAssets().call())
        exposure_bps = (new_dep * 10000 // new_total) if new_total else 0
        rep = 0
        if identity is not None:
            try:
                rep, _cnt = rpc_read(lambda: identity.functions.getSummary(aid).call())
            except Exception as e:  # noqa: BLE001 - reputation read is best-effort
                print(f"agent {aid} reputation read failed: {e}", file=sys.stderr)

        results.append(
            {
                "agentId": aid,
                "strategy": name,
                "edge": edge,
                "action": d.action,
                "reasoning": d.reasoning,
                "navE18": str(nav2),
                "reputation": str(rep),
                "exposureBps": exposure_bps,
                "vault": v["vault"],
            }
        )

        entry = series.setdefault(
            str(aid), {"strategy": name, "navSeries": [], "ts": []}
        )
        entry["strategy"] = name
        entry["navSeries"].append(str(nav2))
        entry["ts"].append(now)
        entry["navSeries"] = entry["navSeries"][-NAV_SERIES_CAP:]
        entry["ts"] = entry["ts"][-NAV_SERIES_CAP:]

        print(
            f"agent {aid} {name}: {d.action} exposure->{exposure_bps}bps "
            f"nav {int(nav2) / 1e18:.5f} rep {rep}"
        )

    out_dir.mkdir(parents=True, exist_ok=True)
    nav_doc["updatedAt"] = now
    _atomic_write(nav_path, nav_doc)
    _atomic_write(
        out_dir / "mainnet-arena.json",
        {
            "ethPrice": signal["price"] if signal else None,
            "agents": results,
            "updatedAt": now,
        },
    )
    print(f"mainnet round: {len(results)} vaults")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
