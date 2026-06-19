# Reef v2 Architecture

## Product Wedge

Reef v2 is the non-bypassable risk, authorization, and underwriting layer between an
autonomous financial agent and a wallet.

The core question is:

```text
Should this agent be allowed to execute this exact transaction right now?
```

The answer must be enforceable at the wallet/account layer, not only displayed in a dashboard.

## Core Flow

```text
agent proposes transaction
        |
Reef simulates and evaluates policy
        |
wallet guard / account module allows or blocks execution
        |
receipt binds decision, policy result, tx hash, and outcome
        |
agent credit/risk limits update from verified outcomes
```

## Mandatory v2 Boundaries

- Reef proof is **evidence-envelope integrity** until runtime/model/data attestation exists.
- Reef Trust Score is a prototype risk signal, not a calibrated production credit rating.
- Reef must not custody meaningful third-party capital before external audit, timelocked
  multisig governance, and emergency migration paths.
- Agent strategy performance is not the wedge. Transaction authorization and underwriting is.

## Policy Engine Inputs

The policy engine must receive or reconstruct:

- canonical agent identity tuple
- wallet/account address
- target
- value
- calldata
- operation type
- token/asset
- parsed amount
- current portfolio value
- post-transaction exposure
- slippage/deadline/leverage/counterparty where available
- mandate id and policy template
- current TrustOracle score and components
- active disputes, posted bond, and credit limits

`ReefGuard.canExecuteAction` is the source-level v1.5 step: it derives size from standard
native/ERC-20 calldata and can enforce a TrustOracle threshold. v2 must move this behind a Safe
Guard/module or ERC-4337 validation module so agents cannot bypass the check.

## Evidence Envelope

Each complete receipt should bind:

- canonical agent identity
- code hash
- runtime hash or attestation id
- model/config hash
- prompt/policy hash
- input-data hashes
- source attestations
- decision timestamp
- validity window
- block number
- proposed transaction hash
- policy result
- execution transaction hash
- post-state hash
- outcome window and measured outcome
- durable content-addressed evidence URI

Current source signs a v2 receipt envelope: `keccak256(canonical evidence envelope)`, action
context, policy context, execution context, post-state, outcome context, decision timestamp,
expiry, decision block, and content-addressed evidence URI hash. This still does not prove model
or runtime provenance by itself, but it gives underwriting code a complete object to verify and
score.

## Risk Outputs

Keep a simple UI score, but capital should use explicit limits:

- allowed / blocked
- max notional
- max daily loss
- required bond
- expected loss bps
- tail-loss estimate
- liquidity-adjusted exposure
- bond-to-risk ratio
- history confidence
- probability of policy violation
- reasons

## Labs Surfaces

These are useful evaluation surfaces but should not define the core protocol:

- SignalMarket
- Human-vs-AI Seasons
- ComplianceRegistry
- rINDEX retail-style exposure
- strategy benchmarks
- token incentives

They can return when they directly strengthen transaction safety, agent evaluation, or
underwriter confidence.
