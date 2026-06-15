# Reef

> **Verifiable AI yield agents on Mantle — the trust, risk, and capital-allocation layer you can check on-chain.**

[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Tests](https://img.shields.io/badge/forge%20test-250%20passing-brightgreen.svg)](#getting-started)
[![Network](https://img.shields.io/badge/Mantle-Sepolia%20%2B%20Mainnet-000000.svg)](https://reef.gudman.xyz/transparency)
[![Hackathon](https://img.shields.io/badge/Mantle%20Turing%20Test%202026-AI%20%C3%97%20RWA-3D7FFF.svg)](https://dorahacks.io/hackathon/mantleturingtesthackathon2026)

**[Live site](https://reef.gudman.xyz)** · **[On-chain proof](https://reef.gudman.xyz/transparency)** · [SDK](sdk/) · [Integration guide](INTEGRATION.md) · [Security](SECURITY.md) · [Roadmap](ROADMAP.md)

![Reef — verifiable AI yield agents on Mantle](docs/landing.png)

---

## Overview

Reef answers one question: **which autonomous agents can Mantle users trust with capital?**

Software agents can now hold and move money on their own — but there is no tamper-proof way to tell a good one from a reckless one. Reef is a **credit-rating layer for AI money-managers**: every agent has a portable ERC-8004 identity, a sovereign vault that deploys into RWA/LSD strategies (USDY, mETH, FusionX), source-labelled decision records, and strict-sequence EIP-712 receipts for liveness and reputation. Reputation is earned from **realized**, donation-proof performance. That trust is exposed as a public on-chain primitive (`TrustOracle`), enforced as policy (`ReefGuard`), and used to route capital under risk mandates (`Allocator`, and the reputation-weighted `AgentIndex` ERC-20 token).

Built for the **Mantle Turing Test Hackathon 2026 — AI × RWA track**.

## Highlights

- **Composable trust** — `TrustOracle.scoreOf(agentId)` returns a 0–100 Trust Score (reputation 40% / receipt freshness 20% / drawdown 20% / bond 20%) in one on-chain call any Mantle protocol can read. The dashboard renders this exact on-chain number (verifiable parity ≈ 0.1%).
- **Policy + capital gating** — `ReefGuard.canExecute(agentId, asset, sizeBps)` is a pure-view policy gate (registration, reputation, bond, disputes, asset allowlist, size). `Allocator` routes capital across agents trust-weighted, gated by named risk **mandates** (qualification bar + per-agent concentration cap).
- **Real, autonomous AI** — reference agents read live **Allora** predictions, **Nansen** smart-money flow, and **CoinGecko** momentum, decide via **Z.ai GLM** (`glm-4.7-flash`) or a deterministic fallback, and execute **real swaps on FusionX V2**. Decision source, model, rationale, and swap tx hashes are published at `/api/executions.json`; rationale-bound receipts are summarized at `/api/proofs.json`.
- **Automated risk management** — a transparent exposure-band policy maps live ETH momentum to a target exposure and executes a **real on-chain** de-risk/re-risk on a DEX-backed vault (proven: 60% → 20% → 80%, each move a verifiable Mantlescan tx).
- **The Financial Turing Test** — strategies, Allora, and a passive **human buy-and-hold baseline** are scored on one basis and ranked by **risk-adjusted return (Sharpe)** — the hackathon's question made measurable.
- **Portable ERC-8004 reputation** — every agent is registered in Mantle's **official** ERC-8004 registries (canonical `0x8004…` singletons), with its Trust Score published to the official Reputation Registry.
- **Real RWA yield on mainnet** — a live Mantle-mainnet vault custodies real **mETH**; a rate-aware adapter marks it to ETH so the vault's NAV reflects genuine staking yield.

## How it works

```
                          ERC-8004 identity (official Mantle registry)
                                        │
              EIP-712 signed receipts → reputation (realized-PnL, high-water)
                                        │
        ┌───────────────────────────────┼───────────────────────────────┐
        ▼                               ▼                               ▼
   AgentVault[]                    TrustOracle                     SignalMarket
   sovereign per agent        scoreOf / report (0–100)          A2A signal payments
        │                           │      │                    (no reputation farmed)
        │ deploys into              │      │ canExecute
        ▼                           │      ▼
  StrategyAdapter              (read by)  ReefGuard ── policy gate any protocol calls
  Usdy / mETH / FusionX             │
        │                           ▼
        ▼                       Allocator ── trust-weighted, mandate-gated capital
   RWA / LSD substrate          AgentIndex (rINDEX ERC-20) ── one-token exposure to the field
   (USDY, mETH on Mantle)
```

## Verify it yourself

Reef commits each agent's decision on-chain as `evidenceHash = keccak256(verbatim rationale)`. You don't have to trust our dashboard — recompute it. This read-only check (no keys, no clone state) pulls the published rationales from `/api/proofs.json`, recomputes the hash, and matches it against each vault's on-chain `AgentVault.lastReceiptEvidenceHash`:

```bash
python -m agents.scripts.verify_proof
```

```
agent 1: OK - keccak(rationale)==evidence==on-chain 0xe826d948…745e8d80
...
5 matched proof(s) verified, 0 liveness-only, 0 failed
REEF_PROOF_VALID
```

Three independent checks per agent: the recomputed `keccak256(rationale)` equals the published `evidenceHash`, which equals the on-chain `lastReceiptEvidenceHash`. The same proof renders in the browser on the [proof page](https://reef.gudman.xyz/transparency).

## The trust & risk layer

| Contract | Role |
|---|---|
| `TrustOracle` / `TrustOracleConsumer` | Public 0–100 Trust Score (`scoreOf`/`report`) + a reference trust-gated/sized credit consumer |
| `ReefGuard` / `ReefGuarded` | On-chain policy gate (`canExecute`) + an inheritable base with an `onlyCleared` modifier |
| `Allocator` | Trust-weighted capital allocation under named risk mandates (bar + concentration cap; permissioned-LP mode) |
| `ReputationBond` | Stake-backed bonds; challenge → dispute → slash, with a two-step unbonding cooldown |
| `AgentIdentity` / `AgentIndex` | ERC-8004 identity + reputation; reputation-weighted index token (rINDEX) |
| `AgentVault` / `AdapterRegistry` | Sovereign per-agent vault (realized-PnL reputation) + governor-vetted strategy adapter allowlist |
| `Seasons` / `SignalMarket` | On-chain Human-vs-AI seasons + agent-to-agent signal marketplace |
| Adapters | `Usdy` · `Meth` · `MethRate` · `FusionX` · `Fbtc` · `Usde` · `Mi4` · `MockYield` |

## Live deployments

Everything is on-chain and verifiable — the source of truth is [`deployments/`](deployments/), and every contract is Mantlescan-verified.

![On-chain proof — every contract verified](docs/transparency.png)

**Mantle Sepolia (chain 5003)** — full system seeded: 5 agent vaults, the reputation-weighted index, bond gate, open season, `TrustOracle`, `ReefGuard`, both `Allocator`s, and the A2A market. VPS crons run the live agents (source-labelled decisions, real swaps, rationale-bound/cadence receipts) and the read-only snapshots behind the dashboard. All addresses in [`deployments/mantle-sepolia.json`](deployments/mantle-sepolia.json).

**Mantle Mainnet (chain 5000) — real mETH RWA vault.** A vault custodying real **mETH** (Mantle's liquid-staked ETH). Because mETH is non-rebasing (yield accrues in the mETH→ETH rate maintained on L1), `MethRateAdapter` marks the held mETH to ETH via an on-chain `MethRate` store, so the vault's `nav()` reflects **real staking yield**. All 6 contracts Mantlescan-verified; addresses in [`deployments/mantle-mainnet.json`](deployments/mantle-mainnet.json):

| Contract | Address |
|---|---|
| AgentVault (mETH) | [`0x76f129…cFA5`](https://mantlescan.xyz/address/0x76f129D56a4BE538f7E3bd44DAC70b23BcDFcFA5) |
| MethRateAdapter | [`0xb7Ceedf6…a90A`](https://mantlescan.xyz/address/0xb7Ceedf6BDC4Cf8bdBE8610EAe1D1f962E35a90A) |
| MethRate | [`0xf765d02A…6b4E`](https://mantlescan.xyz/address/0xf765d02A7F04bFDB8f72d97D5584d80475dF6b4E) |

> The mainnet position is **demo scale** and the code is **unaudited** — see [`SECURITY.md`](SECURITY.md) before any real TVL.

## Tech stack

- **Contracts** — Solidity 0.8.24, Foundry 1.7.1 (`evm_version = paris`); unit + fuzz/invariant suites + live mainnet-fork tests. **250 tests passing** (one L1-fork test is opt-in via `ETHEREUM_RPC`, skipped by default).
- **Agents** — Python (web3.py) reference agents, keeper, receipt loop, and read-only snapshots in `agents/`; decisions via Z.ai GLM with a deterministic fallback.
- **Frontend** — static, no build step (`ui/`): `index.html` (landing), `app.html` (dashboard), `transparency.html` (on-chain proof), `agent.html` (agent passport), served at [reef.gudman.xyz](https://reef.gudman.xyz).
- **SDK** — `@reef/sdk` (`sdk/`), a zero-dependency JS/TS client.

## Getting started

```bash
git clone https://github.com/Ridwannurudeen/reef.git
cd reef
cp .env.example .env     # fill in PRIVATE_KEY + API keys (all optional for build/test)
forge build
forge test                # 250 passing, 1 skipped
```

The static site needs no build — open `ui/index.html`, or visit [reef.gudman.xyz](https://reef.gudman.xyz).

## Build on Reef

Reef is infrastructure other Mantle protocols call — read an agent's trust, or gate an action behind on-chain policy. See [`INTEGRATION.md`](INTEGRATION.md).

**Solidity** — read the score, or gate with one modifier:

```solidity
uint256 score = ITrustOracle(oracle).scoreOf(agentId);   // 1e18 == 100/100
// or inherit ReefGuarded and gate an entrypoint:
function act(uint256 id, address asset, uint256 sizeBps)
    external onlyCleared(id, asset, sizeBps) { /* reverts with the policy reason if not cleared */ }
```

**JS / TS** — `@reef/sdk`, zero dependencies:

```js
import { ReefClient } from "@reef/sdk";
const reef = new ReefClient({ rpcUrl, oracleAddress, guardAddress, apiBase });
await reef.trustScoreOf(5);                 // 99.9
await reef.report(5, asset, 1000);          // { score, rating, guardCleared, guardReason }
```

Live reference integrations (Mantlescan-verified): `MockProtocol` (ReefGuard gate) and `TrustOracleConsumer` (trust-weighted credit).

## Project structure

```
src/         Solidity contracts (core, trust/risk layer, adapters, utils)
test/        Foundry tests (unit, fuzz/invariant, mainnet-fork)
script/      Deploy scripts (Sepolia + mainnet)
agents/      Python reference agents, keeper, receipt loop, snapshots
sdk/         @reef/sdk — zero-dependency JS/TS client
ui/          Static multi-page site (landing / app / transparency / passport)
deployments/ Verified on-chain addresses (sepolia + mainnet)
docs/        Screenshots and documentation assets
```

## Security

Reef is a working prototype that demonstrates the idea end-to-end and live — **not** production-ready. We ran an adversarial, multi-agent security pass on our own contracts and would rather state the boundaries than oversell. See [`SECURITY.md`](SECURITY.md) for the full findings ledger (#1–#28) and [`AI_USAGE.md`](AI_USAGE.md) for how the AI components work.

**Fixed and live:**
- **Reputation is realized-PnL / donation-proof.** The two ways an agent could fake its own reputation — a self-donation (#15) and a flash-loaned price mark (#13) — are closed: reputation now credits only *realized* performance (`reputableNav`), and the displayed Trust Score is the authoritative **on-chain** oracle value.
- **Reputation-writer binding (#21, Critical).** An agent can no longer repoint its reputation source to its own wallet to mint an arbitrary score — proven on-chain (the call reverts `source already set`).

**Open and disclosed (honest boundaries):**
- **Unaudited, and deployed contracts are immutable.** A third-party audit is the prerequisite for any real TVL.
- **Some gaming surface remains.** Receipt *freshness* is fakeable (inherent to a cheap heartbeat) and the reputation component is cohort-relative. Two subtle accounting edge cases (#22 withdraw-ratchet, #28 spot-mark share pricing) are **not exploitable in the live setup** (no DEX-marked strategy is deployed) and are audit-deferred with written remediation specs.
- **The real-money piece is a tiny proof.** The mainnet mETH vault holds ~$1–2 and is **deposit-paused** (a known mark-vs-realizable accounting flaw, #16). It proves real-RWA custody works; it is not an economically useful vault.
- **Centralized trust points.** The rate keeper, dispute arbiter, and most governance are single EOAs (rotatable to a multisig at deploy; a 2-of-3 Safe is committed pre-mainnet). The live system runs on one server with ~10-min snapshot freshness.
- **The live AI is intermittent.** On a free LLM tier with rate limits, agents fall back to a deterministic rule when the model/signals are unavailable — recorded honestly per decision.
- **No economic model or cross-chain reputation yet.** No fees/token incentives; reputation is portable on Mantle but not across chains.

## Roadmap

See [`ROADMAP.md`](ROADMAP.md). Near-term: third-party audit + the realized-PnL accumulator and manipulation-resistant pricing (the #22/#28 remediations), 2-of-3 Safe governance, and a richer end-user surface on top of the index.

## License

[MIT](LICENSE) © 2026 Ridwan Nurudeen. Per-file SPDX headers throughout `src/`.

## Contact

nraheemst@gmail.com
