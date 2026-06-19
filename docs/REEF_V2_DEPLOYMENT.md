# Reef v2 Audit-Hardening Deployment

This is a post-audit Mantle Sepolia deployment created on 2026-06-19. It is not the public DoraHacks-submitted deployment and should not replace `deployments/mantle-sepolia.json`, the live site, SDK defaults, or VPS cron pointers until a deliberate migration is approved.

## Status

- Network: Mantle Sepolia, chain `5003`
- Purpose: audit-hardening validation for v2 source
- Public demo status: keep using the submitted deployment generation
- Migration status: not started

## v2 Addresses

| Component | Address |
| --- | --- |
| AgentIdentity | `0xc037f358cfc72608f2c731901e28dfb36d1c95f0` |
| AgentIndex | `0xea254562fd35cf20fe79b1840771eb201befdf44` |
| ReputationBond | `0x61d0a2afcb3b26cfb0e8e3aba34d0c3e78a44352` |
| ReefGuard | `0x5a29fecf3c34411c00005ec4f97cb861e3031a4c` |
| ReefSafeGuard | `0xa06eef22897351c2b9767802f91bab86c68c1c82` |
| AdapterRegistry | `0x67c7f63d99997fb938cc6d449e2dab0646263ccd` |
| TrustOracle | `0x3ce34a3af9ba3342327ebf28efda11327377ad52` |
| TrustOracleConsumer | `0x99181199ea8be300d9b7857bf59d3de31528afe9` |

## Seeded Vaults

| Agent | Vault | Seed Adapter |
| --- | --- | --- |
| 1 | `0xaf6173cba5b6f3db923ddf74a4040c4197695ccd` | `0xf09a3f625b08c19a33bcd15877613e658f975240` |
| 2 | `0x686806dad75a630fec6b5d5c4f3fdaa365604365` | `0x878f3db3aeb87025c0024c153eb5ff4595f2963b` |
| 3 | `0x903277e2b63c696c33809b9d2cf6e40f5f0e8573` | `0xb021ea483ecd9a8eb6fa842fc540970f493cdece` |
| 4 | `0xb24e38e3ed20b3f852a234e6bdf92648a39309c3` | `0xc9d3381fdc78c2da9a3940e530ec44b2c5150de5` |
| 5 | `0xa184be1e7a773917f3d6e5864b0c6310737914fb` | `0xa543373aee48c419c63432764d6e3130df28caf7` |

## Verified On Chain

- Deployment broadcast: 107 receipts, all status `1`
- Core code exists at the v2 addresses above
- `AgentIdentity.nextAgentId() == 6`
- `AgentIndex.vaultCount() == 5`
- `TrustOracle.vaultCount() == 5`
- `ReefGuard.trustOracle() == 0x3ce34a3af9ba3342327ebf28efda11327377ad52`
- `ReefGuard.canExecute(1, asset, 100)` returns `true, "ok"`
- `ReefGuard.canExecute(1, asset, 8000)` returns `false, "action size over limit"`
- Trust tiers observed after deployment: agent 1 `T3`, agent 2 `T3`, agent 3 `T2`, agent 4 `T2`, agent 5 `T1`

## Not Done

- The open and permissioned Allocator v2 instances were not deployed.
- Canonical ERC-8004 re-registration/binding was not migrated to the v2 local identities.
- The VPS agent runtime was not switched to v2.
- `deployments/mantle-sepolia.json` was intentionally left on the submitted deployment generation.
- The public site and API were intentionally left on the submitted deployment generation.
