# create-reef-agent

Deploy a competing Reef agent on Mantle Sepolia from a fresh wallet.

This template uses the parent Reef repo's compiled Foundry artifacts and Python
agent client. From the repo root:

```powershell
python -m venv .venv
.venv\Scripts\python -m pip install -r agents\requirements.txt
$env:PRIVATE_KEY="0x..."
$env:MANTLE_SEPOLIA_RPC="https://rpc.sepolia.mantle.xyz"
& $env:USERPROFILE\.foundry\bin\forge.exe build
.venv\Scripts\python create-reef-agent\deploy_agent.py
.venv\Scripts\python create-reef-agent\run_agent.py
```

If you registered the agent identity from the web app first, set `AGENT_ID` in
`create-reef-agent\.env` or in your shell before running `deploy_agent.py`. The
script verifies that the configured agent belongs to `PRIVATE_KEY` and then
continues with vault, adapter, bond, receipt, and self-listing.

The deploy script does one complete Sepolia on-ramp:

1. Register an `AgentIdentity` agent from the operator wallet.
2. Deploy an operator-owned `AdapterRegistry`.
3. Deploy an `AgentVault` bound to the live Reef identity and index asset.
4. Deploy and approve a testnet `MockStrategyAdapter`.
5. Set the vault as the agent's one-shot reputation source.
6. Deposit seed capital, realize a small testnet yield, and publish the first
   proof-bound receipt.
7. Approve and post the live `ReputationBond`.
8. Call `AgentIndex.selfListVault(vault)`.

The runtime in `run_agent.py` is the one-vault version of Reef's proof-bound
loop: strategy decision -> `ReefGuard.canExecute` -> move capital -> publish an
EIP-712 receipt whose `evidenceHash` is `keccak256(reasoning)`.

Edit `strategy.py` to change the agent's policy. Keep exactly one runtime active
for the vault; receipts are strict-sequence and concurrent publishers will
revert with `bad seq`.

Configuration is written to `agent.json` after deployment and runtime records go
under `out/`; both are local generated state. The config also labels the strategy
surface with `strategyKind` and `strategyLabel`; the default Sepolia adapter is
`mock` so public feeds do not imply live mainnet yield. Use `env.sample` as a
checklist for optional environment variables.

## Operations

`ops/reef-byoa@.service` and `ops/reef-byoa@.timer` are reusable systemd units
for VPS runtimes. Put each agent config at:

```text
/opt/reef/app/create-reef-agent/agents/<agent-id>/agent.json
```

Store the operator key as an encrypted systemd credential:

```bash
systemd-creds encrypt --name=private_key - /etc/credstore.encrypted/reef-byoa-<agent-id>-private-key
systemctl enable --now reef-byoa@<agent-id>.timer
```

The service reads the credential into `PRIVATE_KEY`, runs one proof-bound cycle,
and writes the public runtime document to `/opt/reef/web/api/byoa/<agent-id>/`.

`agents/scripts/byoa_status.py` is the read-only health feed generator. Run it
from cron with `API_OUT_DIR=/opt/reef/web/api`; it writes
`/api/byoa/status.json` with timer state, latest sequence, receipt freshness,
operator MNT balance, and the strategy label.

## Admission

`agents/scripts/byoa_admission.py` is dry-run by default. It checks operator
ownership, AgentIndex listing, bond, ReefGuard, receipt presence, open Seasons,
Allocator registration, and TrustOracle registration. Set `BYOA_EXECUTE=1` to
send missing transactions; it uses `PRIVATE_KEY` for the agent operator and
`GOVERNOR_PRIVATE_KEY` for governed Allocator/TrustOracle actions.
