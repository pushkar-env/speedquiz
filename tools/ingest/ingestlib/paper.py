"""The canonical paper document -- the pipeline's actual output.

One JSON file plus an assets directory, per paper. Everything the importer and
the app need is in here, and nothing in here depends on the PDF any more.

The format is versioned and content-addressed: re-running the pipeline on the
same PDF with the same models produces a byte-identical document, which is what
makes `import` idempotent and a diff between two runs meaningful.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from .answerkey import KeyEntry
from .figures import Figure
from .gates import Verdict
from .naming import PaperIdentity
from .profiles import ExamProfile, SectionSpec
from .solutions import Solution
from .vision import ExtractedQuestion

FORMAT_VERSION = 2


def content_hash(stem_text: str, option_texts: list[str], language: str = "en") -> str:
    """Matches the shape used by `backend/app/ai/pipeline.content_hash`.

    Same function, same purpose: a stable identity for a question so the same
    question appearing in two shifts of the same paper is caught as a duplicate
    rather than banked twice.
    """
    normalized = "|".join(
        [language, stem_text.strip().lower()]
        + sorted(o.strip().lower() for o in option_texts)
    )
    return hashlib.sha256(normalized.encode("utf-8")).hexdigest()


def _flatten(blocks: list[dict]) -> str:
    return " ".join(b.get("v", "") for b in blocks if b.get("t") == "text").strip()


def resolve_key(
    entry: Optional[KeyEntry], section: Optional[SectionSpec], answer_type: str
) -> tuple[Optional[str], Optional[dict]]:
    """Turn a key entry into the answer, using the section to disambiguate.

    "47. (4)" is option 4 in a choice section and the value 4 in a numeric one.
    The key alone cannot tell you which; the section profile can.
    """
    if entry is None:
        return None, None

    if answer_type == "numeric":
        if entry.value is None:
            return None, None
        spec = {
            "value": entry.value,
            "tolerance": section.tolerance if section else 0.01,
            "mode": section.tolerance_mode if section else "absolute",
        }
        if entry.value_low is not None:
            spec["low"] = entry.value_low
            spec["high"] = entry.value_high
        text = ("%f" % entry.value).rstrip("0").rstrip(".")
        return text, spec

    if entry.option is None:
        return None, None
    return str(entry.option), {"option": entry.option}


def build(
    *,
    identity: PaperIdentity,
    profile: ExamProfile,
    source_pdf: Path,
    source_sha: str,
    questions: dict[int, ExtractedQuestion],
    solutions: dict[int, Solution],
    key: dict[int, KeyEntry],
    figures: dict[int, list[Figure]],
    asset_manifest: dict[str, dict],
    verdicts: dict[int, Verdict],
    models: dict[str, str],
) -> dict:
    """Assemble the canonical document."""
    sections_out = []
    for position, section in enumerate(profile.sections):
        sections_out.append({
            "name": section.name,
            "subject": section.subject,
            "position": position,
            "first_question": section.first,
            "last_question": section.last,
            "question_count": section.count,
            "answer_type": section.answer_type,
            "marking": section.marking(),
            "rules": section.rules(),
        })

    questions_out = []
    used_checksums: set[str] = set()

    for number in sorted(questions):
        question = questions[number]
        section = profile.section_for(number)
        solution = solutions.get(number)
        verdict = verdicts.get(number)
        entry = key.get(number)

        answer_text, answer_spec = resolve_key(entry, section, question.answer_type)

        option_texts = [_flatten(o.blocks) for o in question.options]
        stem_text = _flatten(question.stem)

        figure_refs = {f.ref: f for f in figures.get(number, [])}
        placed = []
        for ref in question.placed_refs:
            figure = figure_refs.get(ref)
            if figure and figure.checksum not in {p["checksum"] for p in placed}:
                placed.append({"ref": ref, "checksum": figure.checksum})
                used_checksums.add(figure.checksum)

        issues = [asdict(i) for i in (verdict.issues if verdict else [])]

        questions_out.append({
            "number": number,
            "section": section.name if section else None,
            "subject": section.subject if section else None,
            "answer_type": question.answer_type,
            "stem": question.stem,
            "options": [{"label": o.label, "blocks": o.blocks} for o in question.options],
            "unit": question.unit,
            "answer": answer_text,
            "answer_spec": answer_spec,
            "answer_key_raw": entry.raw if entry else None,
            "is_dropped": bool(entry.dropped) if entry else False,
            "marks": section.marks_correct if section else 1,
            "negative_marks": section.marks_incorrect if section else 0,
            "figures": placed,
            "solution": solution.solution if solution else "",
            "key_concept": solution.key_concept if solution else "",
            "chapter": solution.chapter if solution else "",
            "difficulty": solution.difficulty if solution else 0.5,
            #: "verified" | "needs_review" | "withheld" -- see Solution.status.
            #: Only "verified" solutions are shown to students on import.
            "solution_status": solution.status if solution else "withheld",
            "blind_answer": solution.blind_answer if solution else None,
            "agrees_with_key": solution.agrees_with_key if solution else None,
            "content_hash": content_hash(stem_text, option_texts),
            "plain_text": stem_text,
            "review": {
                "blocked": bool(verdict.blocked) if verdict else False,
                "flagged": bool(verdict.flagged) if verdict else False,
                "issues": issues,
            },
        })

    assets = {
        checksum: meta
        for checksum, meta in asset_manifest.items()
        if checksum in used_checksums
    }
    orphaned = sorted(set(asset_manifest) - used_checksums)

    publishable = [q for q in questions_out if not q["review"]["blocked"]]

    return {
        "format_version": FORMAT_VERSION,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "paper": {
            "key": identity.key,
            "exam_slug": identity.exam_slug,
            "exam_name": identity.exam_name,
            "year": identity.year,
            "session": identity.session,
            "shift": identity.shift,
            "paper_code": identity.paper_code,
            "held_on": identity.held_on,
            "source_label": identity.source_label,
            "source_pdf": source_pdf.name,
            "source_sha256": source_sha,
            "duration_minutes": profile.duration_minutes,
            "total_marks": profile.total_marks,
            "languages": profile.languages,
        },
        "sections": sections_out,
        "questions": questions_out,
        "assets": assets,
        "stats": {
            "questions_extracted": len(questions_out),
            "questions_publishable": len(publishable),
            "questions_blocked": len(questions_out) - len(publishable),
            "questions_flagged": sum(
                1 for q in questions_out if q["review"]["flagged"] and not q["review"]["blocked"]
            ),
            "figures_used": len(assets),
            "solutions_verified": sum(
                1 for q in questions_out if q["solution_status"] == "verified"
            ),
            "solutions_need_review": sum(
                1 for q in questions_out if q["solution_status"] == "needs_review"
            ),
            "solutions_withheld": sum(
                1 for q in questions_out if q["solution_status"] == "withheld"
            ),
            "figures_orphaned": orphaned,
            "key_disagreements": sorted(
                q["number"] for q in questions_out if q["agrees_with_key"] is False
            ),
            "models": models,
        },
    }


def write(document: dict, out_dir: Path) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    target = out_dir / "paper.json"
    target.write_text(
        json.dumps(document, ensure_ascii=False, indent=2, sort_keys=False),
        encoding="utf-8",
    )
    return target


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))
