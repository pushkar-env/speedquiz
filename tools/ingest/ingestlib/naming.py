"""Work out which paper a PDF *is*, from its filename.

Filenames in the wild are inconsistent, so this is best-effort with an
explicit escape hatch: drop `<same-name>.meta.json` beside the PDF and its
keys win outright. That keeps the happy path zero-config without making an
oddly-named file unusable.
"""

from __future__ import annotations

import json
import re
from dataclasses import asdict, dataclass
from datetime import date
from pathlib import Path
from typing import Optional

MONTHS = {
    "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3,
    "apr": 4, "april": 4, "may": 5, "jun": 6, "june": 6, "jul": 7, "july": 7,
    "aug": 8, "august": 8, "sep": 9, "sept": 9, "september": 9, "oct": 10,
    "october": 10, "nov": 11, "november": 11, "dec": 12, "december": 12,
}

#: Ordered — the first pattern that matches wins, so the more specific exam
#: names have to come first ("jee advanced" before "jee main").
EXAM_PATTERNS: list[tuple[str, str, str]] = [
    (r"jee\s*[-_ ]?adv", "jee-advanced", "JEE Advanced"),
    (r"jee\s*[-_ ]?main", "jee-main", "JEE Main"),
    (r"\bneet\b", "neet-ug", "NEET UG"),
    (r"\bgate\b", "gate", "GATE"),
    (r"\bbitsat\b", "bitsat", "BITSAT"),
    (r"\bwbjee\b", "wbjee", "WBJEE"),
    (r"\bcuet\b", "cuet-ug", "CUET UG"),
]


@dataclass
class PaperIdentity:
    exam_slug: str
    exam_name: str
    year: int
    #: "january" / "april" for JEE Main's two sessions; None where the exam
    #: runs once a year.
    session: Optional[str] = None
    #: 1 or 2. None for exams that do not run shifts.
    shift: Optional[int] = None
    #: GATE's branch code (cs, me, ee...) or a JEE Advanced paper number.
    paper_code: Optional[str] = None
    held_on: Optional[str] = None
    source_label: Optional[str] = None

    @property
    def key(self) -> str:
        """Stable identity. Re-ingesting the same paper must land on this."""
        bits = [self.exam_slug, str(self.year)]
        if self.session:
            bits.append(self.session)
        if self.shift:
            bits.append(f"shift{self.shift}")
        if self.paper_code:
            bits.append(str(self.paper_code).lower())
        return "-".join(bits)

    def as_dict(self) -> dict:
        return asdict(self)


def _match_exam(text: str) -> tuple[str, str]:
    for pattern, slug, name in EXAM_PATTERNS:
        if re.search(pattern, text, re.I):
            return slug, name
    return "unknown", "Unknown Exam"


def parse_filename(path: Path) -> PaperIdentity:
    """Derive a paper identity from the filename, then let a sidecar override."""
    stem = path.stem
    flat = re.sub(r"[_]+", " ", stem)

    exam_slug, exam_name = _match_exam(flat)

    years = [int(y) for y in re.findall(r"\b((?:19|20)\d{2})\b", flat)]
    year = max(years) if years else 0

    session = None
    if re.search(r"\bjan(uary)?\b", flat, re.I):
        session = "january"
    elif re.search(r"\bapr(il)?\b", flat, re.I):
        session = "april"
    elif re.search(r"\bmay\b", flat, re.I):
        session = "may"

    shift = None
    m = re.search(r"shift\s*[-_ ]?(\d)", flat, re.I)
    if m:
        shift = int(m.group(1))

    paper_code = None
    m = re.search(r"\bpaper\s*[-_ ]?(\d)\b", flat, re.I)
    if m:
        paper_code = f"paper{m.group(1)}"
    if exam_slug == "gate":
        m = re.search(r"\bgate\b[^A-Za-z]*(?:\d{4})?[^A-Za-z]*([A-Z]{2,3})\b", stem)
        if m:
            paper_code = m.group(1).lower()

    held_on = None
    m = re.search(r"\b(\d{1,2})\s+([A-Za-z]{3,9})\b", flat)
    if m and year:
        month = MONTHS.get(m.group(2).lower())
        if month:
            try:
                held_on = date(year, month, int(m.group(1))).isoformat()
            except ValueError:
                held_on = None

    source_label = None
    m = re.search(r"-\s*([A-Za-z][A-Za-z0-9 ]{2,30})$", stem)
    if m:
        source_label = m.group(1).strip()

    identity = PaperIdentity(
        exam_slug=exam_slug,
        exam_name=exam_name,
        year=year,
        session=session,
        shift=shift,
        paper_code=paper_code,
        held_on=held_on,
        source_label=source_label,
    )

    sidecar = path.with_suffix(".meta.json")
    if sidecar.exists():
        overrides = json.loads(sidecar.read_text(encoding="utf-8"))
        for field_name, value in overrides.items():
            if hasattr(identity, field_name):
                setattr(identity, field_name, value)

    return identity
