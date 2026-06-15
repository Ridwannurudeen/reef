# Reef — DoraHacks Submission

**Mantle Turing Test Hackathon 2026 · Primary track: AI & RWA**
Live: https://reef.gudman.xyz · On-chain proof: https://reef.gudman.xyz/transparency

---

## One-liner

**Reef is the trust, risk, and capital-allocation layer for autonomous AI agents on Mantle.** It answers one question for anyone deploying capital: **which autonomous agents can you actually trust with it?**

## The problem

Autonomous AI agents are about to manage on-chain capital, but there is no shared, verifiable way to know which ones to trust. Reputation lives in screenshots and Discord; track records are unauditable; an agent that quietly took a 40% drawdown looks identical to one that compounded steadily. On Mantle — where real RWA and LSD yield (USDY, mETH) make agent-managed capital genuinely attractive — that trust gap is the thing standing between "interesting demo" and "capital that an agent can responsibly route." Reef makes agent trust a **public on-chain primitive**: a portable identity, a NAV-derived track record nobody can fake, a 0–100 trust score any protocol can read in one call, and a policy gate that lets capital flow only to agents that clear an on-chain bar.

---

## What it is / architecture

Every agent in Reef has a portable **ERC-8004 identity**, a **sovereign vault**, and a **verifiable on-chain track record**. That record is distilled into trust, enforced as policy, and used to route capital. The pieces:

- **ERC-8004 identity (official Mantle registries).** Every Reef agent is registered in Mantle's canonical ERC-8004 registries (the `0x8004…` vanity-CREATE2 singletons). Mainnet canonical registries are `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` (Identity) / `0x8004BAa17C55a88189AE136b182e5fdA19dE9b63` (Reputation); Reef's live testnet agents (#197–#201) are registered in the corresponding Sepolia singletons (`0x8004A818…BD9e` / `0x8004B663…8713`), whose proxies point at the same source-verified implementations as mainnet. Reputation is **portable**: any Mantle protocol can read it from the canonical registry without touching a Reef contract.

- **Sovereign AgentVaults.** One vault per agent (`AgentVault`), each deploying into RWA/LSD strategies through a governor-vetted adapter allowlist (`AdapterRegistry`). The agent's operator controls its own vault; nobody can point it at an unvetted adapter.

- **NAV-derived reputation above a high-water mark.** Reputation is credited only when the vault's per-share NAV makes a *new high* — and only off **donation-proof, realized PnL**. `reputableNav()` counts internally-accounted idle plus a strategy valued at `deployedCostBasis`, so a bare token donation or a flash-loan-inflated spot mark credits **zero** reputation; only a `recall` that returns more than cost lifts the high-water and mints reputation. (Security findings #13/#15, fixed at source and live on the leaderboard.)

- **EIP-712 signed receipts.** Each vault publishes strict-sequence EIP-712 receipts on-chain (`publishReceipt`) for liveness and NAV-derived reputation. When the receipt loop has a recent decision rationale for that agent, the receipt is rationale-bound and `proofs.json` exposes the exact reasoning/evidenceHash pair.

- **TrustOracle (0–100, on-chain view).** `TrustOracle.scoreOf(agentId)` returns a 0–100 Trust Score in a single pure-view call any Mantle protocol can read — composed of reputation 40% / receipt-freshness 20% / drawdown 20% / bond 20%. `report(agentId, asset, sizeBps)` folds in ReefGuard's live verdict. The drawdown leg reads the donation-proof `reputableNav()`. The on-chain `scoreOf` reproduces the dashboard number (verifiable parity ≈0.1%).

- **ReefGuard (policy / eligibility gate).** `ReefGuard.canExecute(agentId, asset, sizeBps) → (allowed, reason)` is a pure-view gate checking **registration, ERC-8004 reputation, bond, open disputes, an asset allowlist, and action size**. Any protocol can query it before letting an agent act, or inherit `ReefGuarded` and gate an entrypoint with the `onlyCleared` modifier (reverts with the policy reason). Live policy on the deployed gate: min reputation 0.5e18, min bond 10e18, max size 5000 bps.

- **Allocator (mandate-gated, trust-weighted capital).** LPs deposit one asset; `rebalance()` allocates across vaults weighted by **on-chain** Trust Score, but only to agents that clear the active **mandate** (a qualification bar + per-agent concentration cap). Live mandates: Open / Balanced (60, 50% cap) / Conservative (70, 35% cap, active) / Aggressive. A **permissioned** Allocator variant adds an on-chain depositor allowlist for compliance-sensitive flows.

- **AgentIndex / rINDEX (ERC-20).** A reputation-weighted index token (`rINDEX`) giving one-token exposure to the whole field of agents; full ERC-20 with a live on-chain share transfer demonstrated.

- **ReputationBond.** Stake-backed bonds with a `post → challenge → arbiter-resolve → slash/forfeit/refund` lifecycle, wired into the index bond-gate. Self-challenge rejected, one active dispute per agent, two-step unbond cooldown.

- **Seasons (Human-vs-AI).** `Seasons.sol` runs time-boxed on-chain seasons (enroll on Human/AI side, snapshot at entry, freeze at finalize). Season 0 is open; all 5 agents enrolled.

- **SignalMarket (A2A).** Provider agents list priced signals; consumers buy them; per-provider and global sales/revenue tracked on-chain. Purchases **do not** credit ERC-8004 reputation — so the agent-to-agent economy cannot farm reputation.

---

## The AI — real decisions in the real workflow

Reef's agents are **not a cosmetic chatbot bolted onto a dashboard**. The AI sits in the live capital workflow:

1. **Grounded inputs.** Each agent reads live market signals — **Allora** ETH predictions, **Nansen** smart-money flow, and **CoinGecko** price/24h momentum — plus the vault's on-chain NAV state.
2. **Real LLM decision.** Those inputs go to **Z.ai GLM (`glm-4.7-flash`)**, which returns an allocation action (`increase`/`hold`/`decrease`) and a plain-English rationale grounded in the data (e.g. at a drawdown with ETH down ~2.9% it chose `decrease`, citing momentum). A VPS cron runs one rotating agent per cycle under the free-tier rate limit; if the model is unavailable it falls back to a deterministic rule, recorded honestly as `source:"fallback"`.
3. **Verifiable AI on-chain.** Decisions are source-labelled in `/api/executions.json`; rationale-bound receipts are summarized in `/api/proofs.json`. For records marked `proofStatus: "matched"`, `keccak(reasoning) == evidenceHash` can be recomputed and matched against the vault's on-chain `lastReceiptEvidenceHash`. Cadence-only receipts are labelled separately.
4. **Real execution.** On an `increase`, the agent executes a **real swap on FusionX V2** (a Mantle-native Uniswap-V2 DEX) on Sepolia; the decision + real swap txHash are served at `/api/executions.json` and verifiable on Mantlescan.

This is the maximal AI×RWA shape for a hackathon prototype: an LLM or explicitly-labelled fallback making the allocation call, matched reasoning records that can be verified against on-chain receipt evidence, and the decision actually moving on-chain through a Mantle-native DEX.

> Honest scope (from `AI_USAGE.md`): live execution swaps currently acquire tokens to the operator wallet (agent-level execution); routing the swap output into the vault NAV via a strategy adapter is a follow-up. The decision → matched proof record → swap loop is real and live when `proofStatus` is `matched`; full vault-routed execution is the next step.

---

## Why this is meaningfully Mantle-native (not a generic deploy)

- **Real mETH, real staking yield (mainnet).** A live Mantle-mainnet vault custodies real **mETH** (Mantle's liquid-staked ETH). Because mETH is non-rebasing — yield accrues in the mETH→ETH rate maintained on L1 Ethereum — `MethRateAdapter` reads that rate from an on-chain `MethRate` store and marks the held mETH to ETH, so the vault's `nav()` reflects **genuine accrued staking yield** (observed `nav() ≈ 1.0747e18` at rate `1.0935e18`). This is Mantle's flagship LSD producing real NAV, not a mock.
- **USDY / mUSD RWA substrate.** The mainnet wiring targets Ondo **USDY** (`0x5bE2…c5A6`) and its rebasing wrapper **mUSD** (`0xab57…7cF3`) — Mantle's native tokenized-treasury yield — through `UsdyAdapter`. `DeployMainnet.s.sol` wires the full system to these real assets and the Ondo redemption oracle.
- **FusionX V2.** Live AI execution and the DEX-NAV demo vault both run through FusionX V2, a Mantle-native DEX (router/factory RPC-verified on-chain both on Sepolia and mainnet; `FusionXAdapter` is mainnet-fork-tested against the live router and USDC/WMNT pool).
- **Official ERC-8004 on Mantle.** Reef builds on Mantle's *official* ERC-8004 registries — the identity/reputation substrate Mantle itself is standardizing on — rather than rolling a private registry. The reputation Reef produces is portable to any Mantle protocol by design.

Reef's value proposition only exists *because* Mantle has both real RWA/LSD yield worth managing and a canonical agent-identity standard to anchor trust to. It is infrastructure for the Mantle agent economy, not a chain-agnostic app that happened to deploy here.

---

## Compliance awareness

Reef treats compliance as **programmable on-chain policy**, not an afterthought. `ReefGuard` is a pure-view **eligibility/policy gate**: every agent action can be required to clear an **asset allowlist** (only governor-approved instruments), a **size cap** (`maxSizeBps`, live at 5000 bps), and **bond / dispute / reputation thresholds** (min bond 10e18, no open disputes, min reputation 0.5e18) before any protocol lets it touch capital. The **permissioned Allocator** adds a real on-chain **depositor allowlist** — only governor-approved (e.g. KYC'd) addresses may deposit, proven on-chain (a non-allowlisted deposit reverts `depositor not allowed`), while withdrawals stay open so funds are never trapped. This maps directly onto RWA reality: **USDY is a KYC'd / accredited-investor instrument**, so a venue routing USDY-backed strategies needs exactly this kind of enforceable, allowlist-gated access control. The AI risk-gating (agents that draw down or breach risk lose trust score and fall below the mandate bar) acts as **compliance-assist** — surfacing risk and de-allocating automatically.

**Honest framing:** this is **policy and eligibility enforcement**, not a full KYC/AML stack. Reef provides the on-chain primitives (allowlists, caps, thresholds, dispute/slash) that a compliant venue composes with off-chain identity verification; it does not itself perform identity verification, sanctions screening, or transaction monitoring.

---

## Deployments

All addresses below are from the repo's `deployments/*.json` and are Mantlescan-verified.

### Mantle Sepolia (chain 5003) — full system, hardened redeploy #2 (2026-06-14), UNAUDITED

| Contract | Address |
|---|---|
| AgentIdentity (ERC-8004) | `0xe6D6320a3647a4b21Abe1654C30E848318D161DD` |
| AgentIndex / rINDEX (ERC-20) | `0xf847D0d2c3E4DBED7cd02eB729e48d0aAEfB8C54` |
| AdapterRegistry | `0xa19323f17e7c28a3E88d407499595A31e0E28bE4` |
| TrustOracle | `0x9C7db1eF649095d5c543aF66538a5E36A04d6598` |
| TrustOracleConsumer (ref. credit) | `0xF4fcd1A79d2D95Ae86257be385d8b5FFCd403830` |
| ReefGuard (policy gate) | `0x108411e3AA1fA2D3643b86A0B52Fd5bE12FDfe3f` |
| MockProtocol (ref. external caller) | `0x44E2324BBd1A645c776c442DCa418b791E93fbb2` |
| Allocator (trust-weighted, mandates) | `0x8F7eAC650F91B87DD927A44F1FB03f5f8f985003` |
| Permissioned Allocator (KYC allowlist) | `0xf9F27122a7acA7d6665922BE380AdC3d57142F0c` |
| ReputationBond | `0xccfF181441a636a63f8b5f9b6697585b54165DAe` |
| Seasons (Human-vs-AI, season 0 open) | `0x52EDb6943bF74328e640bcb9E76734Fe63750697` |
| SignalMarket (A2A) | `0xCf63800B3CC47b149421E6A01b9914c3557884b4` |
| Index asset (MockUSDY) | `0xbc17D7F8f265d069781ed765914ED092989d92e7` |

5 reputation-weighted AgentVaults (weights 526 / 1052 / 1578 / 2631 / 4210 bps), agent 1 vault `0xfEB9E7903CA909cC04aF18e2CcE08211c7ef8a67`. Canonical ERC-8004: registered in the Sepolia Identity singleton `0x8004A818BFB912233c491871b3d84c89A494BD9e` as agents #197–#201, Trust Scores published to the Reputation singleton `0x8004B663056A597Dffe9eCcC1965A193B7388713`.

### Mantle Mainnet (chain 5000) — real mETH RWA vault, demo-scale, deposit-paused, UNAUDITED

| Contract | Address |
|---|---|
| AgentVault (mETH) | `0x76f129D56a4BE538f7E3bd44DAC70b23BcDFcFA5` |
| MethRateAdapter | `0xb7Ceedf6BDC4Cf8bdBE8610EAe1D1f962E35a90A` |
| MethRate (rate store) | `0xf765d02A7F04bFDB8f72d97D5584d80475dF6b4E` |
| AgentIdentity | `0x83c35DFCe04051BcF78f979C9170d2a178C2E23D` |
| AgentIndex | `0x102678bE65416c5F0aDE16666d8135bb766e1AE1` |
| AdapterRegistry | `0x7947c1bB4479a93E5e9F25c52D50b8A35Ef7b9B1` |
| mETH (asset) | `0xcDA86A272531e8640cD7F1a92c01839911B90bb0` |

**Honest status:** this is a **real mETH custody proof** — it holds **~0.000717 mETH (~$1–2)**, with `nav() ≈ 1.0747e18` reflecting real accrued staking yield (initial L1 rate `1.0935e18`). All 6 contracts Mantlescan-verified. It is **deposit-paused** (single depositor = operator), **demo-scale**, and **UNAUDITED**. It proves real-RWA custody works on Mantle mainnet; it is deliberately *not* an economically useful vault (see limitations). Do not unpause or invite external deposits pre-audit.

---

## How to run / demo it yourself

1. **Open the live site** — https://reef.gudman.xyz : landing `/`, dashboard `/app`, on-chain proof `/transparency`, per-agent passport `/agent?id=N`.
2. **Faucet → deposit.** Use the in-UI faucet to mint the demo index asset, then deposit into a vault / the index from the dashboard.
3. **Rebalance (permissionless).** Trigger `rebalance()` from the UI — capital re-allocates across agents by their **on-chain** Trust Score, gated by the active Conservative mandate. Anyone can call it.
4. **Verify it yourself.** On `/transparency`, the Trust Score badge renders the **on-chain `TrustOracle.scoreOf`** (off-chain parity Δ in the tooltip), and the page reads NAV / reputation / receipts straight from chain. Cross-check any address on Mantlescan; for `/api/proofs.json` records marked `matched`, recompute `keccak(reasoning)` against the receipt's `evidenceHash`.
5. **Build on it.** Read trust with `ITrustOracle(oracle).scoreOf(agentId)` (1e18 == 100/100), or gate an entrypoint with `onlyCleared(id, asset, sizeBps)` via `ReefGuarded`; JS/TS via the zero-dependency `@reef/sdk`. Reference integrations `MockProtocol` and `TrustOracleConsumer` are live and verified.

**Build/test:** Solidity 0.8.24, Foundry; `forge build && forge test` — **250 tests passing, 1 skipped** (verified `forge test`), including fuzz/invariant suites and live Mantle-mainnet fork tests (one L1-fork test opt-in via `ETHEREUM_RPC`, skipped by default).

---

## Honest limitations (from `SECURITY.md`)

We would rather state the boundaries than oversell:

- **Unaudited, immutable.** All deployed contracts are unaudited hackathon code and immutable — fixes ship only in future deploys. A third-party audit is the prerequisite for any real TVL. (`SECURITY.md`, internal review + Slither 0.11.5 + multi-agent adversarial pass; findings #1–#28.)
- **Testnet leaderboard uses a mock asset with simulated yield.** The Sepolia index asset is a freely-mintable mock; vault yield is realized on a `MockStrategyAdapter`, not a real market. No real value is at risk there.
- **Trust Score is gameable in the general case.** Computed from on-chain state, but the freshness leg refreshes on a no-op receipt (inherent: it's a liveness signal, not proof of performance), and the reputation leg is cohort-relative by default (a governor-set absolute target exists). The donation/mark-manipulation legs (#13/#15/#19 drawdown) are fixed and live; it is a sound internal ranking, **not yet safe for an external lender to size real credit on**.
- **Human-vs-AI baseline is passive buy-and-hold, not live humans.** The "human" side of the Turing benchmark is a passive buy-and-hold benchmark scored on the same basis (risk-adjusted return / Sharpe), not a fleet of live human traders.
- **Known mainnet-vault accounting flaw — not multi-depositor-safe (#16).** `MethRateAdapter.totalUnderlying()` returns the ETH-marked value while the vault accounts/pays in mETH tokens; when `rate > 1` and capital is deployed, a non-recall-path withdrawer can extract the staking premium, leaving the last withdrawer short. **Mitigated** on the live instance by the single-depositor + deposit-pause; the proper multi-depositor fix (realized-PnL / unit-consistent redesign) is audit-deferred.
- **Centralized trust points.** Governor / arbiter / rate-keeper roles are single EOAs (rotatable; committed to migrate to a 2-of-3 Gnosis Safe pre-mainnet); the L1 rate is read from a single RPC bounded by a 5% per-update step cap; the live system runs on one server with ~10-min snapshot freshness.
- **Live AI is intermittent.** On a free LLM tier, agents fall back to a deterministic rule when the model or signals are unavailable — recorded honestly per decision.

Full findings ledger (#1–#28, shipped vs. audit-deferred) in [`SECURITY.md`](../SECURITY.md); AI components in [`AI_USAGE.md`](../AI_USAGE.md); phased plan in [`ROADMAP.md`](../ROADMAP.md).

---

*Reef · MIT (per-file SPDX) · nraheemst@gmail.com · built for the Mantle Turing Test Hackathon 2026 (AI × RWA).*
