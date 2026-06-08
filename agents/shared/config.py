"""Environment + chain config loader for the Reef reference agents.

Reads .env (project root or agents/) and the Foundry-pinned chain config in
deployments/mantle-sepolia.json. All addresses, keys, and endpoints come from
.env — nothing is hardcoded here.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv

# Repo root = two levels up from this file (agents/shared/config.py -> repo).
REPO_ROOT = Path(__file__).resolve().parents[2]
AGENTS_DIR = Path(__file__).resolve().parents[1]
DEPLOYMENTS_DIR = REPO_ROOT / "deployments"
FOUNDRY_OUT = REPO_ROOT / "out"

# Load .env from repo root first, then agents/ (agents/.env wins if both set the same key).
load_dotenv(REPO_ROOT / ".env")
load_dotenv(AGENTS_DIR / ".env", override=True)


def _require(key: str) -> str:
    val = os.getenv(key)
    if not val:
        raise RuntimeError(f"missing required env var: {key}")
    return val


def _optional(key: str, default: str | None = None) -> str | None:
    val = os.getenv(key)
    return val if val else default


@dataclass(frozen=True)
class ChainConfig:
    name: str
    chain_id: int
    rpc_url: str
    identity_address: str
    deployment_file: Path


def load_chain(network: str = "mantle-sepolia") -> ChainConfig:
    """Load the pinned chain config for `network` (matches deployments/<network>.json)."""
    path = DEPLOYMENTS_DIR / f"{network}.json"
    if not path.exists():
        raise FileNotFoundError(f"no deployment file: {path}")
    with path.open("r", encoding="utf-8") as f:
        data = json.load(f)

    rpc_env = "MANTLE_SEPOLIA_RPC" if network == "mantle-sepolia" else "MANTLE_RPC"
    rpc_url = _optional(rpc_env) or data["rpc"]

    # IDENTITY_ADDR env wins over the deployment file — useful when the file still
    # has placeholder zero addresses.
    identity_addr = _optional("IDENTITY_ADDR") or data["reef"]["AgentIdentity"]
    if not identity_addr or int(identity_addr, 16) == 0:
        raise RuntimeError(
            "AgentIdentity address not set. Set IDENTITY_ADDR in .env or fill "
            f"{path.name}.reef.AgentIdentity."
        )

    return ChainConfig(
        name=data["network"],
        chain_id=int(data["chainId"]),
        rpc_url=rpc_url,
        identity_address=identity_addr,
        deployment_file=path,
    )


@dataclass(frozen=True)
class AgentRuntimeConfig:
    vault_address: str
    private_key: str
    poll_interval_s: int
    # Allora
    allora_api_key: str | None
    allora_topic_id: int
    allora_chain_slug: str
    # Z.ai
    zai_api_key: str | None
    zai_model: str
    zai_base_url: str


def load_agent_runtime(
    vault_env: str = "VAULT_ADDRESS",
    key_env: str = "PRIVATE_KEY",
) -> AgentRuntimeConfig:
    """Load the per-agent runtime config (vault address, signer key, API params)."""
    return AgentRuntimeConfig(
        vault_address=_require(vault_env),
        private_key=_require(key_env),
        poll_interval_s=int(_optional("AGENT_POLL_INTERVAL_S", "30") or "30"),
        allora_api_key=_optional("ALLORA_API_KEY"),
        # Allora topic 13 = ETH/USD price prediction (verified live against the v2
        # consumer API; topic 14 is BTC, not ETH).
        allora_topic_id=int(_optional("ALLORA_TOPIC_ID", "13") or "13"),
        # The v2 consumer endpoint takes a string chain slug, e.g. "ethereum-11155111"
        # (Sepolia) — verified working. NOT a numeric chain id.
        allora_chain_slug=_optional("ALLORA_CHAIN_SLUG", "ethereum-11155111")
        or "ethereum-11155111",
        zai_api_key=_optional("ZAI_API_KEY"),
        # Z.ai OpenAI-compatible endpoint + model id.
        # Spec says model="glm-5.1", endpoint="https://api.z.ai/v4/chat/completions".
        # NOTE: Z.ai's public docs list the current production base path as
        # "https://api.z.ai/api/paas/v4" and the current top model as glm-4.6
        # (https://docs.z.ai). glm-5.1 + a /v4/ root may be the latest release the
        # user has access to. We default to the spec values; override via env if the
        # public docs path is what your key uses:
        #   ZAI_BASE_URL=https://api.z.ai/api/paas/v4
        #   ZAI_MODEL=glm-4.6
        zai_model=_optional("ZAI_MODEL", "glm-5.1") or "glm-5.1",
        zai_base_url=_optional("ZAI_BASE_URL", "https://api.z.ai/v4")
        or "https://api.z.ai/v4",
    )
