"""Thin Z.ai GLM client (OpenAI-compatible chat/completions).

Endpoint + model id come from shared.config (env-overridable). On any failure
(missing key, network error, non-2xx) `chat()` raises GlmUnavailable so callers
can fall back to a deterministic rule.
"""

from __future__ import annotations

import logging
import time
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
    timeout: float = 30.0,
    response_json: bool = True,
    retries: int = 2,
) -> str:
    """POST to <base_url>/chat/completions and return the assistant text.

    Disables GLM "thinking" (chain-of-thought) so the model returns the JSON answer
    directly — ~4x faster than the reasoning path (verified ~18s -> ~4s), which
    routinely blew past the timeout and forced a deterministic fallback. Transient
    429s / network timeouts are retried with a short backoff before giving up.
    """
    if not api_key:
        raise GlmUnavailable("ZAI_API_KEY not set")

    url = base_url.rstrip("/") + "/chat/completions"
    payload: dict[str, Any] = {
        "model": model,
        "messages": messages,
        "temperature": temperature,
        # Z.ai GLM-4.x are hybrid reasoning models; disabling thinking returns the
        # answer directly so we stay well under the timeout.
        "thinking": {"type": "disabled"},
    }
    if response_json:
        # OpenAI-compatible servers accept this; Z.ai's GLM endpoint mirrors the
        # spec. If the server rejects it we still recover the text via parsing.
        payload["response_format"] = {"type": "json_object"}

    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }

    last_err: Exception | None = None
    for attempt in range(retries):
        try:
            resp = requests.post(url, json=payload, headers=headers, timeout=timeout)
        except requests.RequestException as e:
            last_err = GlmUnavailable(f"network error calling Z.ai: {e}")
        else:
            if resp.status_code == 429:
                last_err = GlmUnavailable(f"Z.ai rate limited (429): {resp.text[:200]}")
            elif resp.status_code >= 300:
                raise GlmUnavailable(
                    f"Z.ai returned {resp.status_code}: {resp.text[:300]}"
                )
            else:
                try:
                    data = resp.json()
                    return data["choices"][0]["message"]["content"]
                except (ValueError, KeyError, IndexError, TypeError) as e:
                    raise GlmUnavailable(
                        f"unexpected Z.ai response: {resp.text[:300]}"
                    ) from e
        if attempt < retries - 1:
            time.sleep(2.0 * (attempt + 1))
    raise last_err or GlmUnavailable("Z.ai unavailable")
