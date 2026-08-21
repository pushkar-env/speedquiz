"""Deterministic layout pass: where every question starts and stops.

No model is involved here. Question boundaries, the printable content band and
the answer-key page are all recoverable from the PDF's own text geometry, and
anything recoverable deterministically should be -- a model that never sees a
question boundary can never get one wrong.
"""

from __future__ import annotations

import re
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterator, Optional

import pymupdf

#: "Q12." at the start of a line. Some sources run the number straight into the
#: text ("Q12.Let x be..."), which is why there is no trailing whitespace class.
Q_MARKER = re.compile(r"^Q\s*(\d{1,3})\s*[.):]")
#: Fallback for papers that number without the Q ("12. Let x be...").
BARE_MARKER = re.compile(r"^(\d{1,3})\s*[.)]\s+\S")
ANSWER_KEY_HEADING = re.compile(r"answer\s*keys?", re.I)

#: A text row must repeat on at least this share of pages to count as running
#: header/footer furniture rather than content.
FURNITURE_SHARE = 0.6
#: Rounding for the y-coordinate when deciding whether two rows are "the same
#: row on different pages". Renderers drift by a fraction of a point.
Y_BUCKET = 2.0


@dataclass
class Slice:
    """One page's worth of a question's region, in PDF points."""

    page: int
    y0: float
    y1: float
    x0: float
    x1: float

    def rect(self) -> pymupdf.Rect:
        return pymupdf.Rect(self.x0, self.y0, self.x1, self.y1)


@dataclass
class QuestionRegion:
    number: int
    slices: list[Slice] = field(default_factory=list)
    #: Raw text in reading order. Useful for gates and for the text-only
    #: fallback when a crop cannot be rendered; not the final content.
    raw_text: str = ""

    @property
    def pages(self) -> list[int]:
        return [s.page for s in self.slices]


@dataclass
class PaperLayout:
    path: Path
    page_count: int
    content_top: float
    content_bottom: float
    content_left: float
    content_right: float
    regions: list[QuestionRegion]
    answer_key_page: Optional[int]
    furniture: list[str]


def _spans(page: pymupdf.Page) -> Iterator[tuple[str, tuple, str, float]]:
    for block in page.get_text("dict")["blocks"]:
        if block.get("type") != 0:
            continue
        for line in block["lines"]:
            for span in line["spans"]:
                text = span["text"]
                if text.strip():
                    yield text, tuple(span["bbox"]), span["font"], span["size"]


def _detect_furniture(doc: pymupdf.Document) -> tuple[set, list[str]]:
    """Rows of text that repeat at the same height on most pages.

    Running headers and footers are content-shaped -- they are real text spans
    -- so the only thing that distinguishes them is that they say the same
    thing in the same place on every page.
    """
    seen: Counter = Counter()
    for page in doc:
        rows = set()
        for text, bbox, _font, _size in _spans(page):
            rows.add((text.strip(), round(bbox[1] / Y_BUCKET) * Y_BUCKET))
        for row in rows:
            seen[row] += 1

    threshold = max(2, int(doc.page_count * FURNITURE_SHARE))
    furniture = {row for row, count in seen.items() if count >= threshold}
    return furniture, sorted({text for text, _ in furniture})


def _content_band(doc: pymupdf.Document, furniture: set) -> tuple[float, float]:
    """The vertical strip that actually holds questions."""
    height = doc[0].rect.height
    top_candidates = [y for _text, y in furniture if y < height * 0.2]
    bottom_candidates = [y for _text, y in furniture if y > height * 0.85]

    # +14 clears the descenders of the last furniture row; the fallback margins
    # are deliberately generous because cropping into a question is far worse
    # than carrying a stripe of white space into the model.
    content_top = (max(top_candidates) + 14) if top_candidates else height * 0.06
    content_bottom = (min(bottom_candidates) - 6) if bottom_candidates else height * 0.95
    return content_top, content_bottom


def _marker_number(text: str) -> Optional[int]:
    match = Q_MARKER.match(text.strip())
    return int(match.group(1)) if match else None


def _find_markers(
    doc: pymupdf.Document,
    furniture: set,
    content_top: float,
    content_bottom: float,
) -> list[tuple[int, int, float, float]]:
    """(question_number, page, y_top, x_left) for every question marker found.

    Markers are matched on the first span of a line, which is what keeps a
    mid-sentence back-reference inside another question's body from opening a
    spurious region.
    """
    markers: list[tuple[int, int, float, float]] = []
    for page_no, page in enumerate(doc):
        for block in page.get_text("dict")["blocks"]:
            if block.get("type") != 0:
                continue
            for line in block["lines"]:
                spans = line["spans"]
                if not spans:
                    continue
                y_top = line["bbox"][1]
                if y_top < content_top - 4 or y_top > content_bottom:
                    continue
                if (spans[0]["text"].strip(), round(y_top / Y_BUCKET) * Y_BUCKET) in furniture:
                    continue
                number = _marker_number(spans[0]["text"])
                if number is None:
                    # Some renderers split "Q" and "12." across two spans.
                    number = _marker_number("".join(s["text"] for s in spans[:2]))
                if number is not None:
                    markers.append((number, page_no, y_top, line["bbox"][0]))

    markers.sort(key=lambda m: (m[1], m[2]))

    # Keep only a monotonically increasing run. A stray line that happens to
    # read like a low question number after question 40 is noise, and dropping
    # it here is cheaper than reasoning about it downstream.
    kept: list[tuple[int, int, float, float]] = []
    for marker in markers:
        if not kept or marker[0] > kept[-1][0]:
            kept.append(marker)
    return kept


def _text_in(page: pymupdf.Page, rect: pymupdf.Rect, furniture: set) -> str:
    out: list[str] = []
    for text, bbox, _font, _size in _spans(page):
        if bbox[1] < rect.y0 - 2 or bbox[3] > rect.y1 + 2:
            continue
        if (text.strip(), round(bbox[1] / Y_BUCKET) * Y_BUCKET) in furniture:
            continue
        out.append(text)
    return " ".join(out).strip()


def analyze(path: Path) -> PaperLayout:
    """Segment a paper. Cheap, deterministic, and safe to re-run."""
    doc = pymupdf.open(path)
    furniture, furniture_text = _detect_furniture(doc)
    content_top, content_bottom = _content_band(doc, furniture)

    page_rect = doc[0].rect
    content_left = page_rect.width * 0.04
    content_right = page_rect.width * 0.97

    answer_key_page = None
    for page_no, page in enumerate(doc):
        if ANSWER_KEY_HEADING.search(page.get_text("text")[:400]):
            answer_key_page = page_no
            break

    last_content_page = (answer_key_page - 1) if answer_key_page is not None else doc.page_count - 1
    markers = [
        m for m in _find_markers(doc, furniture, content_top, content_bottom)
        if m[1] <= last_content_page
    ]

    regions: list[QuestionRegion] = []
    for index, (number, page_no, y_top, _x) in enumerate(markers):
        if index + 1 < len(markers):
            _next_number, next_page, next_y, _nx = markers[index + 1]
        else:
            next_page, next_y = last_content_page, content_bottom

        slices: list[Slice] = []
        # -3 lifts the crop just above the marker's own ascenders.
        start_y = max(content_top, y_top - 3)
        if next_page == page_no:
            slices.append(
                Slice(page_no, start_y, max(start_y, next_y - 2), content_left, content_right)
            )
        else:
            slices.append(Slice(page_no, start_y, content_bottom, content_left, content_right))
            for mid in range(page_no + 1, next_page):
                slices.append(Slice(mid, content_top, content_bottom, content_left, content_right))
            if next_y - 2 > content_top:
                slices.append(
                    Slice(next_page, content_top, next_y - 2, content_left, content_right)
                )

        raw = " ".join(_text_in(doc[s.page], s.rect(), furniture) for s in slices).strip()
        regions.append(QuestionRegion(number=number, slices=slices, raw_text=raw))

    layout = PaperLayout(
        path=path,
        page_count=doc.page_count,
        content_top=content_top,
        content_bottom=content_bottom,
        content_left=content_left,
        content_right=content_right,
        regions=regions,
        answer_key_page=answer_key_page,
        furniture=furniture_text,
    )
    doc.close()
    return layout
