#!/usr/bin/env python
"""Run one BYOA agent's proof-bound rebalance loop."""
# ruff: noqa: E402

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

try:
    from dotenv import load_dotenv
except ImportError:  # pragma: no cover - dotenv is optional
    load_dotenv = None

HERE = Path(__file__).resolve().parent
REEF_ROOT = Path(os.getenv("REEF_ROOT", HERE.parent)).resolve()
sys.path.insert(0, str(REEF_ROOT))
sys.path.insert(0, str(HERE))

from eth_utils import keccak

import strategy
from agents.shared.client import get_w3, load_abi, load_account, rpc_read, send_tx
from agents.shared.config import load_chain
from agents.shared.receipt import sign_receipt

if load_dotenv:
    load_dotenv(REEF_ROOT / ".env")
    load_dotenv(HERE / ".env")

ZERO = "0x0000000000000000000000000000000000000000"
VALID_ACTIONS = {"increase", "decrease", "hold"}


def contract(w3, address: str, name: str):
    return w3.eth.contract(address=w3.to_checksum_address(address), abi=load_abi(name))


def env_int(name: str, default: int) -> int:
    raw = os.getenv(name)
    return default if raw in (None, "") else int(raw)


def same(a: str | None, b: str | None) -> bool:
    return bool(a and b) and a.lower() == b.lower()


def load_config() -> dict:
    path = Path(os.getenv("AGENT_CONFIG", HERE / "agent.json"))
    if not path.exists():
        raise FileNotFoundError(
            f"missing agent config: {path}; run deploy_agent.py first"
        )
    return json.loads(path.read_text(encoding="utf-8"))


def normalize_decision(raw: dict) -> dict:
    action = str(raw.get("action", "hold")).lower().strip()
    if action not in VALID_ACTIONS:
        action = "hold"
    nav_delta_bps = max(-500, min(500, int(raw.get("nav_delta_bps", 0))))
    reasoning = str(raw.get("reasoning", "")).strip()
    if not reasoning:
        reasoning = "Hold: the strategy returned no rationale, so the runtime kept capital unchanged."
    return {
        "action": action,
        "nav_delta_bps": nav_delta_bps,
        "reasoning": reasoning[:500],
    }


def cycle(w3, account, cfg: dict, out_dir: Path) -> dict:
    vault = contract(w3, cfg["vault"], "AgentVault")
    guard = contract(w3, cfg["reefGuard"], "ReefGuard")
    token = contract(w3, cfg["asset"], "MockERC20")
    adapter = contract(w3, cfg["strategyAdapter"], "MockStrategyAdapter")

    idle = rpc_read(lambda: token.functions.balanceOf(cfg["vault"]).call())
    current_strategy = rpc_read(lambda: vault.functions.currentStrategy().call())
    strategy_underlying = (
        0
        if current_strategy == ZERO
        else rpc_read(lambda: adapter.functions.totalUnderlying().call())
    )
    nav = rpc_read(lambda: vault.functions.nav().call())
    high_water_nav = rpc_read(lambda: vault.functions.highWaterNav().call())
    max_bps = env_int("ACTION_BPS", 2000)
    guard_allowed, guard_reason = rpc_read(
        lambda: guard.functions.canExecute(cfg["agentId"], cfg["asset"], max_bps).call()
    )
    state = {
        "agentId": cfg["agentId"],
        "vault": cfg["vault"],
        "asset": cfg["asset"],
        "nav": str(nav),
        "highWaterNav": str(high_water_nav),
        "idle": str(idle),
        "currentStrategy": current_strategy,
        "strategyUnderlying": str(strategy_underlying),
        "strategyKind": cfg.get("strategyKind", "mock"),
        "strategyLabel": cfg.get("strategyLabel", "Mock testnet yield adapter"),
        "guardAllowed": bool(guard_allowed),
        "guardReason": guard_reason,
    }
    decision = normalize_decision(strategy.decide(state))
    action = decision["action"]
    size_bps = (
        0
        if action == "hold"
        else max(1, min(abs(decision["nav_delta_bps"]) or max_bps, max_bps))
    )

    move_status = "hold"
    tx_hashes: dict[str, str] = {}
    if action == "increase":
        allowed, reason = rpc_read(
            lambda: guard.functions.canExecute(
                cfg["agentId"], cfg["asset"], size_bps
            ).call()
        )
        if not allowed:
            move_status = f"guard-refused: {reason}"
        elif not (
            current_strategy == ZERO or same(current_strategy, cfg["strategyAdapter"])
        ):
            move_status = "different-active-strategy"
        else:
            amount = (idle * size_bps) // 10_000
            if amount > 0:
                receipt = send_tx(
                    w3,
                    account,
                    vault.functions.deployToStrategy(cfg["strategyAdapter"], amount),
                )
                tx_hashes["deployTx"] = w3.to_hex(receipt["transactionHash"])
                move_status = "deployed"
            else:
                move_status = "no-idle"
    elif action == "decrease":
        if current_strategy == ZERO:
            move_status = "nothing-to-recall"
        else:
            amount = (strategy_underlying * size_bps) // 10_000
            if amount > 0:
                receipt = send_tx(
                    w3,
                    account,
                    vault.functions.recallFromStrategy(current_strategy, amount),
                )
                tx_hashes["recallTx"] = w3.to_hex(receipt["transactionHash"])
                move_status = "recalled"
            else:
                move_status = "nothing-to-recall"

    evidence = keccak(decision["reasoning"].encode("utf-8"))
    seq = rpc_read(lambda: vault.functions.nextReceiptSeq().call())
    period = env_int("RECEIPT_PERIOD_S", 600)
    receipt_args = sign_receipt(
        account.key,
        vault=cfg["vault"],
        chain_id=w3.eth.chain_id,
        agent_id=cfg["agentId"],
        seq=seq,
        evidence_hash=evidence,
        claimed_delta=0,
        period=period,
    )
    receipt = send_tx(w3, account, vault.functions.publishReceipt(*receipt_args))
    record = {
        **state,
        **decision,
        **tx_hashes,
        "moveStatus": move_status,
        "seq": seq,
        "receiptTx": w3.to_hex(receipt["transactionHash"]),
        "evidenceHash": w3.to_hex(evidence),
        "ts": int(time.time()),
    }
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "proofbound-agent.json").write_text(
        json.dumps(record, indent=2), encoding="utf-8"
    )
    print(f"agent {cfg['agentId']} {action}: {move_status}; receipt seq={seq}")
    return record


def main() -> int:
    cfg = load_config()
    chain = load_chain(cfg.get("network", "mantle-sepolia"))
    w3 = get_w3(os.getenv("MANTLE_SEPOLIA_RPC") or cfg.get("rpc") or chain.rpc_url)
    account = load_account()
    if not same(account.address, cfg["operator"]):
        raise RuntimeError(
            f"PRIVATE_KEY is {account.address}, expected operator {cfg['operator']}"
        )
    out_dir = Path(os.getenv("AGENT_OUT_DIR", HERE / "out"))
    sleep_s = env_int("RECEIPT_PERIOD_S", 600)
    while True:
        cycle(w3, account, cfg, out_dir)
        if os.getenv("RUN_ONCE") == "1":
            return 0
        time.sleep(sleep_s)


if __name__ == "__main__":
    raise SystemExit(main())
