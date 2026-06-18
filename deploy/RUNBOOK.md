# Reef — Operations Runbook

How to run and keep the Reef keeper stack healthy on the VPS. Covers the reference
agents, the rebalance keeper, the receipt loop, and monitoring/restart.

## Prerequisites

- `.env` at the repo root with `PRIVATE_KEY`, `MANTLE_SEPOLIA_RPC` (comma-separate
  multiple URLs for failover, e.g. `https://rpc.sepolia.mantle.xyz,https://<backup>`),
  and the deployed addresses already pinned in `deployments/mantle-sepolia.json`.
- Python deps: `pip install -r agents/requirements.txt` (web3 7.x).
- Foundry on PATH for `cast` (rebalance keeper + ad-hoc checks).

## Components

| Component                                                            | What it does                                                                  | How to run                      |
| -------------------------------------------------------------------- | ----------------------------------------------------------------------------- | ------------------------------- |
| Reference agent (`agents.nansen_agent.agent` / `allora_agent.agent`) | Per-vault loop: read signal → decide → publish signed receipt                 | systemd service (one per vault) |
| Receipt loop (`agents/scripts/tick.sh`)                              | Publishes a paper-mode receipt to **all** seeded vaults each tick             | cron                            |
| Rebalance keeper                                                     | Calls permissionless `AgentIndex.rebalance()` so allocations track reputation | cron                            |
| Health check (`agents.scripts.health`)                               | Flags vaults with stalled receipts; non-zero exit on staleness                | cron + alert                    |

## Reference agent as a systemd service (one per vault)

`/etc/systemd/system/reef-nansen@.service`:

```ini
[Unit]
Description=Reef Nansen agent (vault %i)
After=network-online.target

[Service]
WorkingDirectory=/opt/reef/app
EnvironmentFile=/opt/reef/app/.env
Environment=VAULT_ADDRESS=%i
ExecStart=/usr/bin/python -m agents.nansen_agent.agent
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

```bash
systemctl enable --now reef-nansen@0xde7af6Ea6C6d98BD56Bfc520C281c0C7047a3D85.service
journalctl -u 'reef-nansen@*' -f         # tail logs
systemctl restart 'reef-nansen@*.service' # restart all
```

The agent loop already catches per-cycle errors and continues; `Restart=always`
covers process death. RPC blips are absorbed by `get_w3` failover + `rpc_read`
backoff in `agents/shared/client.py`.

## Live cron (deployed on the VPS, `/opt/reef/app`)

The autonomous loop runs from `/opt/reef/app` (the `agents/` package + the three ABI
JSONs under `out/` + `deployments/mantle-sepolia.json` + `.env`; the host has `python3`
3.12 with `web3` 7.x / `eth_account` 0.13 preinstalled). Installed crontab:

```cron
# EIP-712 signed receipts to all vaults every 10 min (Python — typed-data signing)
*/10 * * * * cd /opt/reef/app && /usr/bin/python3 -m agents.scripts.receipt_tick >> /var/log/reef-tick.log 2>&1
# rebalance the index every 30 min so allocations follow reputation
*/30 * * * * cd /opt/reef/app && /usr/bin/python3 -m agents.scripts.keeper >> /var/log/reef-keeper.log 2>&1
# health check every 15 min (non-zero exit on staleness — wire to an alert)
*/15 * * * * cd /opt/reef/app && /usr/bin/python3 -m agents.scripts.health >> /var/log/reef-health.log 2>&1
# public API snapshot + history/guard rolls every 10 min -> static /api/*.json served by nginx
*/10 * * * * cd /opt/reef/app && API_OUT_DIR=/opt/reef/web/api /usr/bin/python3 -m agents.scripts.api_snapshot >> /var/log/reef-api.log 2>&1 && API_OUT_DIR=/opt/reef/web/api /usr/bin/python3 -m agents.scripts.history >> /var/log/reef-api.log 2>&1 && API_OUT_DIR=/opt/reef/web/api /usr/bin/python3 -m agents.scripts.guard_snapshot >> /var/log/reef-api.log 2>&1
# proof-bound receipt replay + veto proof packet every 10 min
*/10 * * * * cd /opt/reef/app && API_OUT_DIR=/opt/reef/web/api /usr/bin/python3 -m agents.scripts.proofbound_rebalance >> /var/log/reef-proofbound.log 2>&1 && API_OUT_DIR=/opt/reef/web/api /usr/bin/python3 -m agents.scripts.veto_proof_snapshot >> /var/log/reef-proofbound.log 2>&1
# automated risk management hourly: signal -> target exposure -> on-chain de-risk/re-risk on the DEX-NAV vault -> /api/risk.json
17 * * * * cd /opt/reef/app && API_OUT_DIR=/opt/reef/web/api MANTLE_SEPOLIA_RPC="https://rpc.sepolia.mantle.xyz,https://mantle-sepolia.drpc.org" /usr/bin/python3 -m agents.scripts.risk_manager >> /var/log/reef-risk.log 2>&1
# portable reputation: publish Trust Scores to Mantle's canonical ERC-8004 Reputation Registry (diff-gated — txs only when a score changes) + /api/canonical.json
54 */6 * * * cd /opt/reef/app && API_OUT_DIR=/opt/reef/web/api /usr/bin/python3 -m agents.scripts.canonical_feedback >> /var/log/reef-canonical.log 2>&1
```

`risk_manager` reads the `dexNavDemo` vault from `deployments/mantle-sepolia.json`, maps the
live ETH 24h momentum to a target exposure (20/40/60/80% at -6/-3/+3% bands), and calls
`deployToStrategy`/`recallFromStrategy` to hit it — logging each action (signal, band,
before/after exposure, txHash) to `/api/risk.json`. Force a scenario with
`RISK_FORCE_MOMENTUM=-7` (tagged `scenario`, never presented as a live reading).

`receipt_tick` and `keeper` resolve everything from `deployments/mantle-sepolia.json`
(`reef.AgentIndex` + `seeded.vaults`); override the index with `INDEX_ADDR`. `rebalance()`
is permissionless, so any keeper key works; receipts are EIP-712-signed by the operator
(`PRIVATE_KEY`) and may be relayed by anyone. After a redeploy, re-ship the updated
`deployments/mantle-sepolia.json` + `out/` ABIs to `/opt/reef/app` and `/opt/reef/web/deployments/`.
Keeper daemon alternative: `python3 -m agents.scripts.keeper --loop` (`KEEPER_INTERVAL_S`, default 600s).

## Monitoring & alerting

- `python -m agents.scripts.health` prints per-vault `lastReceiptAt` age and exits
  `1` if any vault is stale (default 3600s; override `STALE_AFTER_S`). Wire the
  non-zero exit to `reef-alert.sh` (email/Telegram).
- Receipt **gap** safety is enforced on-chain: `publishReceipt` reverts on a
  non-sequential `seq`, and agents read `nextReceiptSeq()` fresh each cycle, so a
  restart never skips or duplicates a sequence number.

## Restart / recovery

1. **Stalled agent:** `systemctl restart 'reef-nansen@<vault>.service'`; confirm with
   `python -m agents.scripts.health`.
2. **RPC outage:** add a backup URL to `MANTLE_SEPOLIA_RPC` (comma-separated) and
   restart — `get_w3` fails over to the first reachable endpoint.
3. **Allocations drift from reputation:** run the rebalance keeper once:
   `python -m agents.scripts.keeper` (or the raw `cast send <index> "rebalance()" ...`).
4. **Site down:** see `deploy/README.md` (nginx + cert); files live in `/opt/reef/web`.

## Mainnet FusionX benchmark (4 agents, REAL funds)

> UNAUDITED (SECURITY.md) — keep seeded capital at demo scale; mirrors the paused
> mETH-vault posture (tiny on-chain notional, demo-only).

This is a separate, self-contained instance on **Mantle mainnet (chain 5000)**: one shared
`AgentIdentity` + `AdapterRegistry`, then 4 `AgentVault` + `FusionXAdapter` pairs
(personas `GLM Synthesis`, `Momentum`, `Contrarian`, `HODL`). Each vault's asset is USDC
(`0x09Bc4E0D864854c6aFB6eB9A9cdF58aC190D0dF9`, **6 decimals**), swapped into a WMNT long
(`0x78c1b0C915c4FAA5FffA6CAbf0219DA63d7f4cb8`) via FusionX V2
(`0xDd0840118bF9CCCc6d67b2944ddDfbdb995955FD`, slippage 150 bps). NAV is a live
mark-to-market of a real position — the four agents compete on real PnL. It is fully
namespaced (`mainnet-*.json`) so it never collides with the live testnet arena.

### Prerequisites / funding

- A funded **Mantle-mainnet** key — real **MNT** for gas (becomes operator of all 4
  agents + registry governor).
- A small amount of **USDC** (the 6-decimal token above) to seed across the 4 vaults at
  demo scale. **USDC must be sourced on Mantle mainnet** (bridge/CEX withdrawal — there is
  no public faucet).
- The deploy script **seeds no funds** — you deposit manually afterwards (step 4).

### 1. Deploy the benchmark

```bash
PRIVATE_KEY=<funded mainnet key> \
forge script script/DeployMainnetFusionX.s.sol:DeployMainnetFusionX \
  --rpc-url https://mantle-rpc.publicnode.com --broadcast --legacy
```

`--legacy` is **required** (Mantle EIP-1559 fee estimation times out otherwise). Prior
mainnet deploys saw public RPCs drop `getCode` under forge fork load — this script seeds
no funds, so simulation should be clean, but prefer `mantle-rpc.publicnode.com` over
`rpc.mantle.xyz`. The script `require`s `block.chainid == 5000`.

### 2. Record addresses

The run prints a JSON `benchmark` block on stdout (shape:
`{"benchmark":{"identity":..,"registry":..,"vaults":[{agentId,persona,vault,adapter}..]}}`).
Paste it into `deployments/mantle-mainnet.json` at the **top level under the key
`benchmark`** — the keeper reads `data["benchmark"]["vaults"]` and
`data["benchmark"]["identity"]`.

### 3. Seed capital per vault (operator key)

The deploy seeds nothing. For **each of the 4 vaults**, as the operator/deployer key,
approve then deposit USDC (6 decimals — `1000000` = 1 USDC); the keeper then moves
exposure via `deployToStrategy`/`recallFromStrategy` on subsequent rounds:

```bash
# repeat per vault; AMOUNT is in USDC's 6 decimals (e.g. 1000000 = 1 USDC)
cast send 0x09Bc4E0D864854c6aFB6eB9A9cdF58aC190D0dF9 "approve(address,uint256)" <vault> <AMOUNT> \
  --rpc-url https://mantle-rpc.publicnode.com --legacy --private-key $PRIVATE_KEY
cast send <vault> "deposit(uint256)" <AMOUNT> \
  --rpc-url https://mantle-rpc.publicnode.com --legacy --private-key $PRIVATE_KEY
```

### 4. Run the keeper once

```bash
REEF_BENCHMARK=1 REEF_NETWORK=mantle-mainnet API_OUT_DIR=/opt/reef/web/api PRIVATE_KEY=<key> \
  python -m agents.scripts.mainnet_keeper
```

`REEF_BENCHMARK=1` is **required**: `mantle-mainnet.json`'s `reef.AgentIdentity` is `0x0`,
so `load_chain("mantle-mainnet")` raises unless `REEF_BENCHMARK` is set (the benchmark
reads `benchmark.identity`, not `reef.AgentIdentity`). Per-agent signers:
`AGENT<agentId>_PRIVATE_KEY` if set, else `PRIVATE_KEY`. Writes
`API_OUT_DIR/mainnet-nav.json` + `API_OUT_DIR/mainnet-arena.json`.

### 5. Cron lines (VPS)

Use a **dedicated mainnet key** for these so they never race nonces with the existing
reef crons (which run on the deployer/arena keys). Staggered, namespaced:

```cron
# MAINNET FusionX benchmark keeper every 20 min (dedicated mainnet key; demo-scale)
*/20 * * * * cd /opt/reef/app && REEF_BENCHMARK=1 REEF_NETWORK=mantle-mainnet API_OUT_DIR=/opt/reef/web/api PRIVATE_KEY=<mainnet key> /usr/bin/python3 -m agents.scripts.mainnet_keeper >> /var/log/reef-mainnet-keeper.log 2>&1
# Human-vs-AI turing transform a few min after the keeper (pure mainnet-nav+arena -> mainnet-turing-bench.json)
7,27,47 * * * * cd /opt/reef/app && REEF_BENCHMARK=1 REEF_NETWORK=mantle-mainnet API_OUT_DIR=/opt/reef/web/api /usr/bin/python3 -m agents.scripts.mainnet_turing_bench >> /var/log/reef-mainnet-bench.log 2>&1
```

`mainnet_turing_bench` is a pure transform (reads `mainnet-nav.json` + `mainnet-arena.json`
→ writes `mainnet-turing-bench.json`); ship it alongside the keeper before enabling its line.

### Honest scope

Yield/PnL is economically tiny at demo scale. The value is a **real on-chain multi-agent
PnL competition on mainnet** — every vault, swap, and signed receipt is Mantlescan-verifiable.
Contracts are **UNAUDITED**; keep notional at demo scale.
