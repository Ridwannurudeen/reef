# Reef — Security Review

**Scope:** all contracts in `src/` (AgentIdentity, AgentVault, AgentIndex, SignalMarket, ReputationBond, adapters).
**Type:** internal review (not a third-party audit). Reef is hackathon/testnet code; the deployed Sepolia instances are demo-only and **must not hold real mainnet TVL until the must-fix items below are resolved and an external audit is completed.**

## Findings

| # | Severity | Issue | Status |
|---|----------|-------|--------|
| 1 | Critical | `AgentIdentity.giveFeedback` had no access control — anyone could mint reputation | **✅ Fixed** (vault-only gate) |
| 2 | Critical | First-depositor / donation share-inflation in `AgentVault` + `AgentIndex` | **Open** (must-fix) |
| 3 | High | `AgentIndex.rebalance` trusts operator-controlled vault NAV; no protocol adapter allowlist | **Open** (must-fix) |
| 4 | High | `AgentVault.publishReceipt` credits reputation from an unverified operator-supplied `navDelta` | **Open** (must-fix) |
| 5 | High | No reentrancy guards; `AgentVault.withdraw` called adapter before updating shares | **✅ Fixed** |
| 6 | Medium | `ReputationBond` concurrent-dispute / commingled-funds accounting | **Open** |
| 7 | Medium | No `SafeERC20`; fragile `approve` for non-standard tokens | **Open** (USDY is standard ERC-20 → low risk for the demo) |
| 8 | Medium | `SignalMarket` free self-dealing reputation + provider-call reentrancy | **✅ Fixed** |
| 9 | Low | `AgentVault.nav()` returns 1e18 ignoring stranded assets | Open (cosmetic for demo) |
| 10 | Low | `ReputationBond` single immutable arbiter; no challenger≠agent check | Open (centralization; document) |

## Fixed in this pass

- **#1 Reputation access control (vault-only).** `giveFeedback` is now gated to `reputationSource[agentId]`, which the agent's own wallet designates via `setReputationSource` (default-closed — no source set means no one can write). The intended source is the agent's `AgentVault`. `SignalMarket` no longer credits reputation, which also structurally kills the free self-dealing reputation farm. Residual: an operator's *own* authorized vault can still over-report via `publishReceipt` — closed by **#4** below.
- **#5 Reentrancy + CEI.** Added a minimal `ReentrancyGuard` (`src/utils/ReentrancyGuard.sol`) and applied `nonReentrant` to `AgentVault.{deposit,withdraw,deployToStrategy,recallFromStrategy}`, `AgentIndex.{deposit,withdraw,rebalance}`, and `SignalMarket.purchaseSignal`. Reordered `AgentVault.withdraw` to burn shares **before** the external adapter `recall` (checks-effects-interactions).
- **#8 SignalMarket.** `createListing` now requires `priceWei > 0`; `purchaseSignal` rejects `providerAgentId == consumerAgentId` (blocks zero-cost self-dealing reputation farming) and is `nonReentrant`. (Full mitigation also depends on #1.)

## Must-fix before mainnet TVL (the reputation-integrity redesign)

Findings **#3, #4** remain interlocking with the (now-fixed) #1 and together gate the core premise (reputation → capital):

- **#1** — ✅ Done (vault-only gate, see above). The chosen model: only the agent's own designated vault may write reputation.
- **#4** — credit reputation from the vault's actual on-chain NAV delta between receipts, not the operator-supplied `navDelta` in `publishReceipt`. This closes the residual from #1 (an authorized vault over-reporting). **Top remaining reputation item.**
- **#3** — move strategy-adapter approval to a protocol/governance allowlist (by codehash), so a malicious operator cannot point a vault at an adapter that lies about `totalUnderlying()`. Ensure `MockYieldAdapter` (testnet-only, mints freely) is never allowlisted.
- **#2** — add dead-shares / virtual-offset to first deposits in both `AgentVault` and `AgentIndex`.
- **#6/#10** — one active dispute per agent (or per-dispute slash escrow); multisig/timelocked arbiter; reject self-challenge.
- **#7** — adopt `SafeERC20` for generic-asset support.

## Testnet posture

The current Sepolia deployment uses a freely-mintable `MockERC20` and the testnet `MockYieldAdapter`. No real value is at risk. These contracts are immutable; the fixes above apply to source and would ship in a fresh, audited deployment before any mainnet TVL.
