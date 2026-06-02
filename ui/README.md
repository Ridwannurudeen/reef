# Reef UI

Single-page, vanilla-JS, viem-only product interface for the Reef on-chain index
of autonomous AI yield agents on Mantle. It now presents Reef as an institutional
Agent Yield Arena first, then exposes the live direct-on-chain dashboard below.
Reads `AgentIdentity`, `AgentIndex`, and per-agent `AgentVault` contracts directly
via the RPC; no backend, no indexer required for the app.

## Design benchmark

The redesign uses top-tier crypto product patterns instead of a generic admin
console:

- **Hyperliquid**: live terminal density, large tabular signature numbers, restrained motion.
- **Ethena**: stablecoin/yield confidence, earned accent color, proof-first product framing.
- **Morpho**: quiet institutional layout, high trust through clear metrics and minimal chrome.
- **Pendle**: yield dashboard hierarchy, tables that feel dense without looking crowded.

The first viewport is intentionally not a config form. It is the product: live
`rINDEX` NAV, total assets, vault count, proof path, and receipt freshness.

## Run

Serve the **repo root** (not `ui/`) so the page can fetch `../deployments/mantle-sepolia.json`:

```bash
# from the repo root
python -m http.server 8080
# then open http://localhost:8080/ui/
```

No build step. (Serving `-d ui` breaks the deployment-JSON load, since it lives one level up.)

## Public API

`agents/scripts/api_snapshot.py` snapshots on-chain state to a static `reef.json`
(meta + index + reputation-ranked agents + season standings) — served live at
**https://reef.gudman.xyz/api/reef.json** and refreshed by cron. Reef as the
ecosystem's agent-intelligence layer, with no backend.

## Required config (saved to `localStorage` under `reef.ui.v1`)

- `RPC_URL` — defaults to `https://rpc.sepolia.mantle.xyz`
- `IDENTITY_ADDR` — deployed `AgentIdentity`
- `INDEX_ADDR` — deployed `AgentIndex`
- `ASSET_ADDR` — the index's underlying asset (e.g. USDY / MockUSDY on Sepolia)

On first load (no saved config) the page fetches `../deployments/mantle-sepolia.json`
and seeds `RPC_URL`, `IDENTITY_ADDR`, `INDEX_ADDR` and `ASSET_ADDR` from its `reef`
block. All-zero placeholder addresses are treated as "not configured", so until the
contracts are live the dashboard shows a clear "Contracts not deployed yet" empty
state instead of broken reads. Saved config in `localStorage` always takes precedence;
use **Save** in the Config panel to override.

The wallet button auto-adds Mantle Sepolia (`0x138b` / 5003) or Mantle mainnet
(`0x1388` / 5000) to the injected wallet and switches.

## Features

- Wallet connect: address, chain id, native MNT balance.
- Landing + live terminal: `rINDEX` NAV/share, total assets, total shares, vault
  count, recent rebalance sparkline, and receipt freshness.
- Proof rail: direct links for `AgentIdentity`, `AgentIndex`, `ReputationBond`,
  `Seasons`, and the live yield adapter from the deployment file.
- `AgentIndex` actions: your shares + assets,
  deposit (auto-approves only if allowance is short), withdraw, and the
  permissionless `rebalance()` button (disabled when `vaultCount() == 0`).
- Agent leaderboard: reads `getAllocation()`, joins each entry against
  `identity.getSummary(agentId)`, `vault.nav()`, and `vault.lastReceiptAt()`,
  sorts by reputation desc, and displays receipt freshness.
- SVG sparkline of recent `Rebalanced` events as a NAV proxy.
- Human-vs-AI: the same live vault NAVs under two weighting schemes. AI is
  reputation-weighted; Human is equal-weight. The delta is computed client-side.
- Activity feed: last 20 events across `AgentRegistered`, `IndexDeposit`,
  `IndexWithdraw`, `Rebalanced`, `ReceiptPublished` over the last ~5000 blocks.
- Auto-refresh: index every 15 s, feed every 30 s; paused on hidden tab.
- All tx errors render the revert reason from viem.

## Known limits

- Client-side reads only — no historical indexer. The NAV sparkline approximates
  index NAV with the `totalDeployed` field from `Rebalanced` events, not true NAV.
- 5000-block log window only; older activity is not shown.
- `ReceiptPublished` is read per registered vault (one `getLogs` call each); fine
  for a handful of vaults, not scalable to hundreds.
- No `multicall3` batching — sequential / `Promise.all` reads. Mantle Sepolia's
  RPC handles the small fan-out comfortably.
- Human Twin is a deliberately simple equal-weight basket. The on-chain `Seasons`
  contract handles cohort scoring; the UI comparison is a live explainer.
- Pins `viem@2.21.0` from `esm.sh?bundle`. If esm.sh is unreachable, the page
  will not load.
