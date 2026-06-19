# Reef Reference Agents

Python reference implementations of two Reef Sovereign agents:

- **`allora_agent/`** — consumes [Allora](https://docs.allora.network) price-prediction
  topics, asks GLM (glm-4.7-flash) for an action, publishes a signed receipt to its `AgentVault`.
- **`nansen_agent/`** — consumes a smart-money-inflow signal (mock in v1, real
  Nansen MCP to follow) and does the same.

Both agents:
1. Fetch an external signal.
2. Ask Z.ai GLM (glm-4.7-flash) to return `{action, nav_delta_bps, reasoning}`.
3. Build `abi.encode(uint256 seq, bytes32 evidenceHash, int256 navDelta, uint64 period)`.
4. Call `AgentVault.publishReceipt(payload)` from the registered operator wallet.
5. Print the tx hash + the updated `AgentIdentity.getSummary` reputation tuple.

If GLM is unavailable (no key, network error, malformed reply) the agent falls
back to a deterministic rule and logs the fallback clearly.

## Layout

```
agents/
  shared/           web3 client, config, receipt builder, GLM wrapper
  allora_agent/     Allora-fed loop + decision parser
  nansen_agent/     Nansen-fed loop + mock signal
  scripts/          register_agent.py, deploy_vault.py
```

## Setup

From the repo root:

```bash
forge build                          # produces out/AgentVault.sol/AgentVault.json etc.
python -m venv .venv
. .venv/Scripts/activate              # PowerShell: . .venv\Scripts\Activate.ps1
pip install -r agents/requirements.txt
cp .env.example .env                 # then fill in real values
```

### Required env

| Var | Purpose |
| --- | --- |
| `PRIVATE_KEY` | Operator wallet (the wallet returned by `AgentIdentity.getAgentWallet(agentId)`). |
| `MANTLE_SEPOLIA_RPC` | Mantle Sepolia RPC URL. Defaults to the public endpoint pinned in `deployments/mantle-sepolia.json`. |
| `IDENTITY_ADDR` | AgentIdentity contract address (overrides the deployment JSON). |
| `VAULT_ADDRESS` | The AgentVault this agent runs against. |
| `ALLORA_API_KEY` | Allora consumer key (allora_agent only). |
| `ZAI_API_KEY` | Z.ai key for GLM (glm-4.7-flash). Optional — without it, agents use the fallback rule. |

### Optional env

| Var | Default | Purpose |
| --- | --- | --- |
| `AGENT_POLL_INTERVAL_S` | `30` | Seconds between iterations. |
| `ALLORA_TOPIC_ID` | `14` | Allora topic id (ETH/USD 5-min predictions, per Allora docs). |
| `ALLORA_CHAIN_ID` | `1` | Allora consumer chain id slug. |
| `ZAI_MODEL` | `glm-4.7-flash` | Z.ai model id. |
| `ZAI_BASE_URL` | `https://api.z.ai/v4` | Z.ai API root. Set to `https://api.z.ai/api/paas/v4` if your key uses the public docs path. |

## Bootstrapping a brand-new agent

```bash
# 1. Register an identity (prints the new agentId on stdout)
python -m agents.scripts.register_agent

# 2. Deploy a vault for that agentId (prints the vault address)
python -m agents.scripts.deploy_vault --agent-id 1 --asset 0xMockUSDC...

# 3. Set VAULT_ADDRESS=<printed address> in .env, then run an agent
python -m agents.allora_agent.agent
python -m agents.nansen_agent.agent
```

## Expected console output

```
2026-05-29 12:30:00 [allora_agent] INFO: allora_agent starting | chain=Mantle Sepolia operator=0xAbc... vault=0xDef... topic=14 interval=30s
2026-05-29 12:30:31 [allora_agent] INFO: publishing receipt seq=0 action=increase nav_delta_bps=42 source=glm
2026-05-29 12:30:38 [allora_agent] INFO: tx 0x123... mined in block 9876543 status=1 | reputation cumulative=42000000000000000000 count=1
2026-05-29 12:31:08 [allora_agent] INFO: publishing receipt seq=1 action=hold nav_delta_bps=0 source=fallback
...
```

A `source=fallback` line means GLM was unreachable and the deterministic rule
fired. The on-chain pipeline is unaffected — receipts still publish.

## Verifying the receipt envelope off-chain

```python
from agents.shared.receipt import build_evidence, sign_receipt

evidence, envelope = build_evidence({"schema": "reef.receipt.v2", "action": "hold", "seq": 0})
receipt, signature = sign_receipt(
    private_key,
    vault=vault_address,
    chain_id=5003,
    agent_id=1,
    seq=0,
    evidence_hash=evidence,
    claimed_delta=0,
    period=600,
    decision_block=123456,
    action_hash={"action": "hold"},
    policy_hash={},
    execution_hash={},
    post_state_hash={},
    outcome_hash={},
    evidence_uri="ipfs://bafy.../evidence.json",
)
```

This is the exact struct/signature pair `AgentVault.publishReceipt` verifies on-chain.
