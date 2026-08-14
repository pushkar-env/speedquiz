#!/usr/bin/env python
"""Check that push is actually wired up, before trusting it in production.

Push fails quietly by design — a bad service account, a project id mismatch or
a missing dart-define all produce "no notification arrived", which is
indistinguishable from "nobody sent one". This script turns each of those into
a specific error.

    python scripts/verify_push.py                      # check config + credentials
    python scripts/verify_push.py --token <FCM>        # also send a real test push
    python scripts/verify_push.py --from-file <path>   # turn a downloaded key into .env lines

Get a device token by running the app with the FIREBASE_* defines and reading
the logcat line that `PushService` prints, or by querying:

    SELECT token, platform FROM device_tokens WHERE is_active ORDER BY created_at DESC LIMIT 5;
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "backend"))

OK, BAD, WARN = "  [ok]  ", "  [FAIL]", "  [warn]"

#: Everything the Flutter side needs. All four or none — a partial set builds
#: an app that silently never registers for push.
DART_DEFINES = (
    "FIREBASE_API_KEY",
    "FIREBASE_APP_ID",
    "FIREBASE_PROJECT_ID",
    "FIREBASE_SENDER_ID",
)


def read_env() -> dict[str, str]:
    """Parse the root .env without importing pydantic settings."""
    env_path = REPO_ROOT / ".env"
    if not env_path.exists():
        return {}
    values: dict[str, str] = {}
    for line in env_path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip()
    return values


def check_service_account(raw: str) -> tuple[bool, str | None]:
    """Validate the JSON blob and report the project it belongs to."""
    if not raw:
        print(f"{WARN} FCM_SERVICE_ACCOUNT_JSON is empty — push is disabled")
        print("         (that is a supported state: the in-app inbox still works)")
        return False, None

    try:
        info = json.loads(raw)
    except json.JSONDecodeError as exc:
        print(f"{BAD} FCM_SERVICE_ACCOUNT_JSON is not valid JSON: {exc}")
        print("         It must be the whole file on ONE line, with the")
        print(r'         private key newlines kept as literal \n escapes.')
        return False, None

    missing = [k for k in ("client_email", "private_key", "project_id") if not info.get(k)]
    if missing:
        print(f"{BAD} service account JSON is missing: {', '.join(missing)}")
        return False, None

    if "-----BEGIN PRIVATE KEY-----" not in info["private_key"]:
        print(f"{BAD} private_key does not look like a PEM key")
        return False, None

    print(f"{OK} service account parses — {info['client_email']}")
    print(f"{OK} project_id — {info['project_id']}")
    return True, info["project_id"]


async def check_credentials() -> bool:
    """Exchange the service account for an access token. Proves it works."""
    import httpx

    from app.push import fcm

    async with httpx.AsyncClient(timeout=20.0) as client:
        token = await fcm._access_token(client)

    if not token:
        print(f"{BAD} could not get an OAuth token from Google")
        print("         Common causes:")
        print("           - the service account was deleted or its key revoked")
        print("           - system clock is skewed (the JWT is time-signed)")
        print("           - no network / proxy blocking oauth2.googleapis.com")
        return False
    print(f"{OK} exchanged the service account for an access token")
    return True


def _devices(env: dict[str, str]) -> list[tuple]:
    """Registered devices, newest first, straight from the database.

    Reads the database rather than asking anyone to copy a 160-character token
    off a phone. A token reaches this table on sign-in, so an empty result is
    itself the diagnosis: the app never got as far as registering.
    """
    from sqlalchemy import create_engine, text

    url = env.get("DATABASE_URL_SYNC")
    if not url:
        print(f"{BAD} DATABASE_URL_SYNC is not set in .env")
        return []
    engine = create_engine(url)
    with engine.connect() as conn:
        return list(
            conn.execute(
                text(
                    "SELECT token, platform, is_active, language, app_version,"
                    "       utc_offset_minutes, created_at "
                    "FROM device_tokens ORDER BY created_at DESC"
                )
            ).all()
        )


def list_devices(env: dict[str, str]) -> int:
    rows = _devices(env)
    if not rows:
        print(f"{WARN} no devices registered yet\n")
        print("  A token is registered when the app signs in. If you have opened")
        print("  the app and this is still empty, the likely causes in order:")
        print("    1. the build has no FIREBASE_* defines (check the build log")
        print("       said 'push notifications  enabled')")
        print("    2. Firebase failed to initialise on the device — look for")
        print("       'Push initialization skipped' in:")
        print("         adb logcat | grep -iE 'push|firebase|flutter'")
        print("    3. you are signed out; registration happens on sign-in")
        return 1

    print(f"{OK} {len(rows)} device(s) registered\n")
    for token, platform, active, language, version, offset, created in rows:
        state = "active" if active else "retired"
        print(f"  {platform.value if hasattr(platform, 'value') else platform}"
              f"  {state}  {language}  v{version or '?'}  UTC{offset:+d}m"
              f"  {created:%Y-%m-%d %H:%M}")
        print(f"    {token[:48]}…")
    return 0


async def check_api_reachable() -> bool:
    """Confirm the Cloud Messaging API is switched on for this project.

    A valid access token proves the *credentials* work; it says nothing about
    whether the FCM API is enabled, which is a separate switch and a separate
    failure. The cheapest way to tell is to send to a deliberately bogus device
    token and read which complaint comes back:

      * a 403 SERVICE_DISABLED is about the **project** — the API is off
      * an INVALID_ARGUMENT / UNREGISTERED is about the **token** — meaning the
        API is live, reachable, and doing its job

    No real device is involved, so this is safe to run any time.
    """
    import httpx

    from app.push import fcm

    project = fcm.project_id()
    async with httpx.AsyncClient(timeout=20.0) as client:
        token = await fcm._access_token(client)
        if not token:
            print(f"{BAD} no access token available for the reachability probe")
            return False
        response = await client.post(
            fcm._SEND_URL.format(project=project),
            headers={"Authorization": f"Bearer {token}"},
            json=fcm._envelope(
                "probe-not-a-real-registration-token",
                fcm.PushMessage(title="probe", body="probe"),
            ),
        )

    body = json.dumps(response.json()) if response.content else ""
    if response.status_code == 403 and "SERVICE_DISABLED" in body:
        print(f"{BAD} the Cloud Messaging API is disabled on {project}")
        print("         Enable it: console.cloud.google.com/apis/library/")
        print("         fcm.googleapis.com — pick this project, press Enable.")
        return False
    if response.status_code == 401:
        print(f"{BAD} FCM rejected the access token (401)")
        return False

    code = fcm._error_status(response)
    if code in fcm._PERMANENT_ERRORS:
        print(f"{OK} FCM API is live — it rejected the fake token as {code}")
        print(f"{OK} that class of error retires a dead token automatically")
        return True

    print(f"{WARN} unexpected reply from FCM ({response.status_code} / {code})")
    print(f"         {body[:200]}")
    return False


async def send_test(token: str) -> bool:
    from app.push import fcm

    result = await fcm.send(
        [token],
        fcm.PushMessage(
            title="SpeedQuiz test",
            body="Push is working. You can ignore this.",
            data={"type": "test", "deep_link": "/battle"},
        ),
    )
    if result.skipped:
        print(f"{BAD} send was skipped — push is not enabled in this config")
        return False
    if result.dead_tokens:
        print(f"{BAD} FCM rejected the token as permanently invalid")
        print("         That token belongs to an uninstalled app or another project.")
        return False
    if result.sent:
        print(f"{OK} FCM accepted the message — check the device")
        return True
    print(f"{BAD} FCM refused the message ({result.failed} failure(s))")
    print("         Re-run with the backend log level at DEBUG for the reason.")
    return False


def check_dart_defines(env: dict[str, str]) -> bool:
    present = [k for k in DART_DEFINES if env.get(k)]
    if len(present) == len(DART_DEFINES):
        print(f"{OK} all four FIREBASE_* values present for the app build")
        return True
    if not present:
        print(f"{WARN} no FIREBASE_* values in .env — the app will build with push off")
        return False
    missing = [k for k in DART_DEFINES if k not in present]
    print(f"{BAD} partial FIREBASE_* config — missing {', '.join(missing)}")
    print("         A partial set is worse than none: the app builds, looks")
    print("         fine, and never registers for push.")
    return False


def check_project_match(env: dict[str, str], service_project: str | None) -> None:
    """The server and the app must be talking about the same project."""
    app_project = env.get("FIREBASE_PROJECT_ID")
    if not (app_project and service_project):
        return
    if app_project == service_project:
        print(f"{OK} app and server agree on the project ({app_project})")
    else:
        print(f"{BAD} project mismatch — app targets {app_project!r},")
        print(f"         service account belongs to {service_project!r}.")
        print("         Tokens minted by the app would be rejected as")
        print("         SENDER_ID_MISMATCH and silently retired.")


def emit_env_line(path: Path) -> int:
    """Turn a downloaded service-account file into the `.env` line.

    Worth automating because the manual version goes wrong in a specific,
    hard-to-see way. The `private_key` field contains literal backslash-n
    escapes *inside* the JSON string; anyone flattening the file by hand tends
    to either convert those to real newlines (which breaks `.env` parsing, as
    the value stops at the line end) or to escape them twice (which yields a
    key PEM decoding rejects). Re-serializing the parsed object leaves them
    exactly as they were, which is the one correct answer.
    """
    if not path.exists():
        print(f"{BAD} no such file: {path}")
        return 1
    try:
        info = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(f"{BAD} that file is not valid JSON: {exc}")
        return 1

    if info.get("type") != "service_account":
        print(f"{BAD} this is not a service-account key (type={info.get('type')!r}).")
        print("         If it has a `client` array it is google-services.json —")
        print("         that is the app config, not the server credential. You")
        print("         want Project settings -> Service accounts -> Generate")
        print("         new private key.")
        return 1

    compact = json.dumps(info, separators=(",", ":"))
    print(f"\n{OK} {info['client_email']}")
    print(f"{OK} project {info['project_id']}\n")
    print("Add to the root .env (the JSON line is long — it is meant to be):\n")
    print(f"FCM_SERVICE_ACCOUNT_JSON={compact}")
    print(f"FCM_PROJECT_ID={info['project_id']}")
    print(
        "\nThis key can send push as your project. Keep it out of git — .env is\n"
        "already gitignored — and paste the same value into Railway's variables\n"
        "for both the api and worker services."
    )
    return 0


async def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--token", help="Device FCM token to send a real test push to")
    parser.add_argument(
        "--from-file",
        type=Path,
        metavar="PATH",
        help="Downloaded service-account JSON; prints the .env lines and exits",
    )
    parser.add_argument(
        "--latest-device",
        action="store_true",
        help="Look up the newest registered device in the database and push to it",
    )
    parser.add_argument(
        "--list-devices",
        action="store_true",
        help="Show registered devices and exit",
    )
    args = parser.parse_args()

    if args.from_file:
        return emit_env_line(args.from_file)
    if args.list_devices:
        return list_devices(read_env())

    env = read_env()
    print("\n--- app build config (.env) ---")
    check_dart_defines(env)

    print("\n--- server credentials ---")
    ok, service_project = check_service_account(env.get("FCM_SERVICE_ACCOUNT_JSON", ""))

    print("\n--- consistency ---")
    check_project_match(env, service_project)

    if not ok:
        print("\nPush is not configured. See docs/DEVELOPMENT.md section 7.")
        return 1

    # Import after the JSON is known good, so settings pick it up.
    import os

    os.environ.setdefault("FCM_SERVICE_ACCOUNT_JSON", env["FCM_SERVICE_ACCOUNT_JSON"])
    os.environ.setdefault("PUSH_ENABLED", "true")

    print("\n--- live credential check ---")
    if not await check_credentials():
        return 1

    print("\n--- FCM API reachability ---")
    if not await check_api_reachable():
        return 1

    target = args.token
    if args.latest_device and not target:
        rows = _devices(env)
        active = [r for r in rows if r[2]]
        if not active:
            print("\n--- test delivery ---")
            list_devices(env)
            return 1
        target = active[0][0]
        print(f"\n{OK} using the newest registered device ({active[0][1]})")

    if target:
        print("\n--- test delivery ---")
        if not await send_test(target):
            return 1
    else:
        print("\n(add --latest-device to push to your phone, or --list-devices)")

    print("\nPush is configured correctly.")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
