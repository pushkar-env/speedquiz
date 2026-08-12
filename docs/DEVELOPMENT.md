# Development

Everything needed to run SpeedQuiz locally and understand how it fits together.

- Deploying it: [DEPLOYMENT.md](DEPLOYMENT.md)
- Shipping to Play: [RELEASE.md](RELEASE.md)
- App and quiz languages: [LANGUAGES.md](LANGUAGES.md)

---

## 1. Architecture

```text
Flutter app (mobile/)
      │ HTTPS
      ▼
FastAPI (backend/app)  ──►  PostgreSQL   (sessions, questions, profiles)
      │                └─►  Redis        (rate limits, leaderboard ZSETs, locks)
      ▼
Background worker (workers/)  ──►  same DB + Redis + LLM provider
```

### The one principle that shapes everything

**No LLM call ever happens during gameplay.** Questions are generated,
validated and stored by the background worker ahead of time; a quiz session
reads them straight from Postgres. That is why answering is fast and why the
API scales on ordinary hardware.

The exceptions are deliberate and user-initiated: creating a **custom topic**
and tapping **Teach me** both call the model on demand, and both are rate
limited.

### Subsystems

| Area | Location |
|---|---|
| Quiz engine — session state machine, server-authoritative scoring, adaptive difficulty | `backend/app/services/quiz_service.py`, `scoring.py`, `adaptive.py` |
| Leaderboards — Redis ZSET with a Postgres fallback | `backend/app/services/leaderboards.py` |
| Entitlements & IAP verification | `backend/app/payments/` |
| AI pipeline — generate → validate → quality score → dedupe → store | `backend/app/ai/`, `workers/` |
| Question bank top-ups | `backend/app/services/bank_inventory.py` |
| Mobile client — Riverpod, GoRouter, Dio with JWT refresh | `mobile/lib/` |
| Languages — app chrome and per-run quiz content, English + Hindi ([LANGUAGES.md](LANGUAGES.md)) | `mobile/lib/core/i18n/`, `backend/app/core/languages.py` |

### Anti-cheat

Answer timing is resolved server-side against the served-at timestamp, with
a grace window for network jitter. Redis enforces a sliding-window limit on
answer submissions per user. Scores are never trusted from the client.

---

## 2. Run the backend

```bash
cp .env.example .env
```

```bash
docker compose up --build
```

- API — <http://localhost:8000>
- Interactive docs — <http://localhost:8000/docs>
- Health — `curl http://localhost:8000/health`
- Readiness — `curl http://localhost:8000/ready` (checks Postgres and Redis)

Or use the wrapper, which waits for health before returning:

```bash
bash scripts/dev_up.sh
```

Stop with `docker compose down`. Add `-v` only when you want to wipe the
database volume.

On first boot the API runs migrations, then seeds 8 categories, 18 topics and
16 achievements. Set `LLM_API_KEY` if you want the worker to actually grow the
question bank; without it the seeded bank is all you get.

---

## 3. Run the app

### Emulator

```bash
cd mobile && flutter pub get
```

```bash
flutter run
```

No `--dart-define` needed: `AppConfig` falls back to `http://10.0.2.2:8000`,
which is the emulator's alias for your machine's localhost.

### Physical device on the same Wi-Fi

`10.0.2.2` means nothing on a real phone, so pass your machine's LAN address.
Find it with `ipconfig`, then allow the port through the firewall once:

```bash
netsh advfirewall firewall add rule name="SpeedQuiz API" dir=in action=allow protocol=TCP localport=8000
```

```bash
flutter run --dart-define=API_BASE_URL=http://192.168.1.42:8000
```

Cleartext HTTP works because `network_security_config.xml` permits it. That is
a development affordance — see the note in [RELEASE.md](RELEASE.md) before
shipping.

### Physical device anywhere

Point it at a deployed API. See [DEPLOYMENT.md](DEPLOYMENT.md).

---

## 4. Environment variables

Local values live in the gitignored root `.env`; the template is
[`.env.example`](../.env.example). Two of them are **not** environment
variables at all — they are compiled into the Flutter binary:

| Compile-time define | Purpose |
|---|---|
| `API_BASE_URL` | Backend base URL. Absent → emulator/localhost fallback |
| `GOOGLE_SERVER_CLIENT_ID` | Google **Web** OAuth client ID, used as `serverClientId` |

### Core

| Variable | Local | Production | Notes |
|---|---|---|---|
| `APP_ENV` | `development` | `production` | Enables the startup safety checks below |
| `DEBUG` | `true` | `false` | Production refuses to boot with this on |
| `LOG_LEVEL` | `INFO` | `INFO` | |
| `CORS_ORIGINS` | `*` | `*` or real origins | `*` automatically disables `allow_credentials`, since browsers reject that combination |
| `JWT_SECRET` | anything | 32+ random chars | `openssl rand -hex 32` |
| `WEB_CONCURRENCY` | `1`–`2` | `2`–`4` | Uvicorn worker processes |

### Database and cache

| Variable | Notes |
|---|---|
| `DATABASE_URL` | **asyncpg** URL for the app. No libpq query params — see [DEPLOYMENT.md](DEPLOYMENT.md) |
| `DATABASE_URL_SYNC` | **psycopg** URL for Alembic. Same database |
| `DB_POOL_SIZE` (default `5`) | Per process |
| `DB_MAX_OVERFLOW` (default `10`) | Per process |
| `DB_POOL_RECYCLE_SECONDS` (default `1800`) | Below any proxy idle timeout |
| `DB_DISABLE_PREPARED_STATEMENTS` | `true` behind a transaction-mode pooler |
| `REDIS_URL` | `rediss://` when the provider requires TLS |

> **Pool sizes are small on purpose.** Async handlers hold a connection only
> while a query is in flight, so real usage is roughly
> `RPS x seconds of DB time` — single digits for this workload. Total server
> connections are `(pool_size + max_overflow) x workers x replicas`, and
> Postgres defaults to `max_connections = 100`. Oversizing does not buy
> throughput; it converts a brief wait into `FATAL: sorry, too many clients`.

### AI worker

| Variable | Notes |
|---|---|
| `LLM_PROVIDER` | `openai` or `mock` |
| `LLM_API_KEY` | Needed by **both** api and worker — the API serves custom topics and Teach me |
| `LLM_MODEL_GENERATE` / `_VALIDATE` / `_CLASSIFY` | Default `gpt-4o-mini` |
| `TOPIC_BANK_TARGET_UNIQUE` | Watermark the worker fills toward |

### Production safety latches

`APP_ENV=production` makes the app **refuse to boot** on any of these, rather
than run insecurely:

| Condition | Why |
|---|---|
| `JWT_SECRET` is the shipped placeholder, or under 32 chars | Tokens could be forged |
| `ENTITLEMENTS_DEV_TOGGLE=true` | Exposes `POST /entitlements/dev/premium` — free Premium for any user |
| `DEBUG=true` | Verbose errors and SQL echo |

The error message names the exact problem. Tests: `backend/tests/test_production_config.py`.

---

## 5. Google Sign-In

The app obtains a Google **ID token** and posts it to
`POST /api/v1/auth/google`, which verifies it and returns SpeedQuiz JWTs. When
a guest Bearer token is supplied, the guest row is **upgraded in place** so
progress survives.

### Google Cloud Console

1. Create a project → **APIs & Services → OAuth consent screen** (External is fine for testing; add test users).
2. **Credentials → Create credentials → OAuth client ID**:
   - **Web application** — this single ID is used twice: as `GOOGLE_CLIENT_ID` on the API (audience check) and as the app's `GOOGLE_SERVER_CLIENT_ID`.
   - **Android** — package `com.speedquiz.app` plus the SHA-1 of the signing key.

Debug SHA-1:

```bash
keytool -list -v -alias androiddebugkey -keystore %USERPROFILE%\.android\debug.keystore -storepass android -keypass android
```

Release SHA-1 comes from your upload keystore — see [RELEASE.md](RELEASE.md).
**Each signing key needs its own registration**, which is why Sign-In often
works in debug and fails in release.

### Wire it up

```env
GOOGLE_CLIENT_ID=123456789-xxxx.apps.googleusercontent.com
```

Empty → `POST /auth/google` returns **503**. Restart the API after changing it.

```bash
flutter run --dart-define=GOOGLE_SERVER_CLIENT_ID=123456789-xxxx.apps.googleusercontent.com
```

### Troubleshooting

| Symptom | Cause |
|---|---|
| API returns 503 | `GOOGLE_CLIENT_ID` unset |
| "ID token is null" | Wrong client type as `serverClientId` — it must be the **Web** ID |
| `ApiException: 10` / `DEVELOPER_ERROR` | Android OAuth client SHA-1 or package mismatch |
| Picker opens then cancels instantly | Same as above. The plugin reports this as a user cancel, so it looks harmless |
| 401 invalid token | Web client ID differs between app and API |
| 409 email conflict | That email already has an email/password account |

iOS needs its own OAuth client (bundle `com.speedquiz.app`); Android-first is
enough for a first launch.

---

## 6. Tests

```bash
cd backend && .venv/Scripts/python.exe -m pytest -q
```

```bash
cd mobile && flutter analyze && flutter test
```

The Flutter suite includes screen smoke tests that render every screen at
phone size in both themes and fail on any layout overflow or exception, plus
WCAG contrast assertions on the palette. They catch the class of bug that
otherwise only shows up on a device.

---

## 7. Client design system

Screens should reach for these rather than hand-rolling colours or timings.

| Concern | Location |
|---|---|
| Colour, type, full `ThemeData` (light + dark) | `mobile/lib/core/theme/app_theme.dart` |
| Durations and curves | `mobile/lib/core/theme/app_motion.dart` |
| Haptics | `mobile/lib/core/feedback/haptics.dart` |
| Sound cues and ambient loop | `mobile/lib/core/feedback/audio_service.dart` |
| Sound / haptics / music preferences | `mobile/lib/core/settings/app_settings.dart` |
| Route transitions | `mobile/lib/core/routing/page_transitions.dart` |
| Buttons, cards, dialogs, toasts, confetti, skeletons | `mobile/lib/shared/widgets/` (import `sq_widgets.dart`) |

Conventions:

- Resolve colours through `context.sq` (a `SqPalette`), never by branching on `Theme.of(context).brightness`.
- Fonts are **bundled** in `mobile/assets/fonts/` — no runtime fetch, no first-launch flash.
- Audio in `mobile/assets/audio/` is synthesised; playback is decorative and fails silently.
- Every animated widget honours the platform *reduce motion* setting.
- **Dialogs must pop with the dialog's own context.** `showSqDialog` passes its route context to the builder for exactly this reason — popping with the caller's context resolves to the GoRouter navigator and tears the current page off the stack, leaving a blank route.

### Screen map

```text
/splash            boot, restores a stored session
/onboarding        first run only: language, then name (device-local)
/landing           signed out: play as guest / continue with Google
/home              hero play, surprise-me, daily challenge, topic rail   ┐
/explore           search, category rail, trending, grouped topic grid   │ tabs
/leaderboard       weekly + daily podium and ranks                       │
/profile           identity hub, links to the screens below              ┘
/profile/edit      display name + avatar picker (PATCH /users/me)
/profile/achievements
/profile/stats     lifetime accuracy, speed, topic mastery
/premium           full-screen store (also shown as a mid-game sheet)
/settings          appearance, sound, haptics, account, sign out
/quiz/*            setup → play → results
/share/results/:id public share card, reachable signed out
```

---

## 8. Local gotchas worth knowing

| Symptom | Cause |
|---|---|
| Settings read the wrong database when running Python from `backend/` | `.env` resolves relative to the working directory. Run from the repo root or pass variables explicitly |
| `CERTIFICATE_VERIFY_FAILED ... certificate has expired` against a managed service | A stale root CA in the local Python trust store, not the provider. Run with `SSL_CERT_FILE=$(python -c "import certifi;print(certifi.where())")` |
| `openssl` not recognised in PowerShell | Git for Windows bundles it at `C:\Program Files\Git\usr\bin\openssl.exe`. Works in Git Bash, or use `python -c "import secrets; print(secrets.token_hex(32))"` |
| App on a physical device says "Cannot reach the server" | Built without `--dart-define=API_BASE_URL`, so it fell back to the emulator address `10.0.2.2:8000` |
