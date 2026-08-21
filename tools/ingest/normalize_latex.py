#!/usr/bin/env python
"""Re-canonicalise the maths in questions already in the database.

    python normalize_latex.py --dry-run     report what would change
    python normalize_latex.py               apply it

Import now normalises on the way in, so this is only for rows written before
that existed. It is idempotent and safe to run repeatedly: normalising already
normalised content is a no-op.

Scoped to exam questions (those carrying `generation_meta.source ==
"exam_ingest"`), because the rest of the bank was never written with LaTeX in
it and there is nothing to gain from rewriting it.
"""

from __future__ import annotations

import argparse
import asyncio
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(REPO_ROOT / "backend"))

from ingestlib.config import SETTINGS  # noqa: E402,F401  (loads the repo .env)


async def main_async(args: argparse.Namespace) -> int:
    from sqlalchemy import select  # noqa: PLC0415
    from sqlalchemy.orm import selectinload  # noqa: PLC0415

    from app.core.database import AsyncSessionLocal  # noqa: PLC0415
    from app.models import ExamQuestion, Question  # noqa: PLC0415
    from app.services.latex_normalize import (  # noqa: PLC0415
        normalize_blocks,
        normalize_text,
    )

    async with AsyncSessionLocal() as db:
        links = (
            await db.execute(
                select(ExamQuestion)
                .options(selectinload(ExamQuestion.question))
                .order_by(ExamQuestion.question_number)
            )
        ).scalars().all()

        print(f"{len(links)} exam questions in the database\n")

        changed = 0
        warnings: list[str] = []
        for link in links:
            question: Question = link.question
            if question is None:
                continue

            content = question.content or {}
            blocks, report = normalize_blocks(content.get("blocks") or [])

            option_content = []
            for option_blocks in question.option_content or []:
                fixed, sub = normalize_blocks(option_blocks or [])
                report.merge(sub)
                option_content.append(fixed)

            explanation, sub = normalize_text(question.explanation or "")
            report.merge(sub)

            if not report.changed and explanation == (question.explanation or ""):
                continue

            changed += 1
            print(f"Q{link.question_number}: "
                  f"{report.delimiters_converted} delimiter(s), "
                  f"{report.runs_wrapped} wrapped")
            if args.verbose:
                for before, after in zip(content.get("blocks") or [], blocks):
                    if before.get("v") != after.get("v"):
                        print(f"    - {str(before.get('v'))[:100]}")
                        print(f"    + {str(after.get('v'))[:100]}")
                for before_opt, after_opt in zip(
                    question.option_content or [], option_content
                ):
                    for before, after in zip(before_opt or [], after_opt):
                        if before.get("v") != after.get("v"):
                            print(f"    - {str(before.get('v'))[:100]}")
                            print(f"    + {str(after.get('v'))[:100]}")
            warnings.extend(f"Q{link.question_number}: {n}" for n in report.notes)

            if not args.dry_run:
                question.content = {**content, "blocks": blocks}
                question.option_content = option_content
                question.explanation = explanation
                # The flat prompt feeds search and dedup; keep it in step.
                question.prompt = " ".join(
                    str(b.get("v", "")) for b in blocks if b.get("t") == "text"
                ).strip() or question.prompt

        print(f"\n{changed} question(s) {'would change' if args.dry_run else 'changed'}")
        for warning in warnings[:20]:
            print(f"  ! {warning}")

        if args.dry_run:
            await db.rollback()
            print("Dry run -- nothing was written.")
        else:
            await db.commit()
            print("Committed.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("-v", "--verbose", action="store_true")
    return asyncio.run(main_async(parser.parse_args()))


if __name__ == "__main__":
    sys.exit(main())
