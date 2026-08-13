#!/usr/bin/env python3
"""Turn the local .env into a Railway-ready variable block.

A local .env is not a production config. Some keys only drive the local Docker
containers, some carry development values that the app now refuses to boot
with, and some required keys are absent because local defaults covered them.

This reads .env, applies those differences, and then validates the result
against the app's real Settings model - so if it prints a block, that block
boots.

Usage:
    python scripts/railway_env.py
    python scripts/railway_env.py --public-url https://api-production-xxxx.up.railway.app
"""

from __future__ import annotations

import argparse
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent

# Only configure the local docker-compose Postgres container. On Railway the
# database is Neon, reached through DATABASE_URL, so these are dead weight.
LOCAL_ONLY = {"POSTGRES_USER", "POSTGRES_PASSWORD", "POSTGRES_DB"}

# Compiled into the Flutter binary by scripts/build_android.sh, not read by the
# server at all. They live in the same .env for convenience; putting them on
# Railway would imply the backend reads them, which is the kind of thing
# somebody later tries to "fix" by changing the wrong one.
CLIENT_BUILD_ONLY = {
    "FIREBASE_API_KEY",
    "FIREBASE_APP_ID",
    "FIREBASE_PROJECT_ID",
    "FIREBASE_SENDER_ID",
    "GOOGLE_CLIENT_ID",
}

# Development values the production validator rejects.
PRODUCTION_OVERRIDES = {
    "APP_ENV": "production",
    "DEBUG": "false",
}

# Absent locally because the defaults are fine there; worth being explicit
# about in a deployment.
PRODUCTION_ADDITIONS = {
    "WEB_CONCURRENCY": "2",
    "ENTITLEMENTS_DEV_TOGGLE": "false",
    "BILLING_VERIFY_MODE": "stub",
    "BILLING_ALLOW_STUB_IN_PRODUCTION": "false",
    "ANALYTICS_PROVIDER": "postgres",
    "APP_LINK_ANDROID_PACKAGE": "com.speedquiz.app",
}

# Needed by both services: the API generates custom topics and "Teach me"
# explanations on demand; the worker tops up the question bank.
#
# FCM_SERVICE_ACCOUNT_JSON is on this list because push is sent from both — the
# API on a challenge or friend request, and the **worker** when its sweep
# settles an expired async match and has to tell both players. Setting it only
# on the API loses exactly the notifications that matter most, and loses them
# silently, since a missing credential is a supported "push disabled" state.
BOTH_SERVICES = {
    "LLM_API_KEY",
    "DATABASE_URL",
    "DATABASE_URL_SYNC",
    "REDIS_URL",
    "FCM_SERVICE_ACCOUNT_JSON",
}


def read_env(path: pathlib.Path) -> dict[str, str]:
    if not path.exists():
        sys.exit(f"error: {path} not found")
    out: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        out[key.strip()] = value.strip()
    return out


def build(env: dict[str, str], public_url: str | None) -> tuple[dict[str, str], list[str]]:
    warnings: list[str] = []
    out = {
        k: v
        for k, v in env.items()
        if k not in LOCAL_ONLY and k not in CLIENT_BUILD_ONLY
    }

    for key, value in PRODUCTION_OVERRIDES.items():
        if out.get(key) not in (None, value):
            warnings.append(f"{key}: '{out[key]}' -> '{value}'")
        out[key] = value

    for key, value in PRODUCTION_ADDITIONS.items():
        out.setdefault(key, value)

    if public_url:
        out["SHARE_PUBLIC_BASE_URL"] = public_url.rstrip("/")
    elif not out.get("SHARE_PUBLIC_BASE_URL"):
        warnings.append(
            "SHARE_PUBLIC_BASE_URL is unset - share links will omit the web "
            "URL. Re-run with --public-url once Railway gives you a domain."
        )

    if "localhost" in out.get("DATABASE_URL", "") or "@postgres:" in out.get(
        "DATABASE_URL", ""
    ):
        warnings.append(
            "DATABASE_URL still points at a local database - Railway cannot "
            "reach it. Use the Neon URL (see scripts/split_db_url.py)."
        )
    if out.get("REDIS_URL", "").startswith("redis://") and "localhost" not in out.get(
        "REDIS_URL", ""
    ):
        warnings.append(
            "REDIS_URL uses redis:// against a remote host - managed Redis "
            "requires TLS. Use rediss:// (two s)."
        )

    return out, warnings


def validate(values: dict[str, str]) -> str | None:
    """Run the block through the real Settings model."""
    sys.path.insert(0, str(REPO / "backend"))
    try:
        from app.core.config import Settings
    except Exception as exc:  # pragma: no cover - depends on local venv
        return f"could not import Settings ({exc}); skipped validation"

    try:
        # _env_file=None so the local .env cannot mask a missing value.
        Settings(_env_file=None, **{k.lower(): v for k, v in values.items()})
    except Exception as exc:
        return str(exc)
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--env-file", default=str(REPO / ".env"))
    parser.add_argument(
        "--public-url",
        help="Railway domain, e.g. https://api-production-xxxx.up.railway.app",
    )
    args = parser.parse_args()

    env = read_env(pathlib.Path(args.env_file))
    values, warnings = build(env, args.public_url)

    error = validate(values)
    if error:
        print("This config would NOT boot on Railway:\n", file=sys.stderr)
        print(error, file=sys.stderr)
        return 1

    print("# ---------------------------------------------------------------")
    print("# Paste into Railway -> Variables -> Raw Editor, on BOTH services")
    print("# (api and worker). Validated against app.core.config.Settings.")
    print("# ---------------------------------------------------------------")
    for key in sorted(values):
        print(f"{key}={values[key]}")

    print()
    print(f"# {len(values)} variables. Dropped local-only: {', '.join(sorted(LOCAL_ONLY))}")
    print(f"# Required on both services: {', '.join(sorted(BOTH_SERVICES))}")

    if warnings:
        print("\n# WARNINGS", file=sys.stderr)
        for w in warnings:
            print(f"#   - {w}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
