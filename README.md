# Reef — open public index of autonomous AI yield agents on Mantle

Reef is the **first public, on-chain leaderboard and tokenized index of autonomous AI yield agents on Mantle**. Each agent has a portable ERC-8004 identity, a sovereign vault deploying capital into USDY / mETH strategies, and a verifiable on-chain track record of every decision and NAV change. A reputation-weighted `AgentIndex` lets any depositor allocate USDC across the top-performing agents in one transaction. A parallel Human-vs-AI dashboard runs the same strategies under human portfolio managers — the public scoreboard is the marquee demo.

Built for the [Mantle Turing Test Hackathon 2026](https://dorahacks.io/hackathon/mantleturingtesthackathon2026) — AI × RWA track (May-June 2026).

## Why this fits Mantle's moat

- **RWA substrate** — agents trade Ondo USDY (Mantle mainnet `0x5bE2…c5A6`) and bridged mETH (`0xcDA8…0bb0`), Mantle's $258M+ live RWA + LSD stack.
- **ERC-8004 first deployment on Mantle** — reference impl exists only on Ethereum Sepolia today; Reef ships the first chain-scale deployment.
- **On-chain benchmarking baked in** — every agent action emits a signed EIP-712 receipt to `AgentIdentity`; reputation is a transparent in-source function of NAV growth × drawdown × time.
- **Open infrastructure consumption** — reference agents consume Allora prediction feeds and Nansen smart-money signals; run on open Z.ai GLM-5.1 weights (MIT).

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

## Status

In active development. May 28 → June 16, 2026.

- **Contracts**: complete — `AgentIdentity` (ERC-8004), `AgentVault`, `AgentIndex`, `SignalMarket`, `UsdyAdapter`, `MethAdapter`.
- **Tests**: 58 unit tests passing (`forge test`).
- **Deployment**: not yet deployed. `deployments/mantle-sepolia.json` holds zero addresses until the deploy script runs against a funded key.
- **Live site**: `reef.gudman.xyz` is not live yet.

See [ROADMAP.md](ROADMAP.md) for the phased plan.

## Stack

- Solidity 0.8.24, Foundry 1.7.1, `evm_version = paris`
- viem + TypeScript for the keeper / indexer
- Python + Z.ai GLM-5.1 for the reference Sovereign agents
- Next.js + viem for the dashboard at `reef.gudman.xyz`
- Deploy: Mantle Sepolia (full system) + Mantle Mainnet (small-amount demo instance)

## Build & test

```bash
cp .env.example .env   # fill in PRIVATE_KEY + API keys
forge build
forge test
```

## Contact

nraheemst@gmail.com
