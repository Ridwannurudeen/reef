# @reef/sdk

Zero-dependency client for the Reef TrustOracle, ReefGuard policy gate, and Agent Passport API
on Mantle.

Reef is the risk, evidence, authorization, and capital-allocation layer for autonomous financial
agents on Mantle. This SDK is how a protocol or app integrates it:

- **TrustOracle** - read an agent's on-chain Trust Score and one-call trust verdict.
- **ReefGuard** - gate agent-driven actions behind policy checks.
- **Agent Passport** - read an agent's public profile: trust, verdict, allocation, and decisions.

No build step, no dependencies. The JS client uses global `fetch` and `TextDecoder`
(browser / Node >= 18).

## JS / TS

```js
import { ReefClient } from "@reef/sdk";

const reef = new ReefClient({
  rpcUrl: "https://rpc.sepolia.mantle.xyz",
  guardAddress: "0x108411e3AA1fA2D3643b86A0B52Fd5bE12FDfe3f",
  oracleAddress: "0x9C7db1eF649095d5c543aF66538a5E36A04d6598",
  apiBase: "https://reef.gudman.xyz/api",
});

await reef.trustScoreOf(5); // 99.9

const report = await reef.report(5, "0xbc17...92e7", 1000);
// { score, rating, guardCleared, guardReason }

// Preferred policy gate: ReefGuard derives size from native/ERC-20 action calldata.
const inspected = await reef.canExecuteAction(1, {
  target: "0xbc17...92e7",
  value: 0,
  data: "0xa9059cbb...", // ERC-20 transfer/approve/transferFrom calldata
  asset: "0xbc17...92e7",
  portfolioValue: 1000n * 10n ** 18n,
});
// { allowed, reason, amount, sizeBps }

// Legacy policy gate when your protocol already computed size internally.
const { allowed, reason } = await reef.canExecute(1, "0xbc17...92e7", 1000);
if (!allowed) throw new Error(`agent blocked: ${reason}`);

const passport = await reef.passport(1);
```

## Write-Side Onboarding

The write helpers submit raw transaction requests through an EIP-1193 wallet such as MetaMask.
The SDK never handles private keys.

```js
const reef = new ReefClient({
  provider: window.ethereum,
  account: "0xYourWallet",
  identityAddress: "0xe6D6320a3647a4b21Abe1654C30E848318D161DD",
  indexAddress: "0xf847D0d2c3E4DBED7cd02eB729e48d0aAEfB8C54",
  bondAddress: "0xccfF181441a636a63f8b5f9b6697585b54165DAe",
});

await reef.registerAgent();
await reef.setReputationSource({ agentId: 6, source: "0xAgentVault" });
await reef.approveToken({
  tokenAddress: "0xbc17D7F8f265d069781ed765914ED092989d92e7",
  spender: "0xccfF181441a636a63f8b5f9b6697585b54165DAe",
  amount: 10n * 10n ** 18n,
});
await reef.postBond({ agentId: 6, amount: 10n * 10n ** 18n });
await reef.selfListVault({ vault: "0xAgentVault" });
```

`deployVault({ bytecode, asset, agentId, identityAddress, registryAddress })` builds a
contract-creation transaction from Foundry bytecode. Adapter approval depends on the registry
governor; use `approveAdapter` only when the connected wallet controls the registry being used
by that vault.

## API

| Method | Returns |
|---|---|
| `trustScoreOf(agentId)` | on-chain Trust Score 0-100 - `eth_call` to `TrustOracle.scoreOf` |
| `report(agentId, asset, sizeBps)` | `{ score, rating, guardCleared, guardReason }` - `TrustOracle.report` |
| `canExecuteAction(agentId, action)` | `{ allowed, reason, amount, sizeBps }` - ReefGuard derives size from native/ERC-20 action data |
| `canExecute(agentId, asset, sizeBps)` | `{ allowed, reason }` - raw `eth_call` to legacy `ReefGuard.canExecute` |
| `passport(agentId)` | full passport JSON - `GET /api/agent/<id>.json` |
| `score(agentId)` | the agent's Reef Trust Score, from the passport API |
| `latestReceipt(agentId)` | the agent's latest recorded decision |
| `registerAgent()` | wallet tx hash for `AgentIdentity.register()` |
| `deployVault(opts)` | wallet tx hash for an `AgentVault` contract creation tx |
| `setReputationSource(opts)` | wallet tx hash for `AgentIdentity.setReputationSource` |
| `approveAdapter(opts)` | wallet tx hash for `AdapterRegistry.approveAdapter` |
| `approveStrategy(opts)` | wallet tx hash for `AgentVault.approveStrategy` |
| `approveToken(opts)` | wallet tx hash for ERC-20 `approve` |
| `postBond(opts)` | wallet tx hash for `ReputationBond.postBond` |
| `selfListVault(opts)` | wallet tx hash for `AgentIndex.selfListVault` |
| `publishReceipt(opts)` | wallet tx hash for `AgentVault.publishReceipt` |

`encodeCanExecuteAction`, `decodeCanExecuteAction`, `encodeCanExecute`, `decodeCanExecute`,
`encodeScoreOf`, `encodeReport`, `decodeReport`, `wadToScore`, and the `encode*` write helpers
are exported for advanced use such as multicall, custom relayers, or dry-run transaction builders.

## Solidity

For standard token/native actions, prefer `ReefGuard.canExecuteAction` so the guard derives action
size itself:

```solidity
ReefGuard.Action memory action = ReefGuard.Action({
    target: token,
    value: 0,
    data: abi.encodeWithSelector(IERC20.transfer.selector, recipient, amount),
    asset: token,
    portfolioValue: currentPortfolioValue
});

(bool ok, string memory reason,,) = reefGuard.canExecuteAction(agentId, action);
require(ok, reason);
```

For integrations that already compute size internally, inherit `ReefGuarded`
(`src/ReefGuarded.sol`) and gate entrypoints with one modifier:

```solidity
import {ReefGuarded} from "reef/src/ReefGuarded.sol";

contract MyProtocol is ReefGuarded {
    constructor(address reefGuard) ReefGuarded(reefGuard) {}

    function act(uint256 agentId, address asset, uint256 sizeBps, uint256 amount)
        external
        onlyCleared(agentId, asset, sizeBps)
    {
        // execution logic
    }
}
```

To size capital by trust, read `TrustOracle.scoreOf`:

```solidity
interface ITrustOracle {
    function scoreOf(uint256 agentId) external view returns (uint256);
}

uint256 score = ITrustOracle(oracle).scoreOf(agentId); // 1e18 == 100/100
require(score >= minScore, "trust below threshold");
uint256 limit = baseLimit * score / 1e18;
```

See `MockProtocol` (ReefGuard gate) and `TrustOracleConsumer` (trust-weighted credit) for
reference integrations, and [`INTEGRATION.md`](../INTEGRATION.md) for the full guide.

## Addresses (Mantle Sepolia, chain 5003)

| Contract | Address |
|---|---|
| TrustOracle | `0x9C7db1eF649095d5c543aF66538a5E36A04d6598` |
| ReefGuard | `0x108411e3AA1fA2D3643b86A0B52Fd5bE12FDfe3f` |
| TrustOracleConsumer (example) | `0xF4fcd1A79d2D95Ae86257be385d8b5FFCd403830` |
| MockProtocol (example) | `0x44E2324BBd1A645c776c442DCa418b791E93fbb2` |

Unaudited testnet code. See `SECURITY.md` before any mainnet TVL.
