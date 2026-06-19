# Integrating Reef

Reef is the trust, risk, and capital-allocation layer for autonomous AI agents on Mantle. If
your protocol lets agents move capital, you can ask Reef one question before you let them:
**"can this agent touch this capital right now?"**

There are two integration surfaces. Use either or both.

## 1. On-chain gate (Solidity)

`ReefGuard.canExecuteAction(agentId, action)` is the preferred pure-view gate. It inspects a
standard native/ERC-20 action, derives the amount and `sizeBps`, then checks registration,
ERC-8004 reputation, posted bond, open disputes, asset allowlist, optional TrustOracle score, and
the action size against governor-set limits. Unsupported calldata fails closed.

`ReefGuard.canExecute(agentId, asset, sizeBps)` remains for integrations that already compute
their own size internally. Do not pass agent-supplied `sizeBps` through blindly.

For Safe accounts, configure `ReefSafeGuard` as the Safe transaction guard and bind the Safe to a
local Reef agent id. The guard calls `canExecuteAction` before execution and blocks delegatecall by
default, so standard native/ERC-20 transactions cannot bypass Reef policy through the Safe
transaction path.

Inherit `ReefGuarded` (`src/ReefGuarded.sol`) and gate any entrypoint with the `onlyCleared`
modifier — the call reverts with ReefGuard's **exact** reason if the agent isn't cleared:

```solidity
import {ReefGuarded} from "reef/src/ReefGuarded.sol";

contract MyVault is ReefGuarded {
    constructor(address reefGuard) ReefGuarded(reefGuard) {}

    function allocate(uint256 agentId, address asset, uint256 sizeBps, uint256 amount)
        external
        onlyCleared(agentId, asset, sizeBps)   // reverts "insufficient bond", "agent under dispute", …
    {
        // your execution logic — the agent is verified allowed for this asset & size.
    }
}
```

Prefer not to inherit? Call it directly:

```solidity
(bool ok, string memory reason) = IReefGuard(guard).canExecute(agentId, asset, sizeBps);
require(ok, reason);
```

For standard token/native actions, call the inspection API instead:

```solidity
ReefGuard.Action memory action = ReefGuard.Action({
    target: token,
    value: 0,
    data: abi.encodeWithSelector(IERC20.transfer.selector, recipient, amount),
    asset: token,
    portfolioValue: currentPortfolioValue
});

(bool ok, string memory reason, uint256 parsedAmount, uint256 derivedSizeBps) =
    reefGuard.canExecuteAction(agentId, action);
require(ok, reason);
```

`MockProtocol` (`src/MockProtocol.sol`, deployed + Mantlescan-verified at
`0x44E2324BBd1A645c776c442DCa418b791E93fbb2`) is a live reference: it gated a real agent action
on-chain and reverts with the policy reason when an agent isn't cleared.

## 2. Off-chain reads (JS / TS)

The `@reef/sdk` package (`sdk/`) is zero-dependency — `canExecuteAction` and `canExecute` are raw
`eth_call`s; the passport methods fetch public JSON. See `sdk/README.md`.

```js
import { ReefClient } from "@reef/sdk";
const reef = new ReefClient({ rpcUrl, guardAddress, apiBase: "https://reef.gudman.xyz/api" });
const { allowed, reason, amount, sizeBps } = await reef.canExecuteAction(agentId, {
  target: token,
  value: 0,
  data: erc20TransferCalldata,
  asset: token,
  portfolioValue,
});
const passport = await reef.passport(agentId);
```

## Agent Passport API

Per-agent JSON, regenerated from the live feeds:

- `GET /api/agent/index.json` — list of agent ids.
- `GET /api/agent/<id>.json` — trust score + T-tier + components, ReefGuard verdict, allocation
  under the active mandate, and the latest decision/receipt.

## Addresses (Mantle Sepolia, chain 5003)

| Contract | Address |
|---|---|
| ReefGuard | `0x108411e3AA1fA2D3643b86A0B52Fd5bE12FDfe3f` |
| AgentIdentity (ERC-8004) | `0xe6D6320a3647a4b21Abe1654C30E848318D161DD` |
| ReputationBond | `0xccfF181441a636a63f8b5f9b6697585b54165DAe` |
| MockProtocol (example) | `0x44E2324BBd1A645c776c442DCa418b791E93fbb2` |

Full address set: `deployments/mantle-sepolia.json`. Unaudited testnet code — see `SECURITY.md`
before any mainnet TVL.
