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
3. **Agent-to-agent commerce primitive** — `SignalMarket` lets agents pay each other for signals; both parties accrue reputation. This is the smallest real demonstration of an agent economy on Mantle.

## Architecture

```
AgentIdentity (ERC-8004)
       │
       │── reputation receipts via giveFeedback
       │
AgentVault[]                     SignalMarket
       │                                │
       │── deploys to                   │── A2A payment + receipts
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
| `AgentIdentity.sol` (ERC-8004) | Done. 13 tests. 5,190 B runtime. |
| `AgentVault.sol` | Done. 14 tests. Full receipt pipeline. |
| `AgentIndex.sol` | Done. 12 tests. Reputation-weighted rebalance. |
| `SignalMarket.sol` (A2A) | Done. 7 tests. |
| `UsdyAdapter.sol` | Done. 7 local tests + **2 fork tests passing against live Ondo USDY on Mantle mainnet**. |
| `MethAdapter.sol` | Done. 5 tests. |
| Deploy script | `script/Deploy.s.sol` |
| Reference Python agents | `agents/allora_agent/` (Allora API + Z.ai GLM-5.1) + `agents/nansen_agent/` (mock signal in v1) |
| Live dashboard | `ui/index.html` — single-file viem dashboard with AgentIndex stats, leaderboard, deposit/withdraw, rebalance button, Human-vs-AI twin |
| Hackathon deck | `slides.html` (reveal.js) |
| nginx + cert deploy config | `deploy/` |

**Total: 58 unit tests + 2 mainnet-fork integration tests, all passing** (`forge test`). All deployed contracts are verified on Mantlescan. Forge 1.7.1, solc 0.8.24, evm_version paris.

## Hackathon Feature Alignment

- **On-chain benchmarking of AI** — every agent decision emits a strict-sequence signed receipt (`AgentVault.publishReceipt`). NAV history is recomputable from events.
- **ERC-8004 agent identity standard** — every Reef agent is registered via `AgentIdentity.register()`; reputation is portable and queryable. First chain-scale deployment on Mantle.
- **Radical transparency / Human-vs-AI** — the live dashboard runs an AI index and a human-twin index in parallel; the public scoreboard is the marquee demo.

## Demo Flow (≥ 2 min)

1. Open `https://reef.gudman.xyz` — show the AgentIndex panel (live NAV, total assets, share count).
2. Show the leaderboard — registered AgentVaults sorted by ERC-8004 reputation.
3. Show the AI vs. Human twin toggle.
4. Click **[Rebalance]** — see the reputation-weighted allocation update on-chain.
5. Open the deposit form — deposit a small amount of USDY/USDC. Show share mint.
6. Open Mantle explorer on one AgentVault — show recent `ReceiptPublished` events from the live Python reference agent.
7. (Optional) Show a SignalMarket purchase tx: agent A2A payment + reputation bumps.

## Honest Scope

- Deployed: full system is live on Mantle Sepolia (all contracts verified on Mantlescan). A Mantle Mainnet small-amount demo instance (~$20 USDY) is optional and not deployed in v1.
- Reference agents publish receipts in paper-mode (real signals consumed, NAV deltas are simulated decisions on-chain). Real Polymarket-style live execution is out of scope for v1.
- Nansen reference agent uses a deterministic mock signal in v1 (real Nansen MCP needs paid API access).
- `withdrawPool` and additional safety primitives present in production yield protocols are intentionally omitted for hackathon scope — the audit risk surface is documented in the README.
- Contracts are immutable and unaudited hackathon code.

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
