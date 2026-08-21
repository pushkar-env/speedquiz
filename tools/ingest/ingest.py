#!/usr/bin/env python
"""Ingest exam PDFs into playable mock tests.

    python ingest.py run <file.pdf>     one paper
    python ingest.py run --all          every PDF in data/inbox that is new
    python ingest.py watch              keep watching data/inbox
    python ingest.py review <key>       what a human still needs to look at
    python ingest.py list               what has been ingested

Drop a PDF in `data/inbox` and run `run --all`. Everything else is derived:
the exam, year and shift come from the filename, the section structure and
marking scheme from the exam profile, the answers from the paper's own key.
"""

from __future__ import annotations

import argparse
import asyncio
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

# config loads the repo .env at import time, before SETTINGS is built.
from ingestlib import paper  # noqa: E402
from ingestlib.config import SETTINGS  # noqa: E402
from ingestlib.pipeline import run as run_pipeline  # noqa: E402


def find_pdfs(inbox: Path) -> list[Path]:
    return sorted(p for p in inbox.glob("*.pdf") if not p.name.startswith("."))


async def cmd_run(args: argparse.Namespace) -> int:
    settings = SETTINGS
    settings.ensure_dirs()

    if args.all:
        targets = find_pdfs(settings.inbox)
        if not targets:
            print(f"No PDFs in {settings.inbox}")
            print("Drop exam papers there and run again.")
            return 0
    else:
        targets = [Path(p).expanduser().resolve() for p in args.pdf]
        for target in targets:
            if not target.exists():
                print(f"!! not found: {target}")
                return 2

    print(f"{len(targets)} paper(s) to process\n")
    failures = 0
    for index, pdf in enumerate(targets, start=1):
        print(f"[{index}/{len(targets)}] {pdf.name}")
        try:
            result = await run_pipeline(
                pdf, settings,
                force=args.force,
                limit=args.limit,
                skip_solutions=args.no_solutions,
            )
            print(f"           {result.cache_stats} | {result.usage}")
        except KeyboardInterrupt:
            raise
        except Exception as error:
            failures += 1
            print(f"  !! failed: {type(error).__name__}: {error}")
            if args.traceback:
                import traceback
                traceback.print_exc()
        print()

    if failures:
        print(f"{failures} of {len(targets)} paper(s) failed")
    return 1 if failures else 0


def cmd_list(args: argparse.Namespace) -> int:
    settings = SETTINGS
    settings.ensure_dirs()
    found = sorted(settings.out.glob("*/paper.json"))
    if not found:
        print("Nothing ingested yet.")
        return 0
    print(f"{'PAPER':<36} {'Q':>4} {'PUB':>4} {'FLAG':>5} {'BLOCK':>6} {'FIGS':>5}")
    for path in found:
        document = paper.load(path)
        stats = document["stats"]
        print(f"{document['paper']['key']:<36} "
              f"{stats['questions_extracted']:>4} "
              f"{stats['questions_publishable']:>4} "
              f"{stats['questions_flagged']:>5} "
              f"{stats['questions_blocked']:>6} "
              f"{stats['figures_used']:>5}")
    return 0


def cmd_review(args: argparse.Namespace) -> int:
    settings = SETTINGS
    path = settings.out / args.key / "paper.json"
    if not path.exists():
        print(f"!! no ingested paper with key {args.key!r}")
        return 2
    document = paper.load(path)

    needs = [q for q in document["questions"] if q["review"]["flagged"]]
    if not needs:
        print(f"{args.key}: nothing flagged, all {len(document['questions'])} questions clean.")
        return 0

    print(f"{args.key}: {len(needs)} of {len(document['questions'])} questions need a look\n")
    for question in needs:
        marker = "BLOCKED" if question["review"]["blocked"] else "flagged"
        print(f"Q{question['number']:>3} [{marker}] {question['subject'] or ''} "
              f"({question['answer_type']}) key={question['answer_key_raw']!r}")
        for issue in question["review"]["issues"]:
            print(f"      {issue['severity']:<5} {issue['code']}"
                  + (f" -- {issue['detail']}" if issue.get("detail") else ""))
        if args.verbose:
            print(f"      text: {question['plain_text'][:200]}")
        print()
    return 0


async def cmd_watch(args: argparse.Namespace) -> int:
    settings = SETTINGS
    settings.ensure_dirs()
    print(f"Watching {settings.inbox}")
    print("Drop PDFs in. Ctrl-C to stop.\n")
    seen: set[Path] = set()
    while True:
        for pdf in find_pdfs(settings.inbox):
            if pdf in seen:
                continue
            # Wait for the copy to finish: a file still being written reports a
            # growing size, and parsing half a PDF fails in confusing ways.
            size = -1
            while size != pdf.stat().st_size:
                size = pdf.stat().st_size
                await asyncio.sleep(1.0)
            seen.add(pdf)
            print(f"--> {pdf.name}")
            try:
                result = await run_pipeline(pdf, settings)
                print(f"           {result.cache_stats} | {result.usage}")
            except Exception as error:
                print(f"  !! failed: {type(error).__name__}: {error}")
            print()
        await asyncio.sleep(args.interval)


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="ingest",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    run_parser = subparsers.add_parser("run", help="ingest one or more PDFs")
    run_parser.add_argument("pdf", nargs="*", help="paths to PDF files")
    run_parser.add_argument("--all", action="store_true", help="every new PDF in data/inbox")
    run_parser.add_argument("--force", action="store_true", help="re-ingest even if unchanged")
    run_parser.add_argument("--limit", type=int, help="only the first N questions (for testing)")
    run_parser.add_argument("--no-solutions", action="store_true",
                            help="skip the solve stage (extraction only, much cheaper)")
    run_parser.add_argument("--traceback", action="store_true", help="full traceback on failure")

    subparsers.add_parser("list", help="what has been ingested")

    review_parser = subparsers.add_parser("review", help="questions needing human review")
    review_parser.add_argument("key", help="paper key, e.g. jee-main-2025-january-shift1")
    review_parser.add_argument("-v", "--verbose", action="store_true")

    watch_parser = subparsers.add_parser("watch", help="watch data/inbox for new PDFs")
    watch_parser.add_argument("--interval", type=float, default=5.0)

    args = parser.parse_args()

    if args.command == "run":
        if not args.all and not args.pdf:
            run_parser.error("give a PDF path or --all")
        return asyncio.run(cmd_run(args))
    if args.command == "list":
        return cmd_list(args)
    if args.command == "review":
        return cmd_review(args)
    if args.command == "watch":
        try:
            return asyncio.run(cmd_watch(args))
        except KeyboardInterrupt:
            print("\nstopped")
            return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
