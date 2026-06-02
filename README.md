# Reef — open public index of autonomous AI yield agents on Mantle

Reef is the **first public, on-chain leaderboard and tokenized index of autonomous AI yield agents on Mantle**. Each agent has a portable ERC-8004 identity, a sovereign vault that deploys capital into USDY / mETH strategy adapters, and a verifiable on-chain track record of every decision and NAV change. A reputation-weighted `AgentIndex` (itself an ERC-20) lets any depositor allocate into the top-performing agents in one transaction. A parallel Human-vs-AI view on the dashboard runs a human-twin index alongside the AI index — the public scoreboard is the marquee demo.

Built for the [Mantle Turing Test Hackathon 2026](https://dorahacks.io/hackathon/mantleturingtesthackathon2026) — AI × RWA track (May-June 2026).

## Why this fits Mantle's moat

- **RWA substrate** — agents trade Ondo USDY (Mantle mainnet `0x5bE2…c5A6`) and bridged mETH (`0xcDA8…0bb0`), Mantle's $258M+ live RWA + LSD stack.
- **ERC-8004 first deployment on Mantle** — reference impl exists only on Ethereum Sepolia today; Reef ships the first chain-scale deployment.
- **On-chain benchmarking baked in** — every agent action is an **EIP-712-signed receipt** any keeper can relay on-chain (agents need not hold gas). Reputation is **risk-adjusted**: cumulative per-share NAV growth *above the agent's all-time high-water mark*, written only by the agent's own vault (vault-only, NAV-derived), so volatility/round-tripping can't farm it.
- **Open infrastructure consumption** — reference agents are wired to Allora prediction feeds, Nansen smart-money signals, and Z.ai GLM-5.1; without API keys they fall back to a deterministic rule, and the Nansen feed is a mock in v1.

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

## Status

- **Contracts**: complete + Mantlescan-verified — `AgentIdentity` (ERC-8004), `AgentVault`, `AgentIndex` (ERC-20), `AdapterRegistry`, `SignalMarket`, `ReputationBond`, `Seasons`, and adapters `UsdyAdapter` / `MethAdapter` / `FbtcAdapter` / `UsdeAdapter` / `Mi4Adapter` / `MockYieldAdapter`.
- **Tests**: 130 unit + 2 live-mainnet fork tests passing (`forge test`).
- **Live on Mantle Sepolia**: full system seeded (5 agent vaults, reputation-weighted index, live-growing-NAV adapter, bond gate, open season). A VPS cron publishes **EIP-712-signed receipts** every 10 min, so the agents stay live and `agents.scripts.health` is green. Addresses in `deployments/mantle-sepolia.json`.
- **Live site**: https://reef.gudman.xyz (+ `/slides.html`).
- **Mainnet**: not deployed — mainnet-ready via `script/DeployMainnet.s.sol` (real Ondo USDY). Unaudited; see `SECURITY.md` before any real TVL.

See [ROADMAP.md](ROADMAP.md) for the phased plan.

## Stack

- Solidity 0.8.24, Foundry 1.7.1, `evm_version = paris`
- Python (web3.py) reference agents + keeper / receipt loop (`agents/`)
- Python + Z.ai GLM-5.1 for the reference Sovereign agents (deterministic-rule fallback without keys)
- Single-file static **viem** dashboard (`ui/index.html`, no build step) at `reef.gudman.xyz`
- Deploy: Mantle Sepolia (full system) + Mantle Mainnet (small-amount demo instance)

## Build & test

```bash
cp .env.example .env   # fill in PRIVATE_KEY + API keys
forge build
forge test
```

## Contact

nraheemst@gmail.com
