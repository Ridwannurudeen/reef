# Reef — Security Review

**Scope:** all contracts in `src/` (AgentIdentity, AgentVault, AgentIndex, SignalMarket, ReputationBond, adapters).
**Type:** internal review (not a third-party audit). Reef is hackathon/testnet code; the deployed Sepolia instances are demo-only and **must not hold real mainnet TVL until the must-fix items below are resolved and an external audit is completed.**

## Findings

| # | Severity | Issue | Status |
|---|----------|-------|--------|
| 1 | Critical | `AgentIdentity.giveFeedback` had no access control — anyone could mint reputation | **✅ Fixed** (vault-only gate) |
| 2 | Critical | First-depositor / donation share-inflation in `AgentVault` + `AgentIndex` | **✅ Fixed** (virtual offset) |
| 3 | High | `AgentIndex.rebalance` trusts operator-controlled vault NAV; no protocol adapter allowlist | **✅ Fixed** (AdapterRegistry) |
| 4 | High | `AgentVault.publishReceipt` credited reputation from an unverified operator `navDelta` | **✅ Fixed** (NAV-derived) |
| 5 | High | No reentrancy guards; `AgentVault.withdraw` called adapter before updating shares | **✅ Fixed** |
| 6 | Medium | `ReputationBond` concurrent-dispute / commingled-funds accounting | **✅ Fixed** (one active dispute/agent) |
| 7 | Medium | No `SafeERC20`; fragile `approve` for non-standard tokens | **✅ Fixed** (SafeTransferLib) |
| 8 | Medium | `SignalMarket` free self-dealing reputation + provider-call reentrancy | **✅ Fixed** |
| 9 | Low | `AgentVault.nav()` returns 1e18 ignoring stranded assets | Open (cosmetic for demo) |
| 10 | Low | `ReputationBond` single immutable arbiter; no challenger≠agent check | **✅ Partly fixed** (self-challenge rejected; multisig arbiter = deploy choice) |
| 11 | Med→Low | `AgentVault.withdraw` paid the spot mark, not the strategy's realized amount | **✅ Fixed** (pays `recall` return) |
| 12 | Medium | `FusionXAdapter.recall` swapped with `minOut=0` (sandwichable forced sale) | **✅ Fixed** (slippage-bounded) |
| 13 | Medium | `FusionXAdapter.totalUnderlying` spot router quote is flash-loan inflatable → fake NAV/reputation high-water | Open (audit item; adapter is mainnet-only, unlisted) |

## Fixed in this pass

- **#1 Reputation access control (vault-only).** `giveFeedback` is now gated to `reputationSource[agentId]`, which the agent's own wallet designates via `setReputationSource` (default-closed — no source set means no one can write). The intended source is the agent's `AgentVault`. `SignalMarket` no longer credits reputation, which also structurally kills the free self-dealing reputation farm. Residual: an operator's *own* authorized vault can still over-report via `publishReceipt` — closed by **#4** below.
- **#5 Reentrancy + CEI.** Added a minimal `ReentrancyGuard` (`src/utils/ReentrancyGuard.sol`) and applied `nonReentrant` to `AgentVault.{deposit,withdraw,deployToStrategy,recallFromStrategy}`, `AgentIndex.{deposit,withdraw,rebalance}`, and `SignalMarket.purchaseSignal`. Reordered `AgentVault.withdraw` to burn shares **before** the external adapter `recall` (checks-effects-interactions).
- **#8 SignalMarket.** `createListing` now requires `priceWei > 0`; `purchaseSignal` rejects `providerAgentId == consumerAgentId` (blocks zero-cost self-dealing reputation farming) and is `nonReentrant`. (Full mitigation also depends on #1.)
- **#4 NAV-derived reputation.** `publishReceipt` credits the vault's real on-chain per-share NAV delta (`nav()` change since the last receipt); the operator's claimed `navDelta` is ignored. Verified: a claimed `1e24` credits only the real `5e17`.
- **#3 Protocol adapter allowlist.** New `src/AdapterRegistry.sol` (governor-controlled). `AgentVault.approveStrategy` now requires the adapter to be registry-approved, so an operator cannot point a vault at an adapter that lies about `totalUnderlying()` to inflate NAV (hence reputation and index weight). This is a second key on top of the operator's own approval. **Allowlisting is by adapter ADDRESS, not codehash** as originally framed: Solidity embeds immutable variables into runtime bytecode, so instances of the same adapter type have distinct `EXTCODEHASH`es — a codehash allowlist would reject legitimate instances. The governor reviews each deployed instance; the testnet-only `MockYieldAdapter` (mints freely) must never be approved on a registry that gates real TVL.
- **#2 First-deposit / donation inflation.** `deposit`/`withdraw` in `AgentVault` and `AgentIndex` now use a `+1` virtual shares/assets offset. This removes the empty-vault 1-wei→1-share edge and makes any price-inflating donation a net loss to the attacker rather than a theft from the next depositor. First real deposit still mints 1:1.
- **#6/#10 ReputationBond.** `openDispute` now rejects the agent's own operator (no self-slash farming/griefing) and enforces **one active dispute per agent**, so a depleting bond can never owe more upheld slashes than it holds (deterministic, order-independent payouts). The single-arbiter centralization (#10) is now addressed in code: the arbiter is rotatable via a 2-step `transferArbiter`/`acceptArbiter` handoff, so it can be moved to a multisig/timelock after deploy.
- **#7 SafeERC20.** New minimal `src/utils/SafeTransferLib.sol` (treats "call succeeded and returned empty OR true" as success). Every external asset `transfer`/`transferFrom`/`approve` in `AgentVault`, `AgentIndex`, `ReputationBond`, and the adapters routes through it, so Reef supports USDT-style tokens that return no bool (proven by `test/mocks/NoReturnERC20.sol`).

## Fixed in the adapter-review pass

- **#11 Realized-vs-marked withdrawal.** `AgentVault.withdraw` priced the payout off `totalAssets()` (which includes a strategy's *spot mark*) but then ignored `recall`'s return value and transferred the full marked amount. A mark-to-market adapter (e.g. a DEX position) can realize slightly less than its mark when it actually sells, and the `IStrategyAdapter` contract explicitly lets `recall` return less than asked (a drained/slashed adapter, or rounding on a real AMM curve). Withdraw now pays `idle + recalled` — the amount the strategy actually delivered — so it can never overdraw the vault (reverting the last withdrawer) or pay one user out of another's principal. Shares are burned before the recall, so the withdrawer bears their own realization slippage and remaining holders stay whole. Regression-tested with an adapter that under-delivers (`test_withdraw_paysRealizedNotMarked_whenRecallUnderdelivers`). Severity is Med→Low in practice: because `totalUnderlying` quotes via `getAmountsOut` (fee included), a full drain realizes the mark exactly at realistic sizes, so the gap is a sub-wei rounding corner — but the fix removes the edge entirely.
- **#12 Sandwichable forced sale.** `FusionXAdapter.recall` swapped with `amountOutMin = 0`, so a forced withdrawal sale could be sandwiched down to an arbitrary price. It now bounds the sale with the same `maxSlippageBps` tolerance as `deploy`.

## Safety primitives (added in the Phase 4 decentralization pass)

- **Circuit breaker** — `src/utils/Pausable.sol`. A guardian (the operator for an `AgentVault`, the governor for `AgentIndex`) can pause the risk-taking entry points (`deposit`, `rebalance`, `deployToStrategy`). **Withdrawals are deliberately never gated**, so a pause halts new exposure without ever trapping user funds. The guardian is rotatable.
- **withdrawPool reserve** — `AgentIndex.reserveBps` (governor-set). `rebalance` allocates only `total − reserve` to vaults, keeping an idle liquidity buffer in the index so redemptions are serviceable without recalling from vaults.

## Remaining

- **#9** (Low, cosmetic) — `nav()` returns 1e18 for an empty vault. Left as-is for the demo.
- **#13** (Medium, open) — `FusionXAdapter.totalUnderlying()` marks the position with a single-block `getAmountsOut` spot quote. A flash-loan price spike in the same block as a (operator-signed, anyone-relayable) `publishReceipt` could ratchet the sticky `highWaterNav` up at a manipulated mark, inflating ERC-8004 reputation / index weight without real PnL. Not a direct fund-theft from the vault, and the adapter is **mainnet-only and not listed on any live registry**, so it cannot be triggered on the current testnet instance. Proper mitigation (a TWAP mark, or accruing reputation off realized PnL rather than mark-to-market) is an architectural change deferred to the pre-mainnet audit — flagged here rather than patched with a rushed half-measure.
- **Third-party audit** — the one true prerequisite before any mainnet TVL; cannot be self-performed.
- **ERC-8004 cross-chain reputation** — deferred: needs a cross-chain messaging layer + a second chain, not buildable/verifiable on a single testnet (see `ROADMAP.md`).

## Testnet posture

The Sepolia deployment uses a freely-mintable `MockERC20` as the index asset — no real value is at risk. As of 2026-06-01 the core set (AgentIdentity, AgentIndex/rINDEX, AdapterRegistry, 5 vaults) was **redeployed with the current post-Phase-3/4 code** (all fixes above + the circuit breaker / withdrawPool / rotatable arbiter) and re-verified on Mantlescan — see `deployments/mantle-sepolia.json`. It remains **unaudited** hackathon code; a third-party audit is required before any mainnet TVL. `ReputationBond`, `Seasons` and `MockYieldAdapter` are source-complete and unit-tested but not wired into this core instance.
