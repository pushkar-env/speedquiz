"""Pull the diagrams out of the PDF and make them usable in both themes.

Two extraction paths, chosen per figure:

* **Embedded image** -- the PDF already carries the figure as a raster object.
  Take the original bytes at native resolution; re-encoding would only lose
  detail. This is the path every MathonGo/Allen-style paper takes.
* **Vector clip** -- the figure is drawn with path operators and has no image
  object. Render the region at `figure_dpi`. Born-digital official papers do
  this, and rendering keeps the result crisp where a screenshot would not.

Every figure is stored content-addressed (sha256 of the canonical bytes), which
makes re-ingesting a paper idempotent, dedupes a figure reused across shifts,
and lets the CDN cache it forever.
"""

from __future__ import annotations

import hashlib
import io
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

import numpy as np
import pymupdf
from PIL import Image

from .segment import PaperLayout, QuestionRegion

#: Figures smaller than this in either dimension are decorations -- bullet
#: glyphs, rule ornaments, the odd stray logo -- not content.
MIN_DIMENSION = 24
#: Below this area a "figure" is almost always an inline math glyph that the
#: renderer rasterised rather than a real diagram.
MIN_AREA = 2600
#: An image covering most of the page is a scan of the page, not a figure in it.
MAX_PAGE_FRACTION = 0.85


@dataclass
class Figure:
    #: sha256 of the canonical PNG bytes -- also the storage key.
    checksum: str
    question_number: int
    #: 1-based position within the question, in reading order. The vision pass
    #: refers to figures by this ("fig1", "fig2") when it places them.
    index: int
    width: int
    height: int
    page: int
    bbox: tuple[float, float, float, float]
    source: str  # "embedded" | "vector"
    light_bytes: bytes = field(repr=False, default=b"")
    dark_bytes: bytes = field(repr=False, default=b"")

    @property
    def ref(self) -> str:
        return f"fig{self.index}"

    def filename(self, variant: str) -> str:
        return f"{self.checksum}.{variant}.png"


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _to_png(data: bytes) -> tuple[bytes, int, int]:
    """Normalise to RGBA PNG so every downstream step sees one format."""
    with Image.open(io.BytesIO(data)) as image:
        image = image.convert("RGBA")
        buffer = io.BytesIO()
        image.save(buffer, format="PNG", optimize=True)
        return buffer.getvalue(), image.width, image.height


def make_dark_variant(png_bytes: bytes) -> bytes:
    """Flip lightness while keeping hue, so a diagram reads on a dark ground.

    A plain RGB inversion turns a red vector arrow cyan, which is worse than
    leaving it alone. Shifting every channel by the lightness delta instead
    keeps colour identity and relative contrast intact, and on the pure
    black-on-white line art that most diagrams are, it reduces to exactly the
    inversion you would have wanted anyway.

    Fully transparent pixels are left alone; a figure with an alpha channel is
    already theme-agnostic in its background.
    """
    with Image.open(io.BytesIO(png_bytes)) as image:
        rgba = np.asarray(image.convert("RGBA"), dtype=np.int16)

    rgb = rgba[..., :3]
    alpha = rgba[..., 3:]

    lightness = (rgb.max(axis=2, keepdims=True) + rgb.min(axis=2, keepdims=True)) // 2
    shifted = np.clip(rgb + (255 - 2 * lightness), 0, 255)

    out = np.concatenate([shifted, alpha], axis=2).astype(np.uint8)
    buffer = io.BytesIO()
    Image.fromarray(out, mode="RGBA").save(buffer, format="PNG", optimize=True)
    return buffer.getvalue()


def _region_for(layout: PaperLayout, page: int, y0: float, y1: float) -> Optional[QuestionRegion]:
    """Which question owns a box on this page.

    Matched on the vertical midpoint: a figure that overhangs a slice boundary
    by a few points still belongs to the question whose body it sits in.
    """
    midpoint = (y0 + y1) / 2
    for region in layout.regions:
        for piece in region.slices:
            if piece.page == page and piece.y0 - 4 <= midpoint <= piece.y1 + 4:
                return region
    return None


def _worth_keeping(width: int, height: int, rect, page_area: float) -> bool:
    if width < MIN_DIMENSION or height < MIN_DIMENSION:
        return False
    if width * height < MIN_AREA:
        return False
    if rect is not None and page_area and rect.get_area() / page_area > MAX_PAGE_FRACTION:
        return False
    return True


def extract(layout: PaperLayout, *, figure_dpi: int = 300) -> dict[int, list[Figure]]:
    """Every figure in the paper, grouped by question number."""
    doc = pymupdf.open(layout.path)
    found: dict[int, list[tuple[float, float, Figure]]] = {}

    try:
        for page_no in range(doc.page_count):
            if layout.answer_key_page is not None and page_no >= layout.answer_key_page:
                break
            page = doc[page_no]
            page_area = page.rect.get_area()

            for image_info in page.get_images(full=True):
                xref = image_info[0]
                try:
                    raw = doc.extract_image(xref)
                except Exception:
                    continue
                rects = page.get_image_rects(xref)
                if not rects:
                    continue
                rect = rects[0]
                if not _worth_keeping(raw["width"], raw["height"], rect, page_area):
                    continue

                region = _region_for(layout, page_no, rect.y0, rect.y1)
                if region is None:
                    continue

                try:
                    png, width, height = _to_png(raw["image"])
                except Exception:
                    continue

                figure = Figure(
                    checksum=_sha(png),
                    question_number=region.number,
                    index=0,
                    width=width,
                    height=height,
                    page=page_no,
                    bbox=(rect.x0, rect.y0, rect.x1, rect.y1),
                    source="embedded",
                    light_bytes=png,
                )
                found.setdefault(region.number, []).append((rect.y0, rect.x0, figure))
    finally:
        doc.close()

    # Reading order within a question: top to bottom, then left to right. That
    # is the order a candidate sees them, so fig1..figN mean something stable
    # to the vision pass and to a human reviewer looking at the same page.
    figures: dict[int, list[Figure]] = {}
    for number, items in found.items():
        items.sort(key=lambda item: (round(item[0], 1), round(item[1], 1)))
        ordered: list[Figure] = []
        for position, (_y, _x, figure) in enumerate(items, start=1):
            figure.index = position
            figure.dark_bytes = make_dark_variant(figure.light_bytes)
            ordered.append(figure)
        figures[number] = ordered
    return figures


def clip_region(
    path: Path, page_no: int, bbox: tuple[float, float, float, float], *, dpi: int = 300
) -> tuple[bytes, int, int]:
    """Render a rectangle of a page to PNG -- the vector-figure fallback."""
    doc = pymupdf.open(path)
    try:
        page = doc[page_no]
        matrix = pymupdf.Matrix(dpi / 72, dpi / 72)
        pixmap = page.get_pixmap(matrix=matrix, clip=pymupdf.Rect(*bbox), alpha=False)
        png = pixmap.tobytes("png")
    finally:
        doc.close()
    normalized, width, height = _to_png(png)
    return normalized, width, height


def write_all(figures: dict[int, list[Figure]], out_dir: Path) -> dict[str, dict]:
    """Write both variants of every figure and return an asset manifest."""
    out_dir.mkdir(parents=True, exist_ok=True)
    manifest: dict[str, dict] = {}
    for items in figures.values():
        for figure in items:
            light_path = out_dir / figure.filename("light")
            dark_path = out_dir / figure.filename("dark")
            if not light_path.exists():
                light_path.write_bytes(figure.light_bytes)
            if not dark_path.exists():
                dark_path.write_bytes(figure.dark_bytes)
            manifest[figure.checksum] = {
                "checksum": figure.checksum,
                "width": figure.width,
                "height": figure.height,
                "source": figure.source,
                "page": figure.page,
                "variants": {
                    "light": light_path.name,
                    "dark": dark_path.name,
                },
                "bytes": {
                    "light": len(figure.light_bytes),
                    "dark": len(figure.dark_bytes),
                },
            }
    return manifest
