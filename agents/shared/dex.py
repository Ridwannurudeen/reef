"""Minimal FusionX V2 (Uniswap-V2-style) client for real swaps on Mantle Sepolia.

Lets an agent execute a genuine on-chain swap of native MNT into a token via the
FusionX V2 router (RPC-verified addresses live in deployments/mantle-sepolia.json
under `dex`). Used to back an agent's GLM decision with a real, verifiable on-chain
trade — no real funds (testnet MNT from the faucet). Pools are thin, so we always
quote with getAmountsOut and apply a slippage floor.
"""

from __future__ import annotations

import json
import time
from typing import Any

from web3 import Web3

from agents.shared.client import rpc_read, send_tx
from agents.shared.config import DEPLOYMENTS_DIR

_ROUTER_ABI = [
    {
        "type": "function",
        "name": "getAmountsOut",
        "stateMutability": "view",
        "inputs": [
            {"name": "amountIn", "type": "uint256"},
            {"name": "path", "type": "address[]"},
        ],
        "outputs": [{"name": "amounts", "type": "uint256[]"}],
    },
    {
        "type": "function",
        "name": "swapExactETHForTokens",
        "stateMutability": "payable",
        "inputs": [
            {"name": "amountOutMin", "type": "uint256"},
            {"name": "path", "type": "address[]"},
            {"name": "to", "type": "address"},
            {"name": "deadline", "type": "uint256"},
        ],
        "outputs": [{"name": "amounts", "type": "uint256[]"}],
    },
    {
        "type": "function",
        "name": "swapExactTokensForTokens",
        "stateMutability": "nonpayable",
        "inputs": [
            {"name": "amountIn", "type": "uint256"},
            {"name": "amountOutMin", "type": "uint256"},
            {"name": "path", "type": "address[]"},
            {"name": "to", "type": "address"},
            {"name": "deadline", "type": "uint256"},
        ],
        "outputs": [{"name": "amounts", "type": "uint256[]"}],
    },
]

_ERC20_ABI = [
    {
        "type": "function",
        "name": "approve",
        "stateMutability": "nonpayable",
        "inputs": [
            {"name": "spender", "type": "address"},
            {"name": "amount", "type": "uint256"},
        ],
        "outputs": [{"type": "bool"}],
    },
    {
        "type": "function",
        "name": "balanceOf",
        "stateMutability": "view",
        "inputs": [{"name": "owner", "type": "address"}],
        "outputs": [{"type": "uint256"}],
    },
]


def token_balance(w3: Web3, token: str, owner: str) -> int:
    erc = w3.eth.contract(address=Web3.to_checksum_address(token), abi=_ERC20_ABI)
    return int(
        rpc_read(
            lambda: erc.functions.balanceOf(Web3.to_checksum_address(owner)).call()
        )
    )


def swap_token_for_wmnt(
    w3: Web3,
    account,
    dex: dict[str, Any],
    token_in: str,
    amount_in: int,
    slippage_bps: int = 3000,
) -> dict[str, Any]:
    """Execute a real token -> WMNT swap (de-risk / 'decrease'). Approves the router first."""
    rt = router_contract(w3, dex)
    token_in = Web3.to_checksum_address(token_in)
    wmnt = Web3.to_checksum_address(dex["wmnt"])
    path = [token_in, wmnt]
    expected = int(
        rpc_read(lambda: rt.functions.getAmountsOut(amount_in, path).call())[-1]
    )
    amount_out_min = expected * (10_000 - slippage_bps) // 10_000
    erc = w3.eth.contract(address=token_in, abi=_ERC20_ABI)
    send_tx(
        w3,
        account,
        erc.functions.approve(Web3.to_checksum_address(dex["router"]), amount_in),
    )
    deadline = rpc_read(lambda: w3.eth.get_block("latest"))["timestamp"] + 600
    fn = rt.functions.swapExactTokensForTokens(
        amount_in, amount_out_min, path, account.address, deadline
    )
    receipt = send_tx(w3, account, fn)
    return {
        "dex": dex.get("name", "FusionX V2"),
        "router": dex["router"],
        "side": "sell",
        "tokenIn": token_in,
        "amountIn": str(amount_in),
        "expectedOut": str(expected),
        "amountOutMin": str(amount_out_min),
        "txHash": receipt["transactionHash"].hex(),
        "ts": int(time.time()),
    }


def load_dex(network: str = "mantle-sepolia") -> dict[str, Any]:
    data = json.loads((DEPLOYMENTS_DIR / f"{network}.json").read_text(encoding="utf-8"))
    dex = data.get("dex")
    if not dex or not dex.get("router"):
        raise RuntimeError("no dex config in deployment file")
    return dex


def router_contract(w3: Web3, dex: dict[str, Any]):
    return w3.eth.contract(
        address=Web3.to_checksum_address(dex["router"]), abi=_ROUTER_ABI
    )


def quote_native_to_token(
    w3: Web3, dex: dict[str, Any], token_out: str, amount_in_wei: int
) -> int:
    """getAmountsOut for [WMNT, token_out]; returns expected token_out amount."""
    rt = router_contract(w3, dex)
    path = [Web3.to_checksum_address(dex["wmnt"]), Web3.to_checksum_address(token_out)]
    amounts = rpc_read(lambda: rt.functions.getAmountsOut(amount_in_wei, path).call())
    return int(amounts[-1])


def swap_native_for_token(
    w3: Web3,
    account,
    dex: dict[str, Any],
    token_out: str,
    amount_in_wei: int,
    slippage_bps: int = 3000,
) -> dict[str, Any]:
    """Execute a real MNT -> token_out swap. Returns {txHash, amountIn, expectedOut, amountOutMin, tokenOut}.

    slippage_bps defaults to 30% because the testnet pools are very shallow.
    """
    rt = router_contract(w3, dex)
    token_out = Web3.to_checksum_address(token_out)
    path = [Web3.to_checksum_address(dex["wmnt"]), token_out]
    expected = quote_native_to_token(w3, dex, token_out, amount_in_wei)
    amount_out_min = expected * (10_000 - slippage_bps) // 10_000
    deadline = rpc_read(lambda: w3.eth.get_block("latest"))["timestamp"] + 600
    fn = rt.functions.swapExactETHForTokens(
        amount_out_min, path, account.address, deadline
    )
    receipt = send_tx(w3, account, fn, value=amount_in_wei)
    return {
        "dex": dex.get("name", "FusionX V2"),
        "router": dex["router"],
        "tokenOut": token_out,
        "amountIn": str(amount_in_wei),
        "expectedOut": str(expected),
        "amountOutMin": str(amount_out_min),
        "txHash": receipt["transactionHash"].hex(),
        "ts": int(time.time()),
    }
