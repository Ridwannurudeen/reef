# Reef

**The trust, risk, and capital-allocation layer for autonomous AI agents on Mantle.**

[Live site](https://reef.gudman.xyz) · [On-chain proof](https://reef.gudman.xyz/transparency) · [Hackathon](https://dorahacks.io/hackathon/mantleturingtesthackathon2026) · [Roadmap](ROADMAP.md) · [Security](SECURITY.md)

Reef answers one question: **which autonomous agents can Mantle users trust with capital?** Every agent has a portable ERC-8004 identity, a sovereign vault that deploys into RWA/LSD strategies (USDY, mETH, FusionX), and a verifiable on-chain track record — every decision is an EIP-712-signed receipt, reputation is NAV-derived above a high-water mark, and weak agents can be challenged and slashed through on-chain bonds. That trust is exposed as a public on-chain primitive (`TrustOracle`), enforced as policy (`ReefGuard`), and used to route capital under risk mandates (`Allocator`, and the reputation-weighted `AgentIndex` ERC-20). Built for the **Mantle Turing Test Hackathon 2026 — AI × RWA track**.

---

## Highlights

- **Composable trust** — `TrustOracle.scoreOf(agentId)` returns a 0–100 Trust Score (reputation 40% / receipt freshness 20% / drawdown 20% / bond 20%) in one on-chain call any Mantle protocol can read. It reproduces the dashboard number exactly (verifiable parity).
- **Policy + capital gating** — `ReefGuard.canExecute(agentId, asset, sizeBps)` is a pure-view policy gate (registration, reputation, bond, disputes, asset allowlist, size). `Allocator` allocates capital across agents trust-weighted, gated by named risk **mandates** (qualification bar + per-agent concentration cap).
- **Real, autonomous AI** — reference agents read live **Allora** predictions, **Nansen** smart-money flow, and **CoinGecko** momentum, decide via **Z.ai GLM** (`glm-4.7-flash`), and execute **real swaps on FusionX V2** — with the LLM's verbatim rationale hash-committed on-chain (deterministic-rule fallback when API keys are absent).
- **The Financial Turing Test** — strategies, Allora, and a passive **human buy-and-hold baseline** are scored on one basis and ranked by **risk-adjusted return (Sharpe)** — the hackathon's question made measurable.
- **Portable ERC-8004 reputation** — every agent is registered in Mantle's **official** ERC-8004 registries (canonical `0x8004…` singletons), and each Trust Score is published to the official Reputation Registry — portable to any Mantle protocol.
- **Real RWA yield on mainnet** — a live Mantle-mainnet vault custodies real **mETH**; a rate-aware adapter marks it to ETH so the vault's NAV reflects genuine staking yield (see below).

## How it works

```
                          ERC-8004 identity (official Mantle registry)
                                        │
              EIP-712 signed receipts → reputation (NAV-derived, high-water)
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

## The trust & risk layer

| Contract | Role |
|---|---|
| `TrustOracle` / `TrustOracleConsumer` | Public 0–100 Trust Score (`scoreOf`/`report`) + a reference trust-gated/sized credit consumer |
| `ReefGuard` / `ReefGuarded` | On-chain policy gate (`canExecute`) + an inheritable base + `onlyCleared` modifier |
| `Allocator` | Trust-weighted capital allocation under named risk mandates (bar + concentration cap; permissioned-LP mode) |
| `ReputationBond` | Stake-backed bonds; challenge → dispute → slash |
| `AgentIdentity` / `AgentIndex` | ERC-8004 identity + reputation; reputation-weighted index token (rINDEX) |
| `AgentVault` / `AdapterRegistry` | Sovereign per-agent vault + governor-vetted strategy adapter allowlist |
| `Seasons` / `SignalMarket` | On-chain Human-vs-AI seasons + agent-to-agent signal marketplace |
| Adapters | `Usdy` · `Meth` · `MethRate` · `FusionX` · `Fbtc` · `Usde` · `Mi4` · `MockYield` |

## Live deployments

**Mantle Sepolia (chain 5003)** — full system seeded: 5 agent vaults, reputation-weighted index, live-growing-NAV adapter, bond gate, open season, `TrustOracle`, `ReefGuard`, `Allocator`, and the A2A market. VPS crons run the live GLM agents (real swaps + signed receipts) and the read-only snapshots behind the dashboard. All addresses in [`deployments/mantle-sepolia.json`](deployments/mantle-sepolia.json); every contract Mantlescan-verified.

**Mantle Mainnet (chain 5000) — real mETH RWA vault.** A vault custodying real **mETH** (Mantle's liquid-staked ETH). Because mETH is non-rebasing (yield accrues in the mETH→ETH rate, maintained on L1), `MethRateAdapter` marks the held mETH to ETH via an on-chain `MethRate` store, so the vault's `nav()` reflects **real staking yield** (observed `nav() ≈ 1.0747`). All 6 contracts Mantlescan-verified; addresses in [`deployments/mantle-mainnet.json`](deployments/mantle-mainnet.json):

- AgentVault (mETH): [`0x76f129D56a4BE538f7E3bd44DAC70b23BcDFcFA5`](https://mantlescan.xyz/address/0x76f129D56a4BE538f7E3bd44DAC70b23BcDFcFA5)
- MethRateAdapter: [`0xb7Ceedf6BDC4Cf8bdBE8610EAe1D1f962E35a90A`](https://mantlescan.xyz/address/0xb7Ceedf6BDC4Cf8bdBE8610EAe1D1f962E35a90A)
- MethRate: [`0xf765d02A7F04bFDB8f72d97D5584d80475dF6b4E`](https://mantlescan.xyz/address/0xf765d02A7F04bFDB8f72d97D5584d80475dF6b4E)

> The mainnet position is **demo scale** and the code is **unaudited** — see [`SECURITY.md`](SECURITY.md) before any real TVL.

## Tech stack

- **Contracts** — Solidity 0.8.24, Foundry 1.7.1 (`evm_version = paris`); fuzz/invariant suites + live mainnet-fork tests. **225 tests passing** (`forge test`; one L1-fork test is opt-in via `ETHEREUM_RPC` and skipped by default).
- **Agents** — Python (web3.py) reference agents, keeper, receipt loop, and read-only snapshots in `agents/`; decisions via Z.ai GLM with deterministic fallback.
- **Frontend** — static, no build step (`ui/`): `index.html` (landing), `app.html` (dashboard), `transparency.html` (on-chain proof), `agent.html` (agent passport), served at [reef.gudman.xyz](https://reef.gudman.xyz).
- **SDK** — `@reef/sdk` (`sdk/`), zero-dependency JS/TS client.

## Build & test

```bash
cp .env.example .env   # fill in PRIVATE_KEY + API keys (all optional for build/test)
forge build
forge test
```

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

## Project layout

```
src/         Solidity contracts (core, trust/risk layer, adapters, utils)
test/        Foundry tests (unit, fuzz/invariant, mainnet-fork)
script/      Deploy scripts (Sepolia + mainnet)
agents/      Python reference agents, keeper, receipt loop, snapshots
sdk/         @reef/sdk — zero-dependency JS/TS client
ui/          Static multi-page site (landing / app / transparency / passport)
deployments/ Verified on-chain addresses (sepolia + mainnet)
```

## Security & scope

Unaudited hackathon code. The Sepolia leaderboard instance uses a demo asset with simulated/accruing yield; the mainnet mETH vault has **real** yield but is **demo scale**. The human baseline in the Turing benchmark is a passive buy-and-hold benchmark, not a live human fleet. See [`SECURITY.md`](SECURITY.md) for open items and [`AI_USAGE.md`](AI_USAGE.md) for how the AI components work.

## Limitations

Reef is a working prototype that demonstrates the idea end-to-end and live. It is **not** production-ready, and we'd rather state the boundaries than oversell:

- **Unaudited, and the deployed contracts are immutable.** Live instances can't be patched — fixes only ship in future deploys. A third-party audit is the prerequisite for any real TVL.
- **The Trust Score is gameable.** It's computed from on-chain state, but an agent can mask its own drawdown (donate to itself), farm the freshness component (no-op receipts), and the reputation component is cohort-relative. It's a sound internal ranking; it is **not** yet safe for an external lender to size real credit on. The fix (score off realized PnL, not a spot mark) is an architectural redesign deferred to audit — see `SECURITY.md` #13/#15/#16/#19.
- **The real-money piece is a tiny proof.** The mainnet mETH vault holds ~$1–2 and, after our security pass, is **deposit-paused** (it has a known mark-vs-realizable accounting flaw that isn't multi-depositor-safe). It proves real-RWA custody works; it is not an economically useful vault.
- **Centralized trust points.** The rate keeper is a single key reading a single L1 source (bounded by a per-update cap); the dispute arbiter and most governance are single EOAs (rotatable to a multisig at deploy, but not yet); the whole live system runs on one server with ~10-min snapshot freshness.
- **The live AI is intermittent.** On a free LLM tier with rate limits, agents fall back to a deterministic rule when the model/signals are unavailable — recorded honestly per decision.
- **No economic model and no cross-chain reputation yet.** No fees/token incentives; reputation is portable on Mantle but not across chains.

See [`SECURITY.md`](SECURITY.md) for the full findings ledger (#1–#20) and which fixes are shipped vs. audit-deferred.

## Contact

nraheemst@gmail.com · MIT (per-file SPDX headers)
