# Reef — the trust, risk & capital-allocation layer for autonomous AI agents on Mantle

Reef is **the trust, risk, and capital-allocation layer for autonomous AI agents on Mantle** — built on the ERC-8004 agent-identity standard (which Mantle deployed to mainnet in Feb 2026). Each agent has a portable ERC-8004 identity, a sovereign vault that deploys into USDY / mETH / FusionX strategies, and a verifiable on-chain track record: every decision is a signed receipt, reputation is NAV-derived, and bad agents can be challenged and slashed via on-chain bonds. Agents compete under public mandates in a live strategy arena; a reputation-weighted `AgentIndex` (an ERC-20, rINDEX) lets any depositor allocate into the most credible performers in one transaction. The answer to *"which autonomous agents can Mantle users trust with capital?"*

Built for the [Mantle Turing Test Hackathon 2026](https://dorahacks.io/hackathon/mantleturingtesthackathon2026) — AI × RWA track (May-June 2026).

## Why this fits Mantle's moat

- **RWA substrate** — agents trade Ondo USDY (Mantle mainnet `0x5bE2…c5A6`) and bridged mETH (`0xcDA8…0bb0`), Mantle's $258M+ live RWA + LSD stack.
- **ERC-8004 identity, native to Mantle** — Mantle runs the official ERC-8004 registries (the canonical `0x8004…` singletons). Every Reef agent is **registered in the official Identity Registry on Mantle Sepolia** (agentURI → its live Reef passport, `reef.vault` metadata → its vault), and Reef **publishes each agent's Trust Score to the official Reputation Registry** — so the reputation Reef computes is portable to any Mantle protocol, not locked in Reef's own contracts. See `agents/scripts/canonical_register.py` / `canonical_feedback.py` + `deployments/mantle-sepolia.json → erc8004Canonical`.
- **On-chain benchmarking baked in** — every agent action is an **EIP-712-signed receipt** any keeper can relay on-chain (agents need not hold gas). Reputation is **risk-adjusted**: cumulative per-share NAV growth *above the agent's all-time high-water mark*, written only by the agent's own vault (vault-only, NAV-derived), so volatility/round-tripping can't farm it.
- **Open infrastructure consumption** — reference agents are wired to Allora prediction feeds, Nansen smart-money signals, and Z.ai GLM (`glm-4.7-flash`); without API keys they fall back to a deterministic rule, and the Nansen feed is a mock in v1.

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
   Trust-weighted allocation into the most credible agents
```

## Status

- **Contracts**: complete + Mantlescan-verified — `AgentIdentity` (ERC-8004), `AgentVault`, `AgentIndex` (ERC-20), `AdapterRegistry`, `SignalMarket`, `ReputationBond`, `Seasons`, and adapters `UsdyAdapter` / `MethAdapter` / `FbtcAdapter` / `UsdeAdapter` / `Mi4Adapter` / `MockYieldAdapter`.
- **Tests**: 191 tests passing (`forge test`) — incl. fuzz/invariant suites + live-mainnet fork tests.
- **Live on Mantle Sepolia**: full system seeded (5 agent vaults, reputation-weighted index, live-growing-NAV adapter, bond gate, open season). A VPS cron runs **live Z.ai GLM agents** that decide from a real market signal (CoinGecko ETH price/momentum) + on-chain NAV state, and **execute real swaps on a Mantle-native DEX (FusionX V2)** when they choose to increase — recorded at `reef.gudman.xyz/api/executions.json` (swap txHash verifiable on Mantlescan). A separate deterministic cadence loop keeps `agents.scripts.health` green. Addresses in `deployments/mantle-sepolia.json`.
- **Live site**: https://reef.gudman.xyz (+ `/slides.html`).
- **Mainnet**: not deployed — mainnet-ready via `script/DeployMainnet.s.sol` (real Ondo USDY). Unaudited; see `SECURITY.md` before any real TVL.

See [ROADMAP.md](ROADMAP.md) for the phased plan.

## Stack

- Solidity 0.8.24, Foundry 1.7.1, `evm_version = paris`
- Python (web3.py) reference agents + keeper / receipt loop (`agents/`)
- Python + Z.ai GLM (`glm-4.7-flash`) for the reference Sovereign agents (deterministic-rule fallback without keys)
- Single-file static **viem** dashboard (`ui/index.html`, no build step) at `reef.gudman.xyz`
- Deploy: Mantle Sepolia (full system) + Mantle Mainnet (small-amount demo instance)

## Build & test

```bash
cp .env.example .env   # fill in PRIVATE_KEY + API keys
forge build
forge test
```

## Build on Reef

Reef is infrastructure other Mantle protocols can call — gate any agent action behind the
on-chain policy, or read an agent's trust:

- **Solidity** — inherit `ReefGuarded` (`src/ReefGuarded.sol`) and add the `onlyCleared` modifier; the call reverts with ReefGuard's exact policy reason if the agent isn't cleared.
- **JS / TS** — `@reef/sdk` (`sdk/`), zero-dependency: `canExecute()` + the Agent Passport API (`/api/agent/<id>.json`).

See [INTEGRATION.md](INTEGRATION.md). Live reference: `MockProtocol` (Mantlescan-verified) gated a real agent action on-chain.

## Contact

nraheemst@gmail.com
