"""One-shot: register a new agent in the AgentIdentity contract.

Usage:
    python -m agents.scripts.register_agent

Reads PRIVATE_KEY + chain config from .env. Prints the new agentId on success.
"""

from __future__ import annotations

import logging
import sys

from agents.shared.client import get_w3, identity_contract, load_account, send_tx
from agents.shared.config import load_chain


def main() -> int:
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s: %(message)s"
    )
    log = logging.getLogger("register_agent")

    chain = load_chain()
    w3 = get_w3(chain.rpc_url)
    account = load_account()
    identity = identity_contract(w3, chain.identity_address)

    log.info(
        "registering agent | chain=%s identity=%s sender=%s",
        chain.name,
        chain.identity_address,
        account.address,
    )

    # Predict the agentId from the contract's next counter, then verify post-tx.
    predicted = identity.functions.nextAgentId().call()
    receipt = send_tx(w3, account, identity.functions.register())
    if receipt["status"] != 1:
        log.error("register() reverted, tx=%s", receipt["transactionHash"].hex())
        return 1

    actual_next = identity.functions.nextAgentId().call()
    new_id = actual_next - 1
    if new_id != predicted:
        log.warning(
            "predicted agentId=%d but actual=%d (someone else registered between calls)",
            predicted,
            new_id,
        )

    wallet = identity.functions.getAgentWallet(new_id).call()
    log.info(
        "registered agentId=%d wallet=%s tx=%s",
        new_id,
        wallet,
        receipt["transactionHash"].hex(),
    )
    print(new_id)
    return 0


if __name__ == "__main__":
    sys.exit(main())
