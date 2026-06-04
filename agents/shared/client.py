"""Web3 client + Foundry-ABI-backed contract bindings for Reef agents."""

from __future__ import annotations

import json
import os
import time
from pathlib import Path
from typing import Any

from eth_account import Account
from eth_account.signers.local import LocalAccount
from web3 import Web3
from web3.contract import Contract

# web3.py renamed geth_poa_middleware -> ExtraDataToPOAMiddleware in 6.14+;
# import whichever the installed version exposes.
try:
    from web3.middleware import geth_poa_middleware as _poa_middleware  # type: ignore[attr-defined]
except ImportError:  # web3 >=7 renamed geth_poa_middleware -> ExtraDataToPOAMiddleware
    from web3.middleware import ExtraDataToPOAMiddleware as _poa_middleware

from .config import FOUNDRY_OUT, load_chain


def get_w3(rpc_url: str | None = None) -> Web3:
    """Return a connected Web3 instance, trying each RPC in turn for failover.

    Pass a single URL, or a comma-separated list (also accepted via the
    MANTLE_SEPOLIA_RPC / MANTLE_RPC env var) — the first that connects wins.
    """
    raw = rpc_url or load_chain().rpc_url
    urls = [u.strip() for u in raw.split(",") if u.strip()]
    last_err: Exception | None = None
    for url in urls:
        try:
            w3 = Web3(Web3.HTTPProvider(url, request_kwargs={"timeout": 30}))
            # Mantle uses a PoA-style consensus; the extraData field exceeds 32
            # bytes without the POA middleware.
            w3.middleware_onion.inject(_poa_middleware, layer=0)
            if w3.is_connected():
                return w3
            last_err = RuntimeError(f"not connected to {url}")
        except Exception as e:  # noqa: BLE001 - fall through to the next RPC
            last_err = e
    raise RuntimeError(f"web3 not connected to any RPC {urls}: {last_err}")


def rpc_read(fn, *, attempts: int = 4, base_delay: float = 0.5):
    """Call an idempotent RPC read `fn`, retrying transient failures with backoff.

    Use only for reads (or gas estimation) — never to re-send a transaction, which
    could double-spend. Re-raises the last error after `attempts` tries.
    """
    last_err: Exception | None = None
    for i in range(attempts):
        try:
            return fn()
        except Exception as e:  # noqa: BLE001 - transient RPC/network error
            last_err = e
            if i < attempts - 1:
                time.sleep(base_delay * (2**i))
    raise RuntimeError(f"rpc_read failed after {attempts} attempts: {last_err}")


def load_account(private_key_env: str = "PRIVATE_KEY") -> LocalAccount:
    """Load a LocalAccount from the named env var."""
    key = os.getenv(private_key_env)
    if not key:
        raise RuntimeError(f"missing private key env var: {private_key_env}")
    if not key.startswith("0x"):
        key = "0x" + key
    return Account.from_key(key)


def load_artifact(contract_name: str) -> dict[str, Any]:
    """Load the Foundry compilation artifact for <contract_name> from out/.

    Looks for out/<contract_name>.sol/<contract_name>.json — the Foundry default
    layout produced by `forge build`.
    """
    path: Path = FOUNDRY_OUT / f"{contract_name}.sol" / f"{contract_name}.json"
    if not path.exists():
        raise FileNotFoundError(
            f"foundry artifact not found at {path}. Run `forge build` from the repo root."
        )
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def load_abi(contract_name: str) -> list[dict[str, Any]]:
    """Return the ABI array for <contract_name>."""
    return load_artifact(contract_name)["abi"]


def load_bytecode(contract_name: str) -> str:
    """Return deployable bytecode (hex string with 0x prefix) for <contract_name>."""
    art = load_artifact(contract_name)
    bc = art["bytecode"]
    obj = bc["object"] if isinstance(bc, dict) else bc
    if not obj.startswith("0x"):
        obj = "0x" + obj
    return obj


def identity_contract(w3: Web3, address: str) -> Contract:
    """Return an AgentIdentity contract binding at `address`."""
    return w3.eth.contract(
        address=Web3.to_checksum_address(address), abi=load_abi("AgentIdentity")
    )


def vault_contract(w3: Web3, address: str) -> Contract:
    """Return an AgentVault contract binding at `address`."""
    return w3.eth.contract(
        address=Web3.to_checksum_address(address), abi=load_abi("AgentVault")
    )


def index_contract(w3: Web3, address: str) -> Contract:
    """Return an AgentIndex contract binding at `address`."""
    return w3.eth.contract(
        address=Web3.to_checksum_address(address), abi=load_abi("AgentIndex")
    )


def send_tx(
    w3: Web3, account: LocalAccount, fn_call, *, gas: int | None = None, value: int = 0
) -> dict[str, Any]:
    """Build, sign, send a transaction; wait for the receipt; return it as a dict.

    `fn_call` is a prepared contract function call (e.g. `vault.functions.publishReceipt(payload)`).
    `value` (wei) is for payable calls (e.g. a native-token DEX swap).
    """
    nonce = rpc_read(lambda: w3.eth.get_transaction_count(account.address, "pending"))
    tx: dict[str, Any] = {
        "from": account.address,
        "nonce": nonce,
        "chainId": w3.eth.chain_id,
        "value": value,
    }
    # Try EIP-1559 fees; fall back to legacy gasPrice if base fee is unavailable.
    try:
        base_fee = rpc_read(lambda: w3.eth.get_block("latest")).get("baseFeePerGas")
        if base_fee is not None:
            priority = w3.to_wei(1, "gwei")
            tx["maxPriorityFeePerGas"] = priority
            tx["maxFeePerGas"] = base_fee * 2 + priority
        else:
            tx["gasPrice"] = rpc_read(lambda: w3.eth.gas_price)
    except Exception:
        tx["gasPrice"] = rpc_read(lambda: w3.eth.gas_price)

    if gas is not None:
        tx["gas"] = gas
    else:
        # Let the node estimate; add a 25% buffer.
        est = rpc_read(
            lambda: fn_call.estimate_gas({"from": account.address, "value": value})
        )
        tx["gas"] = int(est * 5 // 4)

    built = fn_call.build_transaction(tx)
    signed = account.sign_transaction(built)
    # eth_account renamed .rawTransaction -> .raw_transaction in 0.13.
    raw = getattr(signed, "raw_transaction", None) or signed.rawTransaction
    tx_hash = w3.eth.send_raw_transaction(raw)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=180)
    # A mined-but-reverted tx (status 0) is a failure, not a trade — surface it so callers
    # don't record a reverted swap/receipt as if it succeeded.
    if receipt.get("status") != 1:
        raise RuntimeError(f"tx reverted on-chain: {tx_hash.hex()}")
    return dict(receipt)
