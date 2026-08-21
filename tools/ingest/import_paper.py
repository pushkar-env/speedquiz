#!/usr/bin/env python
"""Load ingested papers into the database.

    python import_paper.py <paper-key> [...]      import specific papers
    python import_paper.py --all                  import everything in data/out
    python import_paper.py --all --publish        import and make them live
    python import_paper.py --all --dry-run        report, change nothing

Run `ingest.py` first -- this reads what that produced.

Safety: this connects to whatever DATABASE_URL points at, and in this repo that
is the live database. `--dry-run` rolls the transaction back at the end, and
without `--publish` nothing reaches students: papers land as `in_review` and
their questions as `pending`, which the gameplay dealer already filters out.
"""

from __future__ import annotations

import argparse
import asyncio
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(REPO_ROOT / "backend"))

from ingestlib.config import SETTINGS  # noqa: E402
from ingestlib.storage import build_store, upload_paper_assets  # noqa: E402


def _load_documents(keys: list[str], use_all: bool) -> list[tuple[str, dict, Path]]:
    import json

    found: list[tuple[str, dict, Path]] = []
    if use_all:
        paths = sorted(SETTINGS.out.glob("*/paper.json"))
    else:
        paths = [SETTINGS.out / key / "paper.json" for key in keys]

    for path in paths:
        if not path.exists():
            print(f"!! no ingested paper at {path}")
            continue
        document = json.loads(path.read_text(encoding="utf-8"))
        found.append((document["paper"]["key"], document, path.parent / "assets"))
    return found


async def main_async(args: argparse.Namespace) -> int:
    documents = _load_documents(args.key, args.all)
    if not documents:
        print("Nothing to import. Run `ingest.py run --all` first.")
        return 1

    from app.core.database import AsyncSessionLocal  # noqa: PLC0415
    from app.services.exam_import import import_paper  # noqa: PLC0415

    target = os.environ.get("DATABASE_URL", "")
    # Show enough to identify the host, never the password.
    redacted = target.split("@")[-1] if "@" in target else target
    print(f"database: ...@{redacted}")

    store = build_store(args.store)
    print(f"assets:   {store.describe()}")
    print(f"papers:   {len(documents)}")
    print(f"mode:     {'DRY RUN (rolled back)' if args.dry_run else 'commit'}"
          f"{' + PUBLISH' if args.publish else ''}\n")

    failures = 0
    for key, document, assets_dir in documents:
        stats = document.get("stats", {})
        print(f"[{key}]")
        print(f"  {stats.get('questions_extracted', 0)} questions, "
              f"{stats.get('figures_used', 0)} figures, "
              f"{stats.get('solutions_verified', 0)} verified solutions")

        try:
            asset_urls = upload_paper_assets(store, document, assets_dir)
            print(f"  assets uploaded: {getattr(store, 'written', 0)} new, "
                  f"{getattr(store, 'skipped', 0)} already present")

            async with AsyncSessionLocal() as session:
                report = await import_paper(
                    session,
                    document,
                    asset_urls=asset_urls,
                    publish=args.publish,
                )
                if args.dry_run:
                    await session.rollback()
                else:
                    await session.commit()
            print(f"  {report.summary()}")
            for warning in report.warnings[:10]:
                print(f"  ! {warning}")
        except Exception as error:
            failures += 1
            print(f"  !! failed: {type(error).__name__}: {error}")
            if args.traceback:
                import traceback
                traceback.print_exc()
        print()

    if failures:
        print(f"{failures} of {len(documents)} paper(s) failed")
        return 1
    if args.dry_run:
        print("Dry run complete -- nothing was written.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("key", nargs="*", help="paper keys to import")
    parser.add_argument("--all", action="store_true", help="every paper in data/out")
    parser.add_argument(
        "--publish", action="store_true",
        help="mark papers published and their questions active (visible to players)",
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="roll back instead of committing"
    )
    parser.add_argument("--store", help="asset store: local (default) or r2")
    parser.add_argument("--traceback", action="store_true")
    args = parser.parse_args()

    if not args.all and not args.key:
        parser.error("give one or more paper keys, or --all")
    return asyncio.run(main_async(args))


if __name__ == "__main__":
    sys.exit(main())
