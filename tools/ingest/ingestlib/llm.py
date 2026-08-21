"""Minimal OpenAI-compatible client for the ingestion toolchain.

Deliberately separate from `backend/app/ai/openai_provider.py`. That provider is
tuned for the request path -- short timeouts, one system prompt shape, no image
input. This one runs in a batch job: it sends images, retries hard, and caches
everything. Sharing the class would have meant bending both.
"""

from __future__ import annotations

import asyncio
import base64
import json
import random
import re
from dataclasses import dataclass
from typing import Any, Optional

import httpx

from .cache import ResponseCache
from .ratelimit import TokenBucket, estimate_image_tokens


class LLMError(RuntimeError):
    pass


def extract_json(text: str) -> Any:
    """Parse a model response that is supposed to be JSON.

    Models still fence their output occasionally even in JSON mode, and a
    trailing prose sentence after a valid object is common enough to be worth
    recovering from rather than failing the whole question over.
    """
    cleaned = text.strip()
    if cleaned.startswith("```"):
        cleaned = re.sub(r"^```(?:json)?\s*", "", cleaned)
        cleaned = re.sub(r"\s*```$", "", cleaned)
    try:
        return json.loads(cleaned)
    except json.JSONDecodeError:
        pass

    start = cleaned.find("{")
    end = cleaned.rfind("}")
    if start != -1 and end > start:
        return json.loads(cleaned[start : end + 1])
    raise LLMError(f"response was not JSON: {text[:200]!r}")


@dataclass
class Usage:
    calls: int = 0
    prompt_tokens: int = 0
    completion_tokens: int = 0

    def add(self, payload: dict) -> None:
        usage = payload.get("usage") or {}
        self.calls += 1
        self.prompt_tokens += int(usage.get("prompt_tokens") or 0)
        self.completion_tokens += int(usage.get("completion_tokens") or 0)

    def summary(self) -> str:
        return (
            f"{self.calls} calls, {self.prompt_tokens:,} prompt + "
            f"{self.completion_tokens:,} completion tokens"
        )


class LLMClient:
    def __init__(
        self,
        *,
        api_key: str,
        api_base: str,
        cache: ResponseCache,
        max_retries: int = 6,
        timeout: float = 180.0,
        tokens_per_minute: int = 30000,
    ) -> None:
        if not api_key:
            raise LLMError(
                "No API key. Set LLM_API_KEY in the environment (the repo .env "
                "already carries one for the backend)."
            )
        self._api_key = api_key
        self._url = api_base.rstrip("/") + "/chat/completions"
        self._cache = cache
        self._max_retries = max_retries
        self._timeout = timeout
        self._bucket = TokenBucket(tokens_per_minute)
        self.usage = Usage()
        self.throttled = 0

    @staticmethod
    def _retry_after(response: httpx.Response) -> float:
        """Seconds to wait, from whichever header the API populated."""
        for header in ("retry-after", "x-ratelimit-reset-tokens", "x-ratelimit-reset-requests"):
            raw = response.headers.get(header)
            if not raw:
                continue
            match = re.match(r"^\s*([\d.]+)\s*(ms|s|m)?\s*$", str(raw))
            if not match:
                continue
            value = float(match.group(1))
            unit = match.group(2) or "s"
            seconds = value / 1000 if unit == "ms" else value * 60 if unit == "m" else value
            return min(90.0, max(1.0, seconds))
        # The message body carries the wait when the headers do not.
        match = re.search(r"try again in ([\d.]+)\s*(ms|s)", response.text or "", re.I)
        if match:
            value = float(match.group(1))
            return min(90.0, max(1.0, value / 1000 if match.group(2).lower() == "ms" else value))
        return 20.0

    @staticmethod
    def _image_part(png: bytes) -> dict:
        encoded = base64.b64encode(png).decode("ascii")
        return {
            "type": "image_url",
            "image_url": {"url": f"data:image/png;base64,{encoded}", "detail": "high"},
        }

    async def complete_json(
        self,
        client: httpx.AsyncClient,
        *,
        model: str,
        system: str,
        user: str,
        images: Optional[list[bytes]] = None,
        temperature: float = 0.0,
    ) -> Any:
        """One JSON completion, cached and retried.

        Temperature defaults to 0: this is extraction, not authoring, and a
        re-run that produces different LaTeX for the same crop would make the
        cache and the review queue both meaningless.
        """
        cache_key = ResponseCache.key(
            model=model, prompt=f"{system}\n---\n{user}", images=images, extra=str(temperature)
        )
        cached = self._cache.get(cache_key)
        if cached is not None:
            return cached

        content: Any = user
        if images:
            content = [{"type": "text", "text": user}] + [self._image_part(i) for i in images]

        body = {
            "model": model,
            "temperature": temperature,
            "response_format": {"type": "json_object"},
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": content},
            ],
        }
        headers = {
            "Authorization": f"Bearer {self._api_key}",
            "Content-Type": "application/json",
        }

        # Reserve the estimated cost before going out, so concurrent workers
        # queue against the limit instead of all discovering it at once.
        estimate = len(system) // 3 + len(user) // 3 + 600
        for blob in images or []:
            estimate += estimate_image_tokens(len(blob))

        last_error: Optional[Exception] = None
        malformed = 0
        for attempt in range(self._max_retries):
            await self._bucket.acquire(estimate)
            if malformed:
                # Temperature 0 is right for extraction, but it also means a
                # response that came back truncated or malformed comes back
                # identically malformed on every retry. Nudge just enough to
                # break the tie, and only after the deterministic attempt has
                # already failed.
                body["temperature"] = min(0.6, 0.15 * malformed)
            try:
                response = await client.post(
                    self._url, headers=headers, json=body, timeout=self._timeout
                )
                if response.status_code == 429:
                    wait = self._retry_after(response)
                    self.throttled += 1
                    # Hold every worker, not just this one: the limit is
                    # per-organisation, so letting the others keep firing would
                    # guarantee they are throttled the moment this one resumes.
                    await self._bucket.penalize(wait)
                    last_error = LLMError(f"HTTP 429 (waited {wait:.0f}s)")
                    continue
                if response.status_code >= 500:
                    last_error = LLMError(f"HTTP {response.status_code}: {response.text[:200]}")
                    await asyncio.sleep(min(30.0, 2 ** attempt) * (0.5 + random.random()))
                    continue
                if response.status_code >= 400:
                    raise LLMError(f"HTTP {response.status_code}: {response.text[:400]}")
                payload = response.json()
                self.usage.add(payload)
                actual = int((payload.get("usage") or {}).get("prompt_tokens") or 0)
                self._bucket.record_actual(estimate, actual)
                choice = payload["choices"][0]
                if choice.get("finish_reason") == "length":
                    # Truncated mid-JSON. Retrying verbatim would truncate at
                    # the same place, so treat it as malformed and let the
                    # nudge above take effect.
                    malformed += 1
                    last_error = LLMError("response truncated (hit the output limit)")
                    continue
                value = extract_json(choice["message"]["content"])
                self._cache.put(cache_key, value, meta={"model": model})
                return value
            except (httpx.TimeoutException, httpx.TransportError) as error:
                last_error = error
                await asyncio.sleep(min(30.0, 2 ** attempt) * (0.5 + random.random()))
            except (json.JSONDecodeError, KeyError, LLMError) as error:
                # A 4xx that is not a rate limit is a bad request -- wrong
                # model name, malformed body, revoked key -- and no amount of
                # retrying fixes it.
                if isinstance(error, LLMError) and str(error).startswith("HTTP 4"):
                    raise
                malformed += 1
                last_error = LLMError(f"unusable response: {error}")

        raise LLMError(f"gave up after {self._max_retries} attempts: {last_error}")
