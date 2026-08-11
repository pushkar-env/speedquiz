#!/usr/bin/env python3
"""Turn one Neon/Postgres connection string into the two SpeedQuiz needs.

The app runs async (asyncpg) and Alembic runs sync (psycopg), and SQLAlchemy
picks its driver from the URL scheme — so the same database is referenced by
two URLs that differ only in the driver.

asyncpg additionally rejects libpq query parameters like `sslmode` and
`channel_binding`: SQLAlchemy forwards them verbatim to `asyncpg.connect()`,
which has no such keyword and no **kwargs, so you get
`TypeError: connect() got an unexpected keyword argument 'sslmode'` at connect
time. They are stripped here. TLS still happens; asyncpg negotiates it itself.

Usage:
    python scripts/split_db_url.py "postgresql://user:pass@host/db?sslmode=require"

Or pipe it in so the secret stays out of your shell history:
    python scripts/split_db_url.py
"""

from __future__ import annotations

import sys
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

# libpq options that asyncpg does not accept as keyword arguments.
ASYNCPG_UNSUPPORTED = {
    "sslmode",
    "channel_binding",
    "sslrootcert",
    "sslcert",
    "sslkey",
    "target_session_attrs",
    "options",
}


def _with_scheme(parts, scheme: str, query: str) -> str:
    return urlunsplit((scheme, parts.netloc, parts.path, query, parts.fragment))


def split(raw: str) -> tuple[str, str]:
    raw = raw.strip().strip('"').strip("'")
    if not raw:
        raise ValueError("empty connection string")

    parts = urlsplit(raw)
    if not parts.scheme.startswith("postgres"):
        raise ValueError(
            f"expected a postgresql:// URL, got scheme {parts.scheme!r}"
        )
    if not parts.netloc or not parts.path.strip("/"):
        raise ValueError("connection string is missing a host or database name")

    params = parse_qsl(parts.query, keep_blank_values=True)
    async_query = urlencode(
        [(k, v) for k, v in params if k.lower() not in ASYNCPG_UNSUPPORTED]
    )

    return (
        _with_scheme(parts, "postgresql+asyncpg", async_query),
        _with_scheme(parts, "postgresql+psycopg", parts.query),
    )


def main() -> int:
    if len(sys.argv) > 2:
        print(__doc__)
        return 2

    raw = sys.argv[1] if len(sys.argv) == 2 else sys.stdin.read()

    try:
        async_url, sync_url = split(raw)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    pooled = "-pooler." in async_url
    print("# --- paste into Railway (api + worker) Variables ---")
    print(f"DATABASE_URL={async_url}")
    print(f"DATABASE_URL_SYNC={sync_url}")
    print(f"DB_DISABLE_PREPARED_STATEMENTS={'true' if pooled else 'false'}")
    print()

    if pooled:
        print("# Pooled endpoint detected (-pooler): prepared statements disabled,")
        print("# which is required for transaction-mode pooling.")
    else:
        print("# WARNING: this is a DIRECT endpoint, not a pooled one.")
        print("# In Neon, enable 'Connection pooling' and copy the -pooler host")
        print("# instead. Otherwise every app connection is a real Postgres")
        print("# backend process and you will hit max_connections under load.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
