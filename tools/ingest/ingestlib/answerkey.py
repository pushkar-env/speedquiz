"""Parse the printed answer key.

The key is ground truth. Nothing downstream is allowed to overrule it -- when
the vision pass or the solver disagrees with the key, that raises a review flag
rather than picking a winner (see gates.py).

Papers print keys in a few shapes:

    1. (4)      2. (3)          <- bracketed option index, the common one
    1. 4        2. 3
    1. A        2. C            <- lettered options
    21. (2035)                  <- a numerical answer, in the same notation

The ambiguity in the last case is real and unresolvable from the key alone:
"47. (4)" is option 4 in a multiple-choice section and the value 4 in a
numerical one. Which it is comes from the section profile, not from here.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

import pymupdf

#: "12. (4)" / "12. 4" / "12) A" / "12. -0.5"
ENTRY = re.compile(
    r"(?<![\d.])(\d{1,3})\s*[.)]\s*\(?\s*([A-Da-d]|-?\d+(?:\.\d+)?(?:\s*to\s*-?\d+(?:\.\d+)?)?)\s*\)?"
)
LETTERS = {"a": 1, "b": 2, "c": 3, "d": 4}


@dataclass
class KeyEntry:
    number: int
    #: Exactly as printed, before any interpretation.
    raw: str
    #: 1-based option index when the key names an option; None otherwise.
    option: Optional[int] = None
    #: Parsed value when the key is numeric. Note that a bare "3" sets *both*
    #: `option` and `value` -- the section profile decides which one is real.
    value: Optional[float] = None
    #: GATE-style accepted ranges ("1.4 to 1.6").
    value_low: Optional[float] = None
    value_high: Optional[float] = None
    #: Set when the paper marks a question as dropped or awarded to all.
    dropped: bool = False


def _parse_entry(number: int, raw: str) -> KeyEntry:
    entry = KeyEntry(number=number, raw=raw.strip())
    token = entry.raw.lower()

    if token in LETTERS:
        entry.option = LETTERS[token]
        return entry

    range_match = re.match(r"^(-?\d+(?:\.\d+)?)\s*to\s*(-?\d+(?:\.\d+)?)$", token)
    if range_match:
        entry.value_low = float(range_match.group(1))
        entry.value_high = float(range_match.group(2))
        entry.value = (entry.value_low + entry.value_high) / 2
        return entry

    try:
        entry.value = float(token)
    except ValueError:
        return entry

    # A small positive integer could be an option index. Recording both and
    # letting the profile choose is the only honest reading.
    if entry.value.is_integer() and 1 <= entry.value <= 4:
        entry.option = int(entry.value)
    return entry


def parse_page(path: Path, page_no: int) -> dict[int, KeyEntry]:
    doc = pymupdf.open(path)
    try:
        text = doc[page_no].get_text("text")
    finally:
        doc.close()
    return parse_text(text)


def parse_text(text: str) -> dict[int, KeyEntry]:
    """Extract every `<number>. <answer>` pair, keeping the last for duplicates."""
    entries: dict[int, KeyEntry] = {}
    for match in ENTRY.finditer(text):
        number = int(match.group(1))
        if not 1 <= number <= 400:
            continue
        entries[number] = _parse_entry(number, match.group(2))

    if re.search(r"\b(dropped|bonus|awarded to all)\b", text, re.I):
        # Papers that annotate dropped questions do so beside the entry; flag
        # them so the gate can surface it rather than silently scoring them.
        for line in text.splitlines():
            if re.search(r"\b(dropped|bonus|awarded to all)\b", line, re.I):
                head = re.match(r"\s*(\d{1,3})\s*[.)]", line)
                if head and int(head.group(1)) in entries:
                    entries[int(head.group(1))].dropped = True
    return entries
