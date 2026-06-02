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

| Component | What it does | How to run |
|---|---|---|
| Reference agent (`agents.nansen_agent.agent` / `allora_agent.agent`) | Per-vault loop: read signal → decide → publish signed receipt | systemd service (one per vault) |
| Receipt loop (`agents/scripts/tick.sh`) | Publishes a paper-mode receipt to **all** seeded vaults each tick | cron |
| Rebalance keeper | Calls permissionless `AgentIndex.rebalance()` so allocations track reputation | cron |
| Health check (`agents.scripts.health`) | Flags vaults with stalled receipts; non-zero exit on staleness | cron + alert |

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
# public API snapshot every 10 min -> static /api/reef.json served by nginx
*/10 * * * * cd /opt/reef/app && API_OUT_DIR=/opt/reef/web/api /usr/bin/python3 -m agents.scripts.api_snapshot >> /var/log/reef-api.log 2>&1
```

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
