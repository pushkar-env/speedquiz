"""Render a question's region to a single image for the vision pass.

A question that straddles a page break is still one question, so its slices are
stitched into one tall image rather than sent as two. The model then sees the
stem and its options together, which is the difference between "the options are
missing" and a correct extraction.
"""

from __future__ import annotations

import io
from pathlib import Path

import pymupdf
from PIL import Image

from .segment import QuestionRegion

#: A hairline between stitched page slices. Without it the last line of one
#: page and the first of the next abut, and the model reads them as one line.
SEAM_PX = 6
SEAM_COLOR = (214, 219, 224)
#: Long questions get scaled down rather than sent at full height; beyond this
#: the extra pixels cost tokens without adding legibility.
MAX_HEIGHT_PX = 2200


def render_region(
    doc: pymupdf.Document, region: QuestionRegion, *, dpi: int = 200
) -> bytes:
    """One PNG for the whole question, page breaks stitched."""
    scale = dpi / 72
    matrix = pymupdf.Matrix(scale, scale)

    tiles: list[Image.Image] = []
    for piece in region.slices:
        if piece.y1 - piece.y0 < 2:
            continue
        pixmap = doc[piece.page].get_pixmap(matrix=matrix, clip=piece.rect(), alpha=False)
        tiles.append(Image.open(io.BytesIO(pixmap.tobytes("png"))).convert("RGB"))

    if not tiles:
        raise ValueError(f"question {region.number} has no renderable area")

    if len(tiles) == 1:
        canvas = tiles[0]
    else:
        width = max(tile.width for tile in tiles)
        height = sum(tile.height for tile in tiles) + SEAM_PX * (len(tiles) - 1)
        canvas = Image.new("RGB", (width, height), (255, 255, 255))
        offset = 0
        for index, tile in enumerate(tiles):
            if index:
                seam = Image.new("RGB", (width, SEAM_PX), SEAM_COLOR)
                canvas.paste(seam, (0, offset))
                offset += SEAM_PX
            canvas.paste(tile, (0, offset))
            offset += tile.height

    if canvas.height > MAX_HEIGHT_PX:
        ratio = MAX_HEIGHT_PX / canvas.height
        canvas = canvas.resize(
            (max(1, int(canvas.width * ratio)), MAX_HEIGHT_PX), Image.LANCZOS
        )

    buffer = io.BytesIO()
    canvas.save(buffer, format="PNG", optimize=True)
    return buffer.getvalue()


def render_all(path: Path, regions: list[QuestionRegion], out_dir: Path, *, dpi: int = 200) -> dict[int, Path]:
    """Render every question once and cache the crops on disk.

    Crops are the input to the priciest stage, so they are kept: a re-run after
    a prompt change re-uses them, and a human reviewer can open the exact image
    the model was given.
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    doc = pymupdf.open(path)
    paths: dict[int, Path] = {}
    try:
        for region in regions:
            target = out_dir / f"q{region.number:03d}.png"
            if not target.exists():
                target.write_bytes(render_region(doc, region, dpi=dpi))
            paths[region.number] = target
    finally:
        doc.close()
    return paths
