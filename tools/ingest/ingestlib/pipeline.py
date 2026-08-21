"""The driver: one PDF in, one canonical paper document out.

Stages run in dependency order and each caches its own output, so a re-run after
a prompt change or a gate fix only redoes the part that changed.

    discover -> segment -> answer key -> figures -> render
             -> vision extract -> solve/cross-check -> gates -> emit
"""

from __future__ import annotations

import hashlib
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from . import figures as figmod
from . import gates, paper
from .answerkey import parse_page
from .cache import ResponseCache
from .config import Settings
from .llm import LLMClient
from .naming import parse_filename
from .profiles import generic_profile, get_profile
from .render import render_all
from .segment import analyze
from .solutions import solve_all
from .vision import extract_all


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


class Progress:
    """Single-line progress that degrades to plain lines when piped."""

    def __init__(self, label: str, total: int) -> None:
        self.label = label
        self.total = total
        self.done = 0
        self.failed = 0
        self.tty = sys.stdout.isatty()
        self.started = time.monotonic()

    def tick(self, _number: int, ok: bool) -> None:
        self.done += 1
        if not ok:
            self.failed += 1
        if self.tty:
            width = 28
            filled = int(width * self.done / max(1, self.total))
            bar = "#" * filled + "." * (width - filled)
            sys.stdout.write(
                f"\r    {self.label} [{bar}] {self.done}/{self.total}"
                + (f" ({self.failed} failed)" if self.failed else "")
            )
            sys.stdout.flush()

    def finish(self) -> None:
        elapsed = time.monotonic() - self.started
        if self.tty:
            sys.stdout.write("\r" + " " * 78 + "\r")
            sys.stdout.flush()
        note = f" ({self.failed} failed)" if self.failed else ""
        print(f"    {self.label}: {self.done - self.failed}/{self.total} in {elapsed:.0f}s{note}")


@dataclass
class Result:
    document: dict
    out_dir: Path
    json_path: Path
    cache_stats: str
    usage: str


async def run(
    pdf: Path,
    settings: Settings,
    *,
    force: bool = False,
    limit: Optional[int] = None,
    skip_solutions: bool = False,
) -> Result:
    identity = parse_filename(pdf)
    source_sha = sha256_file(pdf)
    work = settings.work / identity.key
    out_dir = settings.out / identity.key

    print(f"  paper:   {identity.exam_name} {identity.year} "
          f"{identity.session or ''} {'shift ' + str(identity.shift) if identity.shift else ''}".rstrip())
    print(f"  key:     {identity.key}")
    print(f"  sha256:  {source_sha[:16]}...")

    existing = out_dir / "paper.json"
    if existing.exists() and not force:
        previous = paper.load(existing)
        if previous.get("paper", {}).get("source_sha256") == source_sha:
            print("  -> already ingested and the PDF is unchanged (use --force to redo)")
            return Result(previous, out_dir, existing, "cache: skipped", "no calls")

    # --- stage 1: layout ---------------------------------------------------
    layout = analyze(pdf)
    regions = layout.regions
    if limit:
        regions = regions[:limit]
    print(f"  layout:  {layout.page_count} pages, {len(layout.regions)} questions"
          f"{f' (limited to {len(regions)})' if limit else ''}"
          f", answer key on page {layout.answer_key_page}")
    if not regions:
        raise SystemExit("  !! no questions found -- the marker pattern may not match this source")

    # --- stage 2: answer key ----------------------------------------------
    key = parse_page(pdf, layout.answer_key_page) if layout.answer_key_page is not None else {}
    wanted = {r.number for r in regions}
    missing_key = sorted(wanted - set(key))
    print(f"  key:     {len(key)} entries"
          + (f", MISSING for {missing_key}" if missing_key else ", complete"))

    # --- stage 3: profile --------------------------------------------------
    profile = get_profile(identity.exam_slug, len(layout.regions)) or generic_profile(len(layout.regions))
    if profile.slug == "unknown":
        print(f"  profile: none for {identity.exam_slug!r} -- using a single "
              "no-negative-marking section")
    else:
        print(f"  profile: {profile.name}, {len(profile.sections)} sections, "
              f"{profile.duration_minutes} min, {profile.total_marks:g} marks")

    # --- stage 4: figures --------------------------------------------------
    figures = figmod.extract(layout, figure_dpi=settings.figure_dpi)
    figures = {n: f for n, f in figures.items() if n in wanted}
    asset_manifest = figmod.write_all(figures, out_dir / "assets")
    total_figures = sum(len(v) for v in figures.values())
    print(f"  figures: {total_figures} across {len(figures)} questions "
          f"-> {len(asset_manifest)} unique assets (light + dark)")

    # --- stage 5: crops ----------------------------------------------------
    crops = render_all(pdf, regions, work / "crops", dpi=settings.crop_dpi)
    crop_bytes = sum(p.stat().st_size for p in crops.values())
    print(f"  crops:   {len(crops)} rendered at {settings.crop_dpi} dpi "
          f"({crop_bytes/1024/1024:.1f} MB)")

    # --- stage 6: vision extraction ---------------------------------------
    cache = ResponseCache(work / "cache")
    llm = LLMClient(
        api_key=settings.api_key,
        api_base=settings.api_base,
        cache=cache,
        max_retries=settings.max_retries,
        tokens_per_minute=settings.tokens_per_minute,
    )
    progress = Progress("extract", len(regions))
    extracted = await extract_all(
        llm,
        model=settings.vision_model,
        regions=regions,
        crops=crops,
        figures=figures,
        section_for=profile.section_for,
        concurrency=settings.concurrency,
        on_done=progress.tick,
    )
    progress.finish()

    # --- stage 7: solve + cross-check --------------------------------------
    key_answers: dict[int, Optional[str]] = {}
    for number, question in extracted.items():
        entry = key.get(number)
        section = profile.section_for(number)
        answer_text, _spec = paper.resolve_key(entry, section, question.answer_type)
        key_answers[number] = answer_text

    solutions = {}
    if not skip_solutions:
        progress = Progress("solve  ", len(extracted))
        solutions = await solve_all(
            llm,
            model=settings.text_model,
            questions=extracted,
            sections=profile.section_for,
            key_answers=key_answers,
            crops=crops,
            concurrency=settings.concurrency,
            on_done=progress.tick,
        )
        progress.finish()

    # --- stage 8: gates ----------------------------------------------------
    verdicts = {}
    for number, question in extracted.items():
        entry = key.get(number)
        verdicts[number] = gates.check(
            question,
            section=profile.section_for(number),
            figure_count=len(figures.get(number, [])),
            key_answer=key_answers.get(number),
            key_raw=entry.raw if entry else None,
            solution=solutions.get(number),
        )
    report = gates.summarize(verdicts)
    print(f"  gates:   {report['clean']} clean, {len(report['flagged'])} flagged, "
          f"{len(report['blocked'])} blocked")
    for code, count in report["by_code"].items():
        print(f"             {count:>3}  {code}")
    if report["blocked"]:
        print(f"             blocked: Q{report['blocked']}")

    # --- stage 9: emit -----------------------------------------------------
    document = paper.build(
        identity=identity,
        profile=profile,
        source_pdf=pdf,
        source_sha=source_sha,
        questions=extracted,
        solutions=solutions,
        key=key,
        figures=figures,
        asset_manifest=asset_manifest,
        verdicts=verdicts,
        models={"vision": settings.vision_model, "text": settings.text_model},
    )
    json_path = paper.write(document, out_dir)

    stats = document["stats"]
    print(f"  output:  {json_path}")
    print(f"           {stats['questions_publishable']}/{stats['questions_extracted']} publishable, "
          f"{stats['figures_used']} figures")
    print(f"           solutions: {stats['solutions_verified']} verified, "
          f"{stats['solutions_need_review']} need review, "
          f"{stats['solutions_withheld']} withheld")
    if stats["key_disagreements"]:
        print(f"           key disagreements on Q{stats['key_disagreements']}")

    usage = llm.usage.summary()
    if llm.throttled:
        usage += f", {llm.throttled} throttle waits"
    return Result(document, out_dir, json_path, cache.stats(), usage)
