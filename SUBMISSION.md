# Reef — Mantle Turing Test 2026 Submission

> Do not submit this form without explicit approval.

## Project Name

Reef

## One-Line Description

The first public, on-chain index of autonomous AI yield agents on Mantle — ERC-8004 identity, USDY/mETH yield substrate, reputation-weighted allocation, and a Human-vs-AI live leaderboard.

## Track

**AI × RWA** (primary). Cross-eligible for Grand Champion, Best UI/UX, and the 20 Project Deployment Award.

## Live Demo

- **Dashboard**: https://reef.gudman.xyz — LIVE (HTTPS; auto-loads on-chain Sepolia data)
- **Slides**: https://reef.gudman.xyz/slides.html — LIVE
- **Repository**: https://github.com/Ridwannurudeen/reef

**Deployed & verified on Mantle Sepolia (chain 5003):**

| Contract | Address (verified on Mantlescan) |
|---|---|
| AgentIdentity (ERC-8004) | [`0x75Ddb3Ef346C6C4995536D0368EE7C11160eddac`](https://sepolia.mantlescan.xyz/address/0x75Ddb3Ef346C6C4995536D0368EE7C11160eddac) |
| AgentIndex | [`0x9071f05834123ed4F71Ce342f1Af8e0a7077215E`](https://sepolia.mantlescan.xyz/address/0x9071f05834123ed4F71Ce342f1Af8e0a7077215E) |
| Asset (demo MockERC20) | [`0xbc17D7F8f265d069781ed765914ED092989d92e7`](https://sepolia.mantlescan.xyz/address/0xbc17D7F8f265d069781ed765914ED092989d92e7) |

Seeded with **5 AgentVaults** (all verified on Mantlescan); index holds 1,000 demo units with a reputation-weighted allocation of 526 / 1052 / 1578 / 2631 / 4210 bps. A paper-mode receipt loop (`agents/scripts/tick.sh`) publishes strict-sequence signed receipts on-chain.

## What Problem Are We Solving?

How do humans (and other agents) decide which AI agent to trust with capital? Today the answer is screenshots and tweets. There's no public, verifiable, on-chain way to compare AI yield agents at a glance. Reef makes every AI agent's performance, decisions, and reputation legible and composable on Mantle.

## Why This Fits Mantle's Moat

Mantle is the premier distribution layer for RWA — Ondo USDY, mETH (LSP), MI4 (Securitize basket), and fBTC anchor a $258M+ live RWA stack. Reef is built directly on that:

- **`UsdyAdapter`** integrates with the live Ondo USDY token (`0x5bE26527e817998A7206475496fDE1E68957c5A6`) — verified end-to-end against live Mantle mainnet via 2 passing Foundry fork tests (`test/UsdyAdapter.fork.t.sol`).
- **`MethAdapter`** integrates with bridged mETH (`0xcDA86A272531e8640cD7F1a92c01839911B90bb0`).
- **`AgentIdentity`** — Reef ships the **first chain-scale ERC-8004 deployment on Mantle**. The reference implementation existed only on Ethereum Sepolia; we deploy on Mantle natively.
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
| `AgentVault.sol` | Done. 14 tests. NAV-derived receipts; reentrancy-guarded. |
| `AgentIndex.sol` (ERC-20) | Done. 21 tests. Reputation-weighted rebalance + tradeable share + bond gate. |
| `SignalMarket.sol` (A2A) | Done. 9 tests. |
| `ReputationBond.sol` | Done. 9 tests. Slashable bonds + dispute layer. |
| `UsdyAdapter.sol` | Done. 7 local + **2 fork tests passing against live Ondo USDY on Mantle mainnet**. |
| `MethAdapter.sol` | Done. 5 tests. |
| `MockYieldAdapter.sol` | Done. 8 tests. Testnet linear-accruing adapter (real-NAV demo). |
| Deploy scripts | `script/Deploy.s.sol` + `Seed.s.sol` (Sepolia) + `DeployMainnet.s.sol` (mainnet-ready, real USDY) |
| Reference Python agents | `agents/allora_agent/` (Allora + Z.ai GLM-5.1) + `agents/nansen_agent/` (mock signal v1); fall back to a deterministic rule without API keys |
| Live dashboard | `ui/index.html` — single-file viem dashboard with AgentIndex stats, leaderboard, deposit/withdraw, rebalance button, Human-vs-AI twin |
| Hackathon deck | `slides.html` (reveal.js) |
| nginx + cert deploy config | `deploy/` |

**Total: 87 unit tests + 2 mainnet-fork integration tests, all passing** (`forge test`). All deployed Sepolia contracts are verified on Mantlescan. Forge 1.7.1, solc 0.8.24, evm_version paris. Internal security review in `SECURITY.md`.

## Hackathon Feature Alignment

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
7. (Optional) Show a SignalMarket purchase tx: agent-to-agent payment on-chain.

## Honest Scope

- Deployed: full system is live on Mantle Sepolia (all contracts Mantlescan-verified). Mainnet is not deployed but is **mainnet-ready** via `script/DeployMainnet.s.sol` (wires the real Ondo USDY adapter). Sepolia uses a mock asset + the testnet `MockYieldAdapter`.
- Reputation is **NAV-derived**: `publishReceipt` credits the vault's real on-chain per-share NAV change. On testnet that NAV grows via the `MockYieldAdapter`; on mainnet it would be real USDY/mETH yield. The reference agents' signals are advisory (paper-mode) and do not yet drive live mainnet execution.
- Nansen reference agent uses a deterministic mock signal in v1 (real Nansen MCP needs a paid key); agents fall back to a deterministic rule without an LLM key.
- The internal-review must-fixes are now resolved in source (#2 inflation, #3 adapter allowlist, #6/#10 ReputationBond hardening, #7 SafeERC20 — see `SECURITY.md`). `withdrawPool` + circuit breakers and a third-party audit remain prerequisites before mainnet TVL. The immutable Sepolia instances predate this pass; the fixes ship in a fresh deployment.
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
