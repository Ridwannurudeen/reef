#!/usr/bin/env python
"""mETH rate keeper — sync the live L1 mETH->ETH rate onto the Mantle L2 MethRate store.

mETH is non-rebasing; its exchange rate is maintained on L1 Ethereum (the Mantle LSP staking
contract's mETHToETH). The bridged L2 token has no rate function, so MethRateAdapter reads a small
on-chain MethRate store instead. This keeper reads the live L1 rate and pushes it to that L2 store
(setRate, keeper-gated) whenever it drifts past a threshold — keeping the mainnet mETH vault's NAV
in step with real accrued staking yield.

Required env: ETHEREUM_RPC (L1 archive/public RPC), PRIVATE_KEY (the MethRate keeper),
              METH_RATE_ADDR or deployments/mantle-mainnet.json:methDeployment.methRate.
Optional env: MANTLE_RPC (default https://rpc.mantle.xyz), RATE_PUSH_THRESHOLD_BPS (default 5).
Run (from repo root): ETHEREUM_RPC=<l1 rpc> python -m agents.scripts.meth_rate_push
"""

from __future__ import annotations

import json
import os
import sys

from agents.shared.client import get_w3, load_account, rpc_read, send_tx
from agents.shared.config import DEPLOYMENTS_DIR

L1_STAKING = (
    "0xe3cBd06D7dadB3F4e6557bAb7EdD924CD1489E8f"  # Mantle LSP staking (mETHToETH)
)
WAD = 10**18

_RATE_FN_ABI = [
    {
        "name": "mETHToETH",
        "inputs": [{"type": "uint256"}],
        "outputs": [{"type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    }
]
_STORE_ABI = _RATE_FN_ABI + [
    {
        "name": "rate",
        "inputs": [],
        "outputs": [{"type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "name": "setRate",
        "inputs": [{"type": "uint256"}],
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function",
    },
]


def _store_address() -> str:
    addr = os.getenv("METH_RATE_ADDR")
    if not addr:
        path = DEPLOYMENTS_DIR / "mantle-mainnet.json"
        if path.exists():
            data = json.loads(path.read_text(encoding="utf-8"))
            addr = (data.get("methDeployment") or {}).get("methRate", "")
    if not addr or int(addr, 16) == 0:
        raise RuntimeError(
            "MethRate address not set: set METH_RATE_ADDR or deploy first"
        )
    return addr


def main() -> int:
    l1_rpc = os.getenv("ETHEREUM_RPC")
    if not l1_rpc:
        print("ETHEREUM_RPC required (L1 rate source)", file=sys.stderr)
        return 2
    l2_rpc = os.getenv("MANTLE_RPC", "https://rpc.mantle.xyz")
    threshold_bps = int(os.getenv("RATE_PUSH_THRESHOLD_BPS", "5"))

    # Read the live L1 mETH->ETH rate (value of 1 mETH in ETH, WAD).
    l1 = get_w3(l1_rpc)
    staking = l1.eth.contract(
        address=l1.to_checksum_address(L1_STAKING), abi=_RATE_FN_ABI
    )
    l1_rate = rpc_read(lambda: staking.functions.mETHToETH(WAD).call())
    if not (WAD <= l1_rate < 2 * WAD):
        print(f"L1 rate {l1_rate} out of sane range; refusing to push", file=sys.stderr)
        return 1

    # Compare with the on-chain L2 store; push only if it has drifted past the threshold.
    l2 = get_w3(l2_rpc)
    store_addr = l2.to_checksum_address(_store_address())
    store = l2.eth.contract(address=store_addr, abi=_STORE_ABI)
    current = rpc_read(lambda: store.functions.rate().call())
    drift_bps = abs(l1_rate - current) * 10_000 // current if current else 10_000
    print(
        f"L1 rate {l1_rate / WAD:.6f} | L2 rate {current / WAD:.6f} | drift {drift_bps} bps"
    )
    if drift_bps < threshold_bps:
        print(f"within {threshold_bps} bps threshold — no push needed")
        return 0

    account = load_account()
    receipt = send_tx(l2, account, store.functions.setRate(l1_rate))
    print(f"pushed rate {l1_rate / WAD:.6f} in tx {receipt['transactionHash'].hex()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
