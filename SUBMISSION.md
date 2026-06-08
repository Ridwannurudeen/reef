# Reef — Mantle Turing Test 2026 Submission

> Do not submit this form without explicit approval.

## Project Name

Reef

## One-Line Description

Reef turns Mantle's ERC-8004 agent-identity layer into a live capital market: autonomous AI agents compete under public mandates, prove every decision with on-chain signed receipts, earn portable reputation, post slashable bonds (challengeable when they lie), and receive capital through a reputation-weighted index (rINDEX) — over a real RWA/yield substrate (USDY/mETH/FusionX).

## Track

**AI × RWA** (primary). Cross-eligible for Grand Champion, Best UI/UX, and the 20 Project Deployment Award.

## Live Demo

- **Dashboard**: https://reef.gudman.xyz — LIVE (HTTPS; auto-loads on-chain Sepolia data)
- **Slides**: https://reef.gudman.xyz/slides.html — LIVE
- **Repository**: https://github.com/Ridwannurudeen/reef

**Deployed & verified on Mantle Sepolia (chain 5003):**

| Contract | Address (verified on Mantlescan, chain 5003) |
|---|---|
| AgentIdentity (ERC-8004) | [`0x4eCE1853623CA801536d319cB9ddE454f5dA6dC7`](https://sepolia.mantlescan.xyz/address/0x4eCE1853623CA801536d319cB9ddE454f5dA6dC7) |
| AgentIndex (rINDEX) | [`0xC10eCcC78492395f12a8455C8A13471990c53047`](https://sepolia.mantlescan.xyz/address/0xC10eCcC78492395f12a8455C8A13471990c53047) |
| AdapterRegistry | [`0xc1ed73d6707701561df96abbbc37fc7e81f9cc36`](https://sepolia.mantlescan.xyz/address/0xc1ed73d6707701561df96abbbc37fc7e81f9cc36) |
| MockYieldAdapter (agent 1, live NAV) | [`0x63bad8f71455099ebc7a01743c42f9471301edeb`](https://sepolia.mantlescan.xyz/address/0x63bad8f71455099ebc7a01743c42f9471301edeb) |
| ReputationBond | [`0xef2f3602d5fe04487a971e5d749dac7343b8f895`](https://sepolia.mantlescan.xyz/address/0xef2f3602d5fe04487a971e5d749dac7343b8f895) |
| Seasons | [`0xbf8f5e4434f4467cd1d9e10ea5c58fdcf67e5a80`](https://sepolia.mantlescan.xyz/address/0xbf8f5e4434f4467cd1d9e10ea5c58fdcf67e5a80) |
| Asset (demo MockERC20) | [`0xbc17D7F8f265d069781ed765914ED092989d92e7`](https://sepolia.mantlescan.xyz/address/0xbc17D7F8f265d069781ed765914ED092989d92e7) |

Seeded with **5 AgentVaults** (all verified on Mantlescan); index holds 1,000 demo units with a reputation-weighted allocation of 526 / 1052 / 1578 / 2631 / 4210 bps. A VPS cron receipt loop (`agents/scripts/receipt_tick.py`) publishes **EIP-712-signed** strict-sequence receipts on-chain every 10 minutes (any keeper can relay them), keeping the agents live; the full per-vault address list is in `deployments/mantle-sepolia.json`.

## What Problem Are We Solving?

How do humans (and other agents) decide which AI agent to trust with capital? Today the answer is screenshots and tweets. There's no public, verifiable, on-chain way to compare AI yield agents at a glance. Reef makes every AI agent's performance, decisions, and reputation legible and composable on Mantle.

## Why This Fits Mantle's Moat

Mantle is the premier distribution layer for RWA — Ondo USDY, mETH (LSP), MI4 (Securitize basket), and fBTC anchor a $258M+ live RWA stack. Reef is built directly on that:

- **`UsdyAdapter`** integrates with the live Ondo USDY token (`0x5bE26527e817998A7206475496fDE1E68957c5A6`) — verified end-to-end against live Mantle mainnet via 2 passing Foundry fork tests (`test/UsdyAdapter.fork.t.sol`).
- **`MethAdapter`** integrates with bridged mETH (`0xcDA86A272531e8640cD7F1a92c01839911B90bb0`).
- **`AgentIdentity`** — an ERC-8004-aligned identity + reputation registry. Mantle deployed the official ERC-8004 standard to mainnet (Feb 2026); Reef is the **application layer on top of that agent-identity primitive** — turning identity into a live capital market where agents compete, prove decisions, earn reputation, and receive allocation.
- **`AgentIndex`** is a reputation-weighted basket — depositors hold one token, the index reweights across the top-performing AgentVaults in proportion to clamped-positive cumulative reputation. Permissionless `rebalance()`.

## What Is Novel?

Three layers, each minimal but together a new primitive:

1. **Per-agent vault** that is sovereign — operator never custodies funds, every cycle publishes a strict-sequence EIP-712 receipt, reputation accrues to the agent's ERC-8004 identity.
2. **Public index that prices reputation** — `AgentIndex` allocates a basket across registered AgentVaults in proportion to their on-chain track record. This is the missing trust infrastructure for autonomous AI capital.
3. **Agent-to-agent commerce primitive** — `SignalMarket` lets agents pay each other for signals on-chain. This is the smallest real demonstration of an agent economy on Mantle. (Reputation is intentionally not credited here — only an agent's own vault writes its reputation.)

## Architecture

```
AgentIdentity (ERC-8004)
       │
       │── reputation receipts via giveFeedback
       │
AgentVault[]                     SignalMarket
       │                                │
       │── deploys to                   │── A2A signal payment (no reputation)
       ▼                                ▼
StrategyAdapter (UsdyAdapter / MethAdapter)
       │
       │── holds USDY / mETH on Mantle
       ▼
   Real yield substrate ($258M RWA on Mantle)

AgentIndex
       │
       │── rebalance() weights by AgentIdentity reputation
       │── depositors hold one tokenized share
       ▼
   The "S&P 500 of AI yield agents"
```

## What Ships

| Component | Status |
|---|---|
| `AgentIdentity.sol` (ERC-8004) | Done. 14 tests. Vault-only reputation gate. |
| `AgentVault.sol` | Done. EIP-712-signed receipts (relayable, gasless agents) + risk-adjusted high-water-mark reputation; reentrancy-guarded + circuit breaker. |
| `AgentIndex.sol` (ERC-20) | Done. Reputation-weighted rebalance + tradeable share + bond gate + withdrawPool reserve + permissionless bonded self-listing. |
| `AdapterRegistry.sol` | Done. Governance allowlist of vetted strategy adapters. |
| `SignalMarket.sol` (A2A) | Done. |
| `ReputationBond.sol` | Done. Slashable bonds + dispute layer + rotatable (2-step) arbiter. |
| `Seasons.sol` | Done. On-chain time-boxed Human-vs-AI seasons (enroll → snapshot → finalize → winner). |
| `UsdyAdapter.sol` | Done. Local + **2 fork tests passing against live Ondo USDY on Mantle mainnet**. |
| `MethAdapter.sol` / `FbtcAdapter.sol` / `UsdeAdapter.sol` / `Mi4Adapter.sol` | Done. RWA/yield adapters (mETH, Ignition FBTC, Ethena USDe, Securitize MI4); mainnet addresses on-chain-verified. |
| `MockYieldAdapter.sol` | Done. Testnet linear-accruing adapter (live-NAV demo). |
| Deploy scripts | `script/Deploy.s.sol` + `Seed.s.sol` (Sepolia) + `DeployMainnet.s.sol` (mainnet-ready, real USDY) |
| Reference Python agents | `agents/allora_agent/` (Allora + Z.ai GLM-5.1) + `agents/nansen_agent/` (mock signal v1); fall back to a deterministic rule without API keys |
| Live dashboard | `ui/index.html` — single-file viem dashboard with AgentIndex stats, leaderboard, deposit/withdraw, rebalance button, Human-vs-AI twin |
| Hackathon deck | `slides.html` (reveal.js) |
| nginx + cert deploy config | `deploy/` |

**Total: 130 unit tests + 2 mainnet-fork integration tests, all passing** (`forge test`). All deployed Sepolia contracts are verified on Mantlescan. Forge 1.7.1, solc 0.8.24, evm_version paris. Internal security review in `SECURITY.md`.

## Hackathon Feature Alignment

- **Automated risk management (AI × RWA track core)** — a transparent, auditable policy maps the live ETH market signal (24h momentum) to a target exposure, and the agent executes a **real on-chain** recall (de-risk) or deploy (re-risk) on a DEX-backed vault to hit it. Proven live on Sepolia: exposure cut 80% → 20% on a risk-off signal and restored 20% → 80% on risk-on, every move verifiable on Mantlescan (`agents/scripts/risk_manager.py`; feed at `/api/risk.json`). Risk management you can verify, not a black box.
- **On-chain benchmarking of AI** — every agent decision emits a strict-sequence signed receipt (`AgentVault.publishReceipt`). NAV history is recomputable from events.
- **ERC-8004 agent identity standard** — every Reef agent is registered via `AgentIdentity.register()`; reputation is portable and queryable. First chain-scale deployment on Mantle.
- **Radical transparency / Human-vs-AI** — the dashboard runs the live AI index alongside a human-twin baseline (a client-side simulation in v1); the public scoreboard is the marquee demo.

## Demo Flow (≥ 2 min)

1. Open `https://reef.gudman.xyz` — show the AgentIndex panel (live NAV, total assets, share count).
2. Show the leaderboard — registered AgentVaults sorted by ERC-8004 reputation.
3. Show the AI vs. Human twin toggle.
4. Click **[Rebalance]** — see the reputation-weighted allocation update on-chain.
5. Open the deposit form — deposit a small amount of USDY/USDC. Show share mint.
6. Open Mantle explorer on one AgentVault — show recent `ReceiptPublished` events from the live Python reference agent.
7. Open `/transparency` — the **Automated risk management** panel: a real on-chain de-risk (exposure 80% → 20% on a risk-off signal) and re-risk (20% → 80% on risk-on), each linked to its Mantlescan tx. This is the AI × RWA "automated risk management" loop, verifiable end to end.
8. (Optional) Show a SignalMarket purchase tx: agent-to-agent payment on-chain.

## Honest Scope

- Deployed: full system is live on Mantle Sepolia (all contracts Mantlescan-verified). Mainnet is not deployed but is **mainnet-ready** via `script/DeployMainnet.s.sol` (wires the real Ondo USDY adapter). Sepolia uses a mock asset + the testnet `MockYieldAdapter`.
- **Live AI:** agents decide via **Z.ai GLM** (`glm-4.7-flash`) from a **real market signal** (CoinGecko ETH price + 24h momentum) plus on-chain NAV state — e.g. at a drawdown with ETH down ~2.9% the agent chose `decrease`, citing the momentum. When an agent chooses to increase, it **executes a real swap on a Mantle-native DEX (FusionX V2)**; decisions + real swap txHashes are served at `/api/executions.json` and verifiable on Mantlescan. Deterministic fallback (recorded `source:"fallback"`) if the model is unavailable.
- Reputation is **NAV-derived + risk-adjusted**: `publishReceipt` credits the real on-chain per-share NAV change only above the agent's high-water mark. On testnet NAV grows via `MockYieldAdapter`; on mainnet it would be real USDY/mETH yield.
- Honest scope: agents decide from a live market signal + on-chain NAV and execute real swaps on a Mantle DEX; swaps acquire tokens to the operator wallet (agent-level execution), with routing into vault NAV via a strategy adapter as a follow-up. The core contribution remains the verifiable trust + reputation + capital-allocation layer.
- The internal-review must-fixes are resolved in source (#2 inflation, #3 adapter allowlist, #6/#10 ReputationBond hardening, #7 SafeERC20) and the Phase 4 safety primitives are in (circuit breaker `Pausable`, `withdrawPool` reserve, rotatable arbiter, permissionless bonded self-listing, on-chain `Seasons`) — see `SECURITY.md`/`ROADMAP.md`. A **third-party audit** is now the only prerequisite before mainnet TVL. The core set (identity, index/rINDEX, AdapterRegistry, 5 reputation-weighted vaults) was redeployed on Sepolia 2026-06-01 with this current code and re-verified on Mantlescan (see `deployments/mantle-sepolia.json`); ReputationBond/Seasons/MockYieldAdapter remain source-complete and ship in the full audited deploy.
- Contracts are immutable, **unaudited** hackathon code — see `SECURITY.md` before any mainnet TVL.

## Current Status / What's Left to Submit

The system is **live on Mantle Sepolia** and the dashboard is up at https://reef.gudman.xyz. Status:

- [x] **Deployed to Mantle Sepolia** — `script/Deploy.s.sol`; live addresses in `deployments/mantle-sepolia.json`.
- [x] **Seeded agents** — 5 AgentVaults registered + funded, initial receipts published; reputation-weighted index live (`script/Seed.s.sol`).
- [x] **Contracts verified** — all 8 contracts verified on Mantlescan (Etherscan API V2).
- [x] **Live site** — `reef.gudman.xyz` serving the dashboard + `slides.html` over HTTPS.
- [ ] **Record the demo video** — walk the Demo Flow above against the live deployment.
- [ ] **Submit** — only after explicit approval (see top of this file).

(Optional) Mantle Mainnet small-amount demo instance (~$20 USDY) per the Honest Scope above.

## Team

Ridwan Nurudeen

## Contact

nraheemst@gmail.com
