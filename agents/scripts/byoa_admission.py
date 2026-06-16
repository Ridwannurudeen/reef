#!/usr/bin/env python
"""Enroll and admit a BYOA vault into Reef's governed cohorts.

Dry-run by default. Set BYOA_EXECUTE=1 to send any missing txs.
Uses PRIVATE_KEY for the agent operator and GOVERNOR_PRIVATE_KEY for governed
Allocator/TrustOracle actions. If GOVERNOR_PRIVATE_KEY is unset, PRIVATE_KEY is
used only when it matches the on-chain governor.
"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path
from typing import Any

from eth_account import Account

from agents.shared.client import get_w3, load_abi, load_account, rpc_read, send_tx
from agents.shared.config import DEPLOYMENTS_DIR, REPO_ROOT, load_chain

WAD = 10**18


def _config() -> dict[str, Any]:
    path = Path(
        os.getenv("AGENT_CONFIG", REPO_ROOT / "create-reef-agent" / "agent.json")
    )
    return json.loads(path.read_text(encoding="utf-8"))


def _contract(w3, address: str, name: str):
    return w3.eth.contract(address=w3.to_checksum_address(address), abi=load_abi(name))


def _maybe_account(env_name: str):
    key = os.getenv(env_name)
    if not key:
        return None
    if not key.startswith("0x"):
        key = "0x" + key
    return Account.from_key(key)


def _governor_account(expected: str):
    account = _maybe_account("GOVERNOR_PRIVATE_KEY")
    if account is None:
        try:
            account = load_account()
        except RuntimeError:
            return None
    return account if account.address.lower() == expected.lower() else None


def _tx_hex(receipt: dict) -> str:
    tx = receipt["transactionHash"]
    return tx.hex() if hasattr(tx, "hex") else str(tx)


def main() -> int:
    network = os.getenv("REEF_NETWORK", "mantle-sepolia")
    execute = os.getenv("BYOA_EXECUTE") == "1"
    side = int(os.getenv("BYOA_SEASON_SIDE", "1"))  # 0 Human, 1 AI
    chain = load_chain(network)
    data = json.loads((DEPLOYMENTS_DIR / f"{network}.json").read_text(encoding="utf-8"))
    cfg = _config()
    w3 = get_w3(chain.rpc_url)

    agent_id = int(cfg["agentId"])
    vault_addr = w3.to_checksum_address(cfg["vault"])
    operator_addr = w3.to_checksum_address(cfg["operator"])
    asset = w3.to_checksum_address(cfg["asset"])

    identity = _contract(w3, cfg["identity"], "AgentIdentity")
    index = _contract(w3, cfg["index"], "AgentIndex")
    vault = _contract(w3, vault_addr, "AgentVault")
    bond = _contract(w3, cfg["bond"], "ReputationBond")
    guard = _contract(w3, cfg["reefGuard"], "ReefGuard")

    wallet = rpc_read(lambda: identity.functions.getAgentWallet(agent_id).call())
    listed = bool(rpc_read(lambda: index.functions.isRegistered(vault_addr).call()))
    min_bond = int(rpc_read(lambda: index.functions.minBond().call()))
    posted_bond = int(rpc_read(lambda: bond.functions.bondOf(agent_id).call()))
    guard_ok, guard_reason = rpc_read(
        lambda: guard.functions.canExecute(agent_id, asset, 100).call()
    )
    last_receipt = int(rpc_read(lambda: vault.functions.lastReceiptAt().call()))
    rep, count = rpc_read(lambda: identity.functions.getSummary(agent_id).call())
    preflight = {
        "operatorMatches": wallet.lower() == operator_addr.lower(),
        "agentIndexListed": listed,
        "bondOk": posted_bond >= min_bond,
        "guardOk": bool(guard_ok),
        "guardReason": guard_reason,
        "hasReceipt": last_receipt > 0,
        "reputationE18": str(int(rep)),
        "receiptCount": int(count),
    }
    if not all(
        v
        for k, v in preflight.items()
        if k not in {"guardReason", "reputationE18", "receiptCount"}
    ):
        raise RuntimeError(f"BYOA preflight failed: {preflight}")

    results: dict[str, Any] = {
        "agentId": agent_id,
        "vault": vault_addr,
        "execute": execute,
        "preflight": preflight,
        "txs": {},
    }

    operator = None
    seasons_meta = data.get("seeded", {}).get("seasons", {})
    if seasons_meta.get("address"):
        seasons = _contract(w3, seasons_meta["address"], "Seasons")
        season_count = int(rpc_read(lambda: seasons.functions.seasonCount().call()))
        season_status: dict[str, Any] = {"seasonCount": season_count}
        if season_count:
            season_id = season_count - 1
            start, end, finalized = rpc_read(
                lambda: seasons.functions.seasons(season_id).call()
            )
            enrolled = bool(
                rpc_read(lambda: seasons.functions.enrolled(season_id, agent_id).call())
            )
            season_status.update(
                {
                    "seasonId": season_id,
                    "start": int(start),
                    "end": int(end),
                    "finalized": bool(finalized),
                    "enrolled": enrolled,
                    "side": side,
                }
            )
            if not enrolled and not finalized and int(time.time()) < int(end):
                if execute:
                    operator = load_account()
                    if operator.address.lower() != operator_addr.lower():
                        raise RuntimeError(
                            f"PRIVATE_KEY is {operator.address}, expected {operator_addr}"
                        )
                    receipt = send_tx(
                        w3,
                        operator,
                        seasons.functions.enroll(season_id, agent_id, side),
                    )
                    season_status["enrolled"] = True
                    results["txs"]["seasonEnroll"] = _tx_hex(receipt)
                else:
                    season_status["wouldEnroll"] = True
        results["season"] = season_status

    governor_targets = []
    alloc_meta = data.get("allocator")
    if alloc_meta and alloc_meta.get("address"):
        allocator = _contract(w3, alloc_meta["address"], "Allocator")
        gov = rpc_read(lambda: allocator.functions.governor().call())
        registered = bool(
            rpc_read(lambda: allocator.functions.isRegistered(vault_addr).call())
        )
        results["allocator"] = {
            "address": alloc_meta["address"],
            "governor": gov,
            "registered": registered,
        }
        if not registered:
            governor_targets.append(
                ("allocatorAddVault", gov, allocator.functions.addVault(vault_addr))
            )

    oracle_meta = data.get("trustOracle")
    if oracle_meta and oracle_meta.get("address"):
        oracle = _contract(w3, oracle_meta["address"], "TrustOracle")
        gov = rpc_read(lambda: oracle.functions.governor().call())
        registered_vault = rpc_read(lambda: oracle.functions.vaultOf(agent_id).call())
        registered = int(registered_vault, 16) != 0
        results["trustOracle"] = {
            "address": oracle_meta["address"],
            "governor": gov,
            "registered": registered,
            "vaultOf": registered_vault,
        }
        if not registered:
            governor_targets.append(
                (
                    "trustOracleRegisterVault",
                    gov,
                    oracle.functions.registerVault(vault_addr),
                )
            )

    if governor_targets:
        if execute:
            gov_addr = governor_targets[0][1]
            if any(t[1].lower() != gov_addr.lower() for t in governor_targets):
                raise RuntimeError("governed targets have different governors")
            governor = _governor_account(gov_addr)
            if governor is None:
                raise RuntimeError(f"missing governor key for {gov_addr}")
            for name, _gov, fn in governor_targets:
                receipt = send_tx(w3, governor, fn)
                results["txs"][name] = _tx_hex(receipt)
                if name == "allocatorAddVault":
                    results["allocator"]["registered"] = True
                if name == "trustOracleRegisterVault":
                    results["trustOracle"]["registered"] = True
                    results["trustOracle"]["vaultOf"] = vault_addr
        else:
            results["governanceDryRun"] = [name for name, _gov, _fn in governor_targets]

    print(json.dumps(results, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
