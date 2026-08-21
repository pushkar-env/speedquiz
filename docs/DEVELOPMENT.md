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
| Multiplayer — matches, rounds, settlement ([below](#7-multiplayer)) | `backend/app/services/matches.py` |
| Realtime — Redis Streams fan-out, WebSocket, presence | `backend/app/services/realtime.py`, `backend/app/api/v1/multiplayer.py` |
| Social graph — friends, blocks, usernames, friend codes | `backend/app/services/friends.py`, `usernames.py` |
| Ranked — Elo, tiers, seasons, matchmaking queue | `backend/app/services/ranking.py`, `matchmaking.py` |
| Push — FCM v1 sender, device registry, quiet hours | `backend/app/push/fcm.py`, `backend/app/services/notifications.py` |
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

## 7. Multiplayer

Three ideas carry the whole feature. Everything else follows from them.

### The board is frozen at creation

A match draws its questions **once**, and stores the ids plus a per-question
option permutation on the `matches` row. Every participant therefore sees the
same prompts, in the same order, with the same answers in the same button
positions. That is what makes two scores comparable — and it is also what lets
an opponent who was offline play the identical board six hours later.

Questions already seen by *any* known participant are excluded first, so nobody
arrives with a head start. If the bank is too thin to fill a match that way,
the fairness filter is dropped rather than refusing to start: both sides being
equally disadvantaged by a repeat beats no game at all.

### Live and async are the same match

`matches.delivery` is `live` or `async`. A live match runs one shared clock off
`matches.round_started_at`; an async one has no shared clock, so each player's
window opens when *they* are served (`match_participants.round_served_at`,
cleared after every answer). Nothing else differs — same board, same scoring,
same settlement.

A live match degrades to async when the opponent never connects. That is the
single most important behaviour in the feature: on Indian mobile networks, a
challenge that requires both players online at the same instant is a challenge
that mostly does not happen.

### Nobody owns a match

Railway runs several API containers and the two players are routinely on
different ones, so no process can hold a timer for a game. Round advancement is
*opportunistic*: any request that touches a match — an answer landing, a state
poll, a realtime tick — asks whether the round is over, and a short Redis lock
plus a compare-and-set on `current_round_index` makes exactly one of them act.
No leader election, and if Redis is down it degrades to "the next request
advances it", which is late but never wrong.

### Realtime

The transport is a **Redis Stream per match**, not pub/sub. Pub/sub delivers to
whoever is listening at that instant; a player crossing from wifi to cellular
is gone for two seconds and must not lose the round that started meanwhile. A
stream is a log with ids, so a reconnecting client resumes from its last id.

Critically, there is **one reader per process, not per socket**
(`RealtimeHub`). A `XREAD BLOCK` per WebSocket would burn a Redis connection
per connected player, and against a 50-connection pool that ceiling is 50
concurrent players.

Answers go over HTTP even during a live match. The socket is a notification
channel; putting the one write that must not be lost on the one transport that
drops would be a poor trade.

> **The Cloudflare Worker must be redeployed** for any of this to work in
> production. It previously rewrapped every response, which discards the
> `webSocket` handle — see `infrastructure/cloudflare-worker/worker.js`.

### Usernames became identities

A username used to be a label nobody typed. Now strangers search and challenge
by it, so `user_profiles.username_skeleton` stores a folded form — lowercased,
separators dropped, digits mapped to the letters they imitate — and carries the
unique index. `Ravi`, `r_a_v_i` and `R4vi` are therefore one identity, which is
the impersonation vector closed. Migration `0006` backfills it with a Postgres
`translate()` that must stay identical to `usernames.username_skeleton`; a test
asserts they agree.

### Ranked

Only rated 1v1 duels move Elo — friend challenges are unrated on purpose, since
a ladder attached to them suppresses the exact behaviour the social features
exist to create. Placements use a larger K so a new player reaches their real
bracket in five games. Seasons are a key (`YYYY-MM`), not a table: rollover is
the first ranked match of a month creating a row seeded from the last one, so
there is no scheduled job that can fail to run.

### Push

Optional. With no `FCM_SERVICE_ACCOUNT_JSON` the sender is a no-op and the
in-app inbox carries everything — a deployment without a Firebase project has a
working multiplayer feature, just a quieter one. The client side is the same
deal: the four `FIREBASE_*` dart-defines are read by
`scripts/build_android.sh`, and their absence disables push rather than
breaking the build.

Quiet hours are applied **per device** using the UTC offset the client reports,
because a server-side 22:00 is the wrong 22:00 for most of the world. Only
`match_your_turn` is exempt — the round clock is running and silence costs the
player the game.

#### Setting it up

There is deliberately **no `google-services.json` in the repo**, and the
google-services Gradle plugin is deliberately not applied. Firebase is
configured from `FirebaseOptions` built out of dart-defines instead, so a
checkout without a Firebase project still builds. That is the whole reason the
setup below is four values rather than a file drop.

1. **Create the project** — <https://console.firebase.google.com> → *Add
   project*. Google Analytics is not needed.

2. **Register the Android app** — *Project settings → Your apps → Add app →
   Android*.
   - Package name: `com.speedquiz.app` (must match exactly, or tokens are
     rejected as `SENDER_ID_MISMATCH`)
   - Debug signing SHA-1: optional here — it is required for Google Sign-In,
     not for FCM
   - **Download `google-services.json` but do not add it to the project.** It
     is only a convenient place to read the four values from.

3. **Read the four values** out of that file (or off the *Your apps* panel):

   | dart-define | Where it is in `google-services.json` |
   |---|---|
   | `FIREBASE_API_KEY` | `client[0].api_key[0].current_key` |
   | `FIREBASE_APP_ID` | `client[0].client_info.mobilesdk_app_id` |
   | `FIREBASE_PROJECT_ID` | `project_info.project_id` |
   | `FIREBASE_SENDER_ID` | `project_info.project_number` |

   Put them in the root `.env`. `scripts/build_android.sh` picks them up and
   refuses a partial set — four or none, because a partial set builds an app
   that looks fine and never registers.

4. **Create the server credential** — *Project settings → Service accounts →
   Generate new private key*. This downloads a JSON file.
   - Paste it into `FCM_SERVICE_ACCOUNT_JSON` as **one line**, keeping the
     private key's newlines as literal `
` escapes.
   - This is a secret with send-as-your-project authority. It belongs in the
     gitignored `.env` and in Railway's variables — never in the repo.

5. **Verify before believing it:**

   ```bash
   python scripts/verify_push.py
   ```

   It checks the JSON parses, exchanges it for a real OAuth token, and confirms
   the app and server agree on the project id. Add `--token <device token>` to
   send an actual notification.

6. **iOS additionally** needs an APNs key (*Project settings → Cloud Messaging
   → APNs Authentication Key*) uploaded to Firebase, plus the Push
   Notifications capability in Xcode. Android does not.

#### The Android notification channel

`MainActivity.kt` registers a `speedquiz_multiplayer` channel at launch, and
`backend/app/push/fcm.py` targets that id. **These two strings must stay in
step.** On Android 8+ a notification naming a channel that does not exist is
dropped with no error, no crash and nothing in the app's logs — the failure
looks exactly like nobody having sent it.

The channel is created in Kotlin rather than from Dart because a push can
arrive at a process the user never opened, so it has to exist before any Dart
runs. Its label lives in `android/app/src/main/res/values/strings.xml` (and
`values-hi/`) because Android renders it in system Settings, where the Dart
string table cannot reach.

On-device reminders — the daily challenge, a lapsing streak, a nudge back after
a few quiet days — are a separate system on a separate `speedquiz_reminders`
channel, scheduled from Dart via `flutter_local_notifications` and needing no
Firebase project at all. See `mobile/lib/core/push/local_notifications.dart`
and `ReminderScheduler`. Keeping the two channels apart is what lets a player
silence nudges in system settings without also losing challenges.

---

## 8. Client design system

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
/studio            quizzes you wrote + quizzes shared with you
/studio/new        write a quiz
/studio/quiz/:id   play it, challenge with it, its own leaderboard
/studio/quiz/:id/edit
/studio/code/:code redeem a share code (deep-link target)
/quiz/*            setup → play → results
/share/results/:id public share card, reachable signed out
```

The studio's screens sit on the **root** navigator, not in the tab shell:
writing a quiz is a destination, and a half-written question must not be
interruptible by a stray tap on the bottom bar. `QuizEditorScreen` registers
its own `PopScope` rather than wrapping in `SqBackGuard` — leaving flushes any
metadata edit that has not been written yet, and two `PopScope`s on one route
both fire.

See [Player-authored quizzes](../README.md#player-authored-quizzes) for how the
feature is built server-side.

---

## 9. Local gotchas worth knowing

| Symptom | Cause |
|---|---|
| Settings read the wrong database when running Python from `backend/` | `.env` resolves relative to the working directory. Run from the repo root or pass variables explicitly |
| `CERTIFICATE_VERIFY_FAILED ... certificate has expired` against a managed service | A stale root CA in the local Python trust store, not the provider. Run with `SSL_CERT_FILE=$(python -c "import certifi;print(certifi.where())")` |
| `openssl` not recognised in PowerShell | Git for Windows bundles it at `C:\Program Files\Git\usr\bin\openssl.exe`. Works in Git Bash, or use `python -c "import secrets; print(secrets.token_hex(32))"` |
| App on a physical device says "Cannot reach the server" | Built without `--dart-define=API_BASE_URL`, so it fell back to the emulator address `10.0.2.2:8000` |
