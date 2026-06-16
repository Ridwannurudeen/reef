#!/usr/bin/env python
"""Snapshot recent Reef on-chain activity to static JSON.

Reads recent AgentIdentity, AgentIndex, and AgentVault events once from the VPS
cron path and writes API_OUT_DIR/activity.json so the browser does not need to
fan out eth_getLogs calls across every vault on load.
"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path
from typing import Any

from agents.shared.client import (
    get_w3,
    identity_contract,
    index_contract,
    vault_contract,
)
from agents.shared.config import DEPLOYMENTS_DIR, REPO_ROOT, load_chain


def _hex(value: Any) -> str:
    raw = value.hex() if hasattr(value, "hex") else str(value)
    return raw if raw.startswith("0x") else f"0x{raw}"


def _fmt_18(value: int, digits: int = 4) -> str:
    return f"{int(value) / 10**18:.{digits}f}"


def _fmt_signed_18(value: int, digits: int = 4) -> str:
    sign = "-" if int(value) < 0 else ""
    return f"{sign}{abs(int(value)) / 10**18:.{digits}f}"


def _short(address: str) -> str:
    return f"{address[:6]}...{address[-4:]}" if address else "-"


def _timestamp(w3, cache: dict[int, int], block_number: int) -> int:
    if block_number not in cache:
        cache[block_number] = int(w3.eth.get_block(block_number)["timestamp"])
    return cache[block_number]


def _event_doc(w3, cache: dict[int, int], log, event_name: str, detail: str) -> dict:
    block_number = int(log["blockNumber"])
    return {
        "eventName": event_name,
        "detail": detail,
        "blockNumber": block_number,
        "transactionHash": _hex(log["transactionHash"]),
        "timestamp": _timestamp(w3, cache, block_number),
    }


def main() -> int:
    network = os.getenv("REEF_NETWORK", "mantle-sepolia")
    out_dir = Path(os.getenv("API_OUT_DIR", str(REPO_ROOT / "ui" / "api")))
    window = int(os.getenv("ACTIVITY_WINDOW_BLOCKS", "200"))
    chain = load_chain(network)
    data = json.loads((DEPLOYMENTS_DIR / f"{network}.json").read_text(encoding="utf-8"))
    reef = data["reef"]
    w3 = get_w3(chain.rpc_url)
    identity = identity_contract(w3, reef["AgentIdentity"])
    index = index_contract(w3, reef["AgentIndex"])
    allocation = index.functions.getAllocation().call()
    head = int(w3.eth.block_number)
    from_block = max(0, head - window)
    timestamps: dict[int, int] = {}
    events = []
    nav_history = []

    def collect(event, event_name: str, detail_fn):
        for log in event.get_logs(from_block=from_block, to_block=head):
            events.append(_event_doc(w3, timestamps, log, event_name, detail_fn(log)))

    collect(
        identity.events.AgentRegistered(),
        "AgentRegistered",
        lambda log: (
            f"agentId={log['args']['agentId']} wallet={_short(log['args']['wallet'])}"
        ),
    )
    collect(
        index.events.IndexDeposit(),
        "IndexDeposit",
        lambda log: (
            f"{_short(log['args']['depositor'])} assets={_fmt_18(log['args']['assets'])} "
            f"shares={_fmt_18(log['args']['shares'])}"
        ),
    )
    collect(
        index.events.IndexWithdraw(),
        "IndexWithdraw",
        lambda log: (
            f"{_short(log['args']['depositor'])} assets={_fmt_18(log['args']['assets'])} "
            f"shares={_fmt_18(log['args']['shares'])}"
        ),
    )
    rebalance_logs = index.events.Rebalanced().get_logs(
        from_block=from_block, to_block=head
    )
    for log in rebalance_logs:
        nav_history.append(str(int(log["args"]["totalDeployed"])))
        events.append(
            _event_doc(
                w3,
                timestamps,
                log,
                "Rebalanced",
                (
                    f"agents={log['args']['totalAgents']} "
                    f"totalDeployed={_fmt_18(log['args']['totalDeployed'])}"
                ),
            )
        )

    for agent_id, vault_addr, _weight_bps, _deployed in allocation:
        vault = vault_contract(w3, vault_addr)
        for log in vault.events.ReceiptPublished().get_logs(
            from_block=from_block, to_block=head
        ):
            events.append(
                _event_doc(
                    w3,
                    timestamps,
                    log,
                    "ReceiptPublished",
                    (
                        f"agentId={agent_id} seq={log['args']['seq']} "
                        f"navDelta={_fmt_signed_18(log['args']['navDelta'])}"
                    ),
                )
            )

    events.sort(key=lambda e: (e["blockNumber"], e["transactionHash"]), reverse=True)
    doc = {
        "events": events[:20],
        "navHistory": nav_history[-30:],
        "headBlock": head,
        "fromBlock": from_block,
        "updatedAt": int(time.time()),
    }
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "activity.json"
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(doc, indent=2), encoding="utf-8")
    os.replace(tmp, path)
    print(f"wrote {path} ({len(doc['events'])} events)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
