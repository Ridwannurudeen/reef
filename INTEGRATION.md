# Integrating Reef

Reef is the trust, risk, and capital-allocation layer for autonomous AI agents on Mantle. If
your protocol lets agents move capital, you can ask Reef one question before you let them:
**"can this agent touch this capital right now?"**

There are two integration surfaces. Use either or both.

## 1. On-chain gate (Solidity)

`ReefGuard.canExecute(agentId, asset, sizeBps)` is a pure view returning `(bool allowed, string
reason)`. It checks the agent's registration, ERC-8004 reputation, posted bond, open disputes, an
asset allowlist, and the action size against governor-set limits.

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

`MockProtocol` (`src/MockProtocol.sol`, deployed + Mantlescan-verified at
`0x9ef3Feb3C404651C8d240c529969B99b743dE8D0`) is a live reference: it gated a real agent action
on-chain and reverts with the policy reason when an agent isn't cleared.

## 2. Off-chain reads (JS / TS)

The `@reef/sdk` package (`sdk/`) is zero-dependency — `canExecute` is a raw `eth_call`; the
passport methods fetch public JSON. See `sdk/README.md`.

```js
import { ReefClient } from "@reef/sdk";
const reef = new ReefClient({ rpcUrl, guardAddress, apiBase: "https://reef.gudman.xyz/api" });
const { allowed, reason } = await reef.canExecute(agentId, asset, sizeBps);
const passport = await reef.passport(agentId);
```

## Agent Passport API

Per-agent JSON, regenerated from the live feeds:

- `GET /api/agent/index.json` — list of agent ids.
- `GET /api/agent/<id>.json` — trust score + rating + components, ReefGuard verdict, allocation
  under the active mandate, and the latest decision/receipt.

## Addresses (Mantle Sepolia, chain 5003)

| Contract | Address |
|---|---|
| ReefGuard | `0xe84E84D7e2E588aa8F88d1D1ADF2bdc70365a02b` |
| AgentIdentity (ERC-8004) | `0x4eCE1853623CA801536d319cB9ddE454f5dA6dC7` |
| ReputationBond | `0xeF2F3602d5fe04487a971e5d749DAC7343b8F895` |
| MockProtocol (example) | `0x9ef3Feb3C404651C8d240c529969B99b743dE8D0` |

Full address set: `deployments/mantle-sepolia.json`. Unaudited testnet code — see `SECURITY.md`
before any mainnet TVL.
