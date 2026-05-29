"""Thin Z.ai GLM client (OpenAI-compatible chat/completions).

Endpoint + model id come from shared.config (env-overridable). On any failure
(missing key, network error, non-2xx) `chat()` raises GlmUnavailable so callers
can fall back to a deterministic rule.
"""

from __future__ import annotations

import json
import logging
from typing import Any

import requests

log = logging.getLogger(__name__)


class GlmUnavailable(Exception):
    """Raised when the GLM call cannot be completed (no key, network, bad response)."""


def chat(
    messages: list[dict[str, str]],
    *,
    api_key: str | None,
    base_url: str,
    model: str,
    temperature: float = 0.2,
    timeout: float = 20.0,
    response_json: bool = True,
) -> str:
    """POST to <base_url>/chat/completions and return the assistant text."""
    if not api_key:
        raise GlmUnavailable("ZAI_API_KEY not set")

    url = base_url.rstrip("/") + "/chat/completions"
    payload: dict[str, Any] = {
        "model": model,
        "messages": messages,
        "temperature": temperature,
    }
    if response_json:
        # OpenAI-compatible servers accept this; Z.ai's GLM endpoint mirrors the
        # spec. If the server rejects it we still recover the text via parsing.
        payload["response_format"] = {"type": "json_object"}

    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }

    try:
        resp = requests.post(url, json=payload, headers=headers, timeout=timeout)
    except requests.RequestException as e:
        raise GlmUnavailable(f"network error calling Z.ai: {e}") from e

    if resp.status_code >= 300:
        raise GlmUnavailable(f"Z.ai returned {resp.status_code}: {resp.text[:300]}")

    try:
        data = resp.json()
    except ValueError as e:
        raise GlmUnavailable(f"Z.ai returned non-JSON: {resp.text[:300]}") from e

    try:
        return data["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError) as e:
        raise GlmUnavailable(
            f"unexpected Z.ai response shape: {json.dumps(data)[:300]}"
        ) from e
