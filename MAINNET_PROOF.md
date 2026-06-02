# Mantle Mainnet Substrate Proof

Reef's RWA substrate is **real**, verified against Mantle **mainnet** (chain 5000) —
without holding any mainnet TVL. This is "real substrate verification, explicitly not
TVL": the contracts are unaudited, so nothing custodies mainnet funds until an audit
(see `SECURITY.md`). The deployer holds **0 MNT / 0 USDY on mainnet** — by design, no
funds are at risk.

## 1. Live fork test against real Ondo USDY (in CI)

`test/UsdyAdapter.fork.t.sol` runs in CI against a fork of live Mantle mainnet:

- `test_fork_metadata_matchesOndo` — asserts the token at `0x5bE26527e817998A7206475496fDE1E68957c5A6` is Ondo "Ondo U.S. Dollar Yield".
- `test_fork_endToEnd_deposit_deploy_recall_withdraw` — a full vault lifecycle (deposit → deployToStrategy → recall → withdraw) against the **real USDY token contract** through `UsdyAdapter`, routed via `SafeTransferLib`.

Both pass in every CI run (`forge test`, 2 fork tests). This is the strongest substrate
proof: the adapter is exercised end-to-end against the actual mainnet asset.

## 2. Mainnet token addresses — on-chain-verified (chain 5000)

Read directly from Mantle mainnet (`cast call ... --rpc-url <mantle>`); symbol + decimals confirmed:

| Asset | Address | symbol / decimals |
|---|---|---|
| Ondo USDY | `0x5bE26527e817998A7206475496fDE1E68957c5A6` | USDY / 18 |
| Mantle mETH | `0xcDA86A272531e8640cD7F1a92c01839911B90bb0` | (bridged LST) |
| Ignition FBTC | `0xC96dE26018A54D51c097160568752c4E3BD6C364` | FBTC / 8 |
| Ethena USDe | `0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34` | USDe / 18 |
| Securitize MI4 | `0x671642ac281c760e34251d51bc9eef27026f3b7a` | MI4 / 6 |

Each has a shipped, unit-tested adapter (`UsdyAdapter` / `MethAdapter` / `FbtcAdapter` /
`UsdeAdapter` / `Mi4Adapter`). Addresses are pinned in `deployments/mantle-sepolia.json`
under `mainnetReferences`.

## 3. Mainnet-ready deploy

`script/DeployMainnet.s.sol` deploys the full system wired to **real Ondo USDY** on
chain 5000 (`deployments/mantle-mainnet.json` pins the addresses). It is **not** broadcast:
mainnet deployment is gated on a third-party audit and a funded key. The demo runs entirely
on Mantle Sepolia (chain 5003) with a mintable MockERC20 — no real value at risk.
