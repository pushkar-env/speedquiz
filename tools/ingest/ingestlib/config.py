"""Paths, model names and tunables for the ingestion toolchain.

The repo `.env` is loaded here, at import time, because `SETTINGS` is built from
it immediately below -- anything that loads the environment later than this
module would be too late to matter.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
REPO_ROOT = ROOT.parent.parent


def load_dotenv() -> None:
    """Reuse the backend's .env so the API key lives in exactly one place.

    `setdefault` rather than assignment: a variable already exported in the
    shell is a deliberate override and must win over the file.
    """
    for candidate in (REPO_ROOT / ".env", ROOT / ".env"):
        if not candidate.exists():
            continue
        try:
            lines = candidate.read_text(encoding="utf-8").splitlines()
        except OSError:
            continue
        for line in lines:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            name, value = line.split("=", 1)
            os.environ.setdefault(name.strip(), value.strip().strip('"').strip("'"))


load_dotenv()


def _env(name: str, default: str) -> str:
    return os.environ.get(name, default).strip() or default


@dataclass(frozen=True)
class Settings:
    #: Drop PDFs here. The watcher and `run --all` both read this.
    inbox: Path = DATA / "inbox"
    #: Per-paper scratch: page renders, crops, the model cache.
    work: Path = DATA / "work"
    #: Canonical output -- one directory per paper, ready to import.
    out: Path = DATA / "out"

    #: Vision extraction. This is the quality-critical call: it reads the
    #: rendered crop and writes the LaTeX. A mini model saves pennies and costs
    #: you stacked fractions flattened to `1/2`, so it is deliberately NOT
    #: defaulted to the backend's cheaper LLM_MODEL_GENERATE.
    vision_model: str = field(default_factory=lambda: _env("INGEST_VISION_MODEL", "gpt-4o"))
    #: Solving, worked solutions and chapter tagging.
    text_model: str = field(default_factory=lambda: _env("INGEST_TEXT_MODEL", "gpt-4o"))
    api_key: str = field(default_factory=lambda: _env("LLM_API_KEY", ""))
    api_base: str = field(default_factory=lambda: _env("LLM_API_BASE", "https://api.openai.com/v1"))

    #: Crops are rendered at this DPI. 200 keeps a subscript legible without
    #: pushing a full-page crop past the model's image budget.
    crop_dpi: int = 200
    #: Used only when a figure has to be clipped from vector drawings; embedded
    #: images are taken at their native resolution instead.
    figure_dpi: int = 300

    #: How many questions to hold in flight against the API.
    concurrency: int = field(default_factory=lambda: int(_env("INGEST_CONCURRENCY", "4")))
    #: Retries per call before a question is parked as failed.
    max_retries: int = field(default_factory=lambda: int(_env("INGEST_MAX_RETRIES", "6")))
    #: Client-side tokens-per-minute ceiling. Must match (or sit just under)
    #: the organisation's real tier -- see the rate-limit headers on any
    #: response, or the limits page in the API console. The default is the
    #: entry tier for gpt-4o; raise it and the pipeline goes proportionally
    #: faster.
    tokens_per_minute: int = field(default_factory=lambda: int(_env("INGEST_TPM", "30000")))

    def ensure_dirs(self) -> None:
        for directory in (self.inbox, self.work, self.out):
            directory.mkdir(parents=True, exist_ok=True)


SETTINGS = Settings()
