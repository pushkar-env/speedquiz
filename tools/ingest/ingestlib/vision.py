"""Vision extraction: a rendered question crop becomes structured content.

This stage exists because the maths cannot be recovered from the PDF's text
layer. Sources typeset formulae as positioned glyph runs -- a fraction is two
glyph rows and a drawn rule, a radical is a glyph plus a path -- so the text
layer yields `y2 dx + (x -1 y )dy = 0` for what is actually
`y^2\,dx + \left(x - \tfrac{1}{y}\right)dy = 0`.

Reconstructing that positionally is a maths-OCR problem, and any heuristic
tuned to one publisher's renderer breaks on the next one. Reading the rendered
image is the only approach that survives an unfamiliar PDF, which is the whole
requirement here.

The model is told **not to solve anything**. Extraction and solving are separate
calls on purpose: an independent solve later is only a useful check on the
answer key if it never saw the options laid out as authoritative.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

import httpx

from .figures import Figure
from .llm import LLMClient
from .profiles import SectionSpec
from .segment import QuestionRegion

SYSTEM = """You transcribe exam questions from images into structured JSON.

You are a transcriber, not a solver. Never work out or state the answer, and
never mark an option as correct -- that comes from the official answer key.

Rules:
- Transcribe EXACTLY what is printed. Do not fix, simplify or reword anything,
  including printed errors.
- All mathematics goes in LaTeX between single dollar signs, inline with the
  prose: "the value of $\\int_0^1 x^2\\,dx$ is". Use \\frac, \\sqrt, ^, _,
  \\int, \\sum, \\vec, \\hat, \\alpha and so on.
- Chemistry formulae are maths too: $\\mathrm{H_2SO_4}$, $\\mathrm{Ca(OH)_2}$.
- Never put a figure into LaTeX. Figures are placed with figure blocks.
- Text blocks hold prose plus inline LaTeX. Never wrap an entire sentence in $.
- Preserve list structure ((A), (B), (I), (II)) as printed, in text blocks.
- The image may show one question stitched across a page break; a grey
  horizontal band marks the seam. Ignore the band.
- Output JSON only."""

USER_TEMPLATE = """Transcribe question {number} from this exam paper image.

{figure_note}

Expected answer type for this question, from the paper's section structure: {answer_type}.
{answer_type_note}

Return exactly this JSON shape:

{{
  "number": {number},
  "answer_type": "single" | "multi" | "numeric",
  "stem": [ block, ... ],
  "options": [ {{"label": "1", "blocks": [block, ...]}}, ... ],
  "unit": "the printed unit of the numeric answer, or null",
  "transcription_notes": "anything unclear or unreadable, else null"
}}

A block is one of:
  {{"t": "text", "v": "prose with inline $LaTeX$"}}
  {{"t": "figure", "ref": "fig1"}}

Notes:
- "options" MUST be [] for a numeric question, and MUST have every printed
  option for a choice question, in printed order, labels "1".."4" (or "A".."D"
  exactly as printed).
- Put each figure exactly where it appears in the reading order. A figure that
  belongs to one option goes in that option's blocks, not in the stem.
- Use every figure ref listed above exactly once, unless a figure is genuinely
  decorative."""

NUMERIC_NOTE = (
    "This is a numeric-entry question: there are no options to transcribe. If the "
    "image clearly shows four lettered or numbered options anyway, transcribe them "
    'and set answer_type to "single" -- the section structure can be wrong.'
)
CHOICE_NOTE = (
    "This is a choice question: transcribe every printed option. If the image "
    "clearly shows no options and asks for a value, set answer_type to "
    '"numeric" and return options: [].'
)


@dataclass
class ExtractedOption:
    label: str
    blocks: list[dict]


@dataclass
class ExtractedQuestion:
    number: int
    answer_type: str
    stem: list[dict]
    options: list[ExtractedOption] = field(default_factory=list)
    unit: Optional[str] = None
    transcription_notes: Optional[str] = None
    #: Refs the model actually placed, for the figure-orphan gate.
    placed_refs: list[str] = field(default_factory=list)

    def plain_text(self) -> str:
        """A flat rendering, for dedup hashing and full-text search."""
        parts = [b.get("v", "") for b in self.stem if b.get("t") == "text"]
        for option in self.options:
            parts.extend(b.get("v", "") for b in option.blocks if b.get("t") == "text")
        return " ".join(p.strip() for p in parts if p).strip()


def _figure_note(figures: list[Figure]) -> str:
    if not figures:
        return (
            "This question has no extracted figures. Do not emit any figure blocks. "
            "If the text refers to a figure you can see in the image but no ref is "
            'listed, say so in transcription_notes.'
        )
    listed = ", ".join(f"{f.ref} ({f.width}x{f.height}px)" for f in figures)
    return (
        f"This question has {len(figures)} extracted figure(s), listed in reading "
        f"order (top to bottom, then left to right): {listed}. "
        "Place each one with a figure block where it appears."
    )


def _normalize_blocks(raw: object, valid_refs: set[str], placed: list[str]) -> list[dict]:
    """Coerce whatever came back into the block shape, dropping the rest.

    A hallucinated figure ref is dropped here rather than at the gate, because a
    dangling ref would otherwise render as a missing image in the app -- the one
    failure mode that makes a question unanswerable.
    """
    blocks: list[dict] = []
    if not isinstance(raw, list):
        return blocks
    for item in raw:
        if not isinstance(item, dict):
            if isinstance(item, str) and item.strip():
                blocks.append({"t": "text", "v": item.strip()})
            continue
        kind = item.get("t") or item.get("type")
        if kind == "text":
            value = str(item.get("v") or item.get("text") or "").strip()
            if value:
                blocks.append({"t": "text", "v": value})
        elif kind == "figure":
            ref = str(item.get("ref") or item.get("id") or "").strip()
            if ref in valid_refs:
                blocks.append({"t": "figure", "ref": ref})
                placed.append(ref)
    return blocks


def _normalize(payload: dict, number: int, figures: list[Figure]) -> ExtractedQuestion:
    valid_refs = {f.ref for f in figures}
    placed: list[str] = []

    stem = _normalize_blocks(payload.get("stem"), valid_refs, placed)

    options: list[ExtractedOption] = []
    for index, raw_option in enumerate(payload.get("options") or [], start=1):
        if isinstance(raw_option, str):
            options.append(ExtractedOption(str(index), [{"t": "text", "v": raw_option.strip()}]))
            continue
        if not isinstance(raw_option, dict):
            continue
        label = str(raw_option.get("label") or index).strip()
        blocks = _normalize_blocks(raw_option.get("blocks"), valid_refs, placed)
        if not blocks and raw_option.get("text"):
            blocks = [{"t": "text", "v": str(raw_option["text"]).strip()}]
        if blocks:
            options.append(ExtractedOption(label, blocks))

    answer_type = str(payload.get("answer_type") or "single").strip().lower()
    if answer_type not in {"single", "multi", "numeric"}:
        answer_type = "numeric" if not options else "single"

    notes = payload.get("transcription_notes")
    unit = payload.get("unit")
    return ExtractedQuestion(
        number=number,
        answer_type=answer_type,
        stem=stem,
        options=options,
        unit=str(unit).strip() if unit else None,
        transcription_notes=str(notes).strip() if notes else None,
        placed_refs=placed,
    )


async def extract_question(
    client: httpx.AsyncClient,
    llm: LLMClient,
    *,
    model: str,
    region: QuestionRegion,
    crop_png: bytes,
    figures: list[Figure],
    section: Optional[SectionSpec],
) -> ExtractedQuestion:
    expected = section.answer_type if section else "single"
    user = USER_TEMPLATE.format(
        number=region.number,
        figure_note=_figure_note(figures),
        answer_type=expected,
        answer_type_note=NUMERIC_NOTE if expected == "numeric" else CHOICE_NOTE,
    )
    payload = await llm.complete_json(
        client, model=model, system=SYSTEM, user=user, images=[crop_png]
    )
    if not isinstance(payload, dict):
        raise ValueError(f"question {region.number}: expected a JSON object")
    return _normalize(payload, region.number, figures)


async def extract_all(
    llm: LLMClient,
    *,
    model: str,
    regions: list[QuestionRegion],
    crops: dict[int, Path],
    figures: dict[int, list[Figure]],
    section_for,
    concurrency: int = 4,
    on_done=None,
) -> dict[int, ExtractedQuestion]:
    """Extract every question, bounded concurrency, failures isolated."""
    semaphore = asyncio.Semaphore(concurrency)
    results: dict[int, ExtractedQuestion] = {}
    errors: dict[int, str] = {}

    async with httpx.AsyncClient() as http:
        async def run(region: QuestionRegion) -> None:
            async with semaphore:
                try:
                    crop = crops[region.number].read_bytes()
                    results[region.number] = await extract_question(
                        http, llm,
                        model=model,
                        region=region,
                        crop_png=crop,
                        figures=figures.get(region.number, []),
                        section=section_for(region.number),
                    )
                except Exception as error:  # one bad question must not stop 74 good ones
                    errors[region.number] = f"{type(error).__name__}: {error}"
                if on_done:
                    on_done(region.number, region.number in results)

        await asyncio.gather(*(run(r) for r in regions))

    if errors:
        for number, message in sorted(errors.items()):
            print(f"    ! Q{number} extraction failed: {message}")
    return results
