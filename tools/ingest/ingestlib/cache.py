"""Content-addressed cache for model responses.

The cache key is a hash of everything that could change the answer: the model
name, the prompt, and the bytes of every image sent. Change any of them and you
get a miss; change none and a re-run is free.

This is what makes the pipeline safe to iterate on. Fixing a validation gate and
re-running a 75-question paper should cost nothing, and without a cache keyed
this precisely it costs a full extraction every time.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any, Optional


class ResponseCache:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.root.mkdir(parents=True, exist_ok=True)
        self.hits = 0
        self.misses = 0

    @staticmethod
    def key(*, model: str, prompt: str, images: list[bytes] | None = None, extra: str = "") -> str:
        digest = hashlib.sha256()
        digest.update(model.encode("utf-8"))
        digest.update(b"\x00")
        digest.update(prompt.encode("utf-8"))
        digest.update(b"\x00")
        digest.update(extra.encode("utf-8"))
        for blob in images or []:
            digest.update(b"\x00")
            digest.update(hashlib.sha256(blob).digest())
        return digest.hexdigest()

    def _path(self, key: str) -> Path:
        # Two-level fan-out; a few thousand files in one directory is slow to
        # list on Windows and this costs nothing to do up front.
        return self.root / key[:2] / f"{key}.json"

    def get(self, key: str) -> Optional[Any]:
        path = self._path(key)
        if not path.exists():
            self.misses += 1
            return None
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            self.misses += 1
            return None
        self.hits += 1
        return payload.get("value")

    def put(self, key: str, value: Any, *, meta: dict | None = None) -> None:
        path = self._path(key)
        path.parent.mkdir(parents=True, exist_ok=True)
        payload = {"value": value, "meta": meta or {}}
        # Write-then-rename so an interrupted run never leaves a half-written
        # entry that would deserialize as a valid miss-shaped file.
        temporary = path.with_suffix(".tmp")
        temporary.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        temporary.replace(path)

    def stats(self) -> str:
        total = self.hits + self.misses
        if not total:
            return "cache: unused"
        return f"cache: {self.hits}/{total} hits ({self.hits / total:.0%})"
