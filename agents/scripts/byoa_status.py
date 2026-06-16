#!/usr/bin/env python
"""BYOA runtime status snapshot.

Reads one or more BYOA agent configs plus their public runtime output and writes
API_OUT_DIR/byoa/status.json. Read-only; safe to run from cron.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from agents.shared.client import get_w3, rpc_read, vault_contract
from agents.shared.config import REPO_ROOT, load_chain


def _load_configs() -> list[dict[str, Any]]:
    raw = os.getenv("BYOA_AGENT_CONFIGS")
    paths = [Path(p.strip()) for p in raw.split(",") if p.strip()] if raw else []
    if not paths:
        legacy = REPO_ROOT / "create-reef-agent" / "agent.json"
        if legacy.exists():
            paths.append(legacy)
        paths.extend((REPO_ROOT / "create-reef-agent" / "agents").glob("*/agent.json"))
    configs = []
    seen: set[int] = set()
    for path in paths:
        if not path.exists():
            continue
        cfg = json.loads(path.read_text(encoding="utf-8"))
        aid = int(cfg["agentId"])
        if aid in seen:
            continue
        cfg["_configPath"] = str(path)
        seen.add(aid)
        configs.append(cfg)
    return sorted(configs, key=lambda c: int(c["agentId"]))


def _systemd(unit: str, *, field: str | None = None) -> str | None:
    if os.name == "nt":
        return None
    cmd = ["systemctl", "show", unit]
    if field:
        cmd.append(f"--property={field}")
    try:
        out = subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL).strip()
    except (OSError, subprocess.CalledProcessError):
        return None
    if field:
        prefix = f"{field}="
        return out[len(prefix) :] if out.startswith(prefix) else out
    return out


def _timer_line(unit: str) -> str | None:
    if os.name == "nt":
        return None
    try:
        out = subprocess.check_output(
            ["systemctl", "list-timers", "--all", unit, "--no-pager", "--no-legend"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return None
    return out.splitlines()[0].strip() if out else None


def _runtime_doc(out_dir: Path, agent_id: int) -> dict[str, Any] | None:
    path = out_dir / "byoa" / str(agent_id) / "proofbound-agent.json"
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except ValueError:
        return None


def main() -> int:
    network = os.getenv("REEF_NETWORK", "mantle-sepolia")
    out_dir = Path(os.getenv("API_OUT_DIR", str(REPO_ROOT / "ui" / "api")))
    stale_after = int(os.getenv("BYOA_STALE_SECONDS", "7200"))
    chain = load_chain(network)
    w3 = get_w3(chain.rpc_url)
    now = int(time.time())
    agents = []

    configs = _load_configs()
    if not configs:
        print("no BYOA configs found", file=sys.stderr)
        return 2

    for cfg in configs:
        aid = int(cfg["agentId"])
        vault = vault_contract(w3, cfg["vault"])
        last = int(rpc_read(lambda vault=vault: vault.functions.lastReceiptAt().call()))
        next_seq = int(
            rpc_read(lambda vault=vault: vault.functions.nextReceiptSeq().call())
        )
        nav = int(rpc_read(lambda vault=vault: vault.functions.nav().call()))
        current_strategy = rpc_read(
            lambda vault=vault: vault.functions.currentStrategy().call()
        )
        operator = w3.to_checksum_address(cfg["operator"])
        operator_balance = int(
            rpc_read(lambda operator=operator: w3.eth.get_balance(operator))
        )
        runtime = _runtime_doc(out_dir, aid)
        service = f"reef-byoa@{aid}.service"
        timer = f"reef-byoa@{aid}.timer"
        active = _systemd(timer, field="ActiveState")
        result = _systemd(service, field="Result")
        if active is None:
            legacy_timer = f"reef-byoa{aid}.timer"
            legacy_service = f"reef-byoa{aid}.service"
            active = _systemd(legacy_timer, field="ActiveState")
            result = _systemd(legacy_service, field="Result")
            timer = legacy_timer
        age = now - last if last else None
        status = "ok"
        if result and result not in ("success", ""):
            status = "failing"
        elif age is None or age > stale_after:
            status = "stale"
        elif active not in (None, "active"):
            status = "timer-inactive"
        agents.append(
            {
                "agentId": aid,
                "vault": cfg["vault"],
                "operator": operator,
                "strategyAdapter": cfg.get("strategyAdapter"),
                "strategyKind": cfg.get("strategyKind", "mock"),
                "currentStrategy": current_strategy,
                "lastReceiptAt": last,
                "receiptAgeSec": age,
                "latestSeq": next_seq - 1,
                "nextSeq": next_seq,
                "navE18": str(nav),
                "operatorBalanceWei": str(operator_balance),
                "runtime": runtime,
                "timerUnit": timer,
                "timerActiveState": active,
                "timerLine": _timer_line(timer),
                "lastServiceResult": result,
                "status": status,
            }
        )
        print(f"agent {aid}: {status} seq={next_seq - 1} age={age}")

    doc = {"agents": agents, "updatedAt": now, "staleAfterSec": stale_after}
    out_path = out_dir / "byoa" / "status.json"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = out_path.with_name(out_path.name + ".tmp")
    tmp.write_text(json.dumps(doc, indent=2), encoding="utf-8")
    os.replace(tmp, out_path)
    print(f"wrote {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
