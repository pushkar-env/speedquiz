# SpeedQuiz

Production-grade AI-powered quiz game for Android and iOS.

Gameplay is served from a validated question bank — not live LLM calls per question.

## Architecture

```text
mobile/          Flutter client (Riverpod, GoRouter, Dio)
backend/         FastAPI + SQLAlchemy + Alembic
workers/         Background AI generation / validation jobs
infrastructure/  Docker and deployment assets
docs/            Product and engineering docs
scripts/         Dev utilities
```

## Client design system

The Flutter client is built on one shared token + widget layer. Screens should
reach for these instead of hand-rolling colours, timings or feedback.

| Concern | Location |
|---|---|
| Colour, type, full `ThemeData` (light + dark) | `mobile/lib/core/theme/app_theme.dart` |
| Durations and curves | `mobile/lib/core/theme/app_motion.dart` |
| Haptics (with a global kill switch) | `mobile/lib/core/feedback/haptics.dart` |
| Sound cues and ambient loop | `mobile/lib/core/feedback/audio_service.dart` |
| Sound / haptics / music preferences | `mobile/lib/core/settings/app_settings.dart` |
| Route transitions | `mobile/lib/core/routing/page_transitions.dart` |
| Buttons, cards, dialogs, toasts, confetti, skeletons, … | `mobile/lib/shared/widgets/` (import `sq_widgets.dart`) |

Notes:

- Resolve colours via `context.sq` (a `SqPalette`) rather than branching on
  `Theme.of(context).brightness`.
- Space Grotesk and DM Sans are **bundled** in `mobile/assets/fonts/`, so there
  is no runtime font fetch and no first-launch fallback flash.
- Audio in `mobile/assets/audio/` is fully synthesised (see the generator note
  in `audio_service.dart`); playback is decorative and fails silently.
- Every animated widget honours the platform *reduce motion* setting.
- **Dialogs must pop with the dialog's own context.** `showSqDialog` hands its
  route context to the builder for exactly this reason: popping with the
  caller's context resolves to the GoRouter navigator and tears the current
  page off the stack, leaving a blank route.

### Screen map

```text
/splash            boot, restores a stored session
/landing           signed-out: play as guest / continue with Google
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
/share/results/:id public share card (reachable signed-out)
```

## Documentation

Three guides, each self-contained:

| Guide | Covers |
|---|---|
| **[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)** | Architecture, running locally, environment reference, Google Sign-In setup, tests, client design system |
| **[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md)** | Railway + Neon + Upstash + Cloudflare Worker, scaling, load testing, troubleshooting, VPS alternative |
| **[docs/RELEASE.md](docs/RELEASE.md)** | Signing, App Links, IAP verification, Play Console, pre-submission checklist |

## Quick start

### Prerequisites

- Docker Desktop
- Flutter 3.44+
- Python 3.12+ (optional for local non-Docker backend)

### Start infrastructure + API

```bash
cp .env.example .env
docker compose up --build
```

Production-style (no reload / no source mounts):

```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml up --build -d
```

Services:

| Service  | URL                    |
|----------|------------------------|
| API      | http://localhost:8000  |
| Docs     | http://localhost:8000/docs |
| Postgres | localhost:5432         |
| Redis    | localhost:6379         |

Health:

```bash
curl http://localhost:8000/health
curl http://localhost:8000/ready
```

### Run Flutter

```bash
cd mobile
flutter pub get
flutter run
```

Point the app at a backend:

- **Android emulator** — nothing to pass; falls back to `http://10.0.2.2:8000`
- **Physical device, same Wi-Fi** — `--dart-define=API_BASE_URL=http://<your-LAN-ip>:8000`
- **Physical device, any network** — deploy first, then pass the public URL

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#3-run-the-app) for the details.

Play Store App Bundle:

```bash
# After creating mobile/android/key.properties from key.properties.example
flutter build appbundle --release --dart-define=API_BASE_URL=https://speedquiz.app
```

### Backend tests

```bash
cd backend
pip install -r requirements/dev.txt
pytest
```

## Phases

1. **Phase 1** — Monorepo, Docker, auth, models, API skeleton ✅
2. **Phase 2** — Topics, sessions, scoring, game modes ✅
3. **Phase 3** — Polished Flutter gameplay UI ✅
4. **Phase 4** — AI generation, custom topics, Teach Me ✅
5. **Bank scale** — Watermark top-ups toward ~1000 unique/topic ✅ (ongoing refill)
6. **Phase 5a** — XP/daily streaks + achievements unlock ✅
7. **Phase 5b** — Leaderboards + daily challenge ✅
8. **Phase 6a** — Adaptive difficulty + light analytics ✅
9. **Phase 6b** — Entitlements foundation + share + anti-cheat ✅
10. **Phase 7a** — Share deep links + paywall UX ✅
11. **Phase 7b** — IAP foundation (verify + buy path) ✅
12. **Phase 7c** — HTTPS share landing foundation ✅
13. **Phase 8a** — App Links / Universal Links foundation ✅
14. **Phase 8b** — Store verification adapters (Apple/Google) ✅
15. **Phase 8c** — Production app identity (`com.speedquiz.app`) ✅
16. **Phase 8d** — Android release readiness + deployment docs ✅
17. **Phase 9** — Design system + landing/sign-out + full UI pass ✅
18. **Phase 10** — Screen split, profile customisation, audio, random topic ✅
19. **Next** — Play Console upload (keystore + AAB) → internal test → production

See [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) and [docs/RELEASE.md](docs/RELEASE.md).

## Progression & engagement

- Calendar **daily streak** updates on quiz finish; Home 🔥 shows it
- Achievements evaluate on finish (`GET /api/v1/achievements`)
- XP level curve: need `level * 500` XP to advance
- **Daily challenge:** `GET/POST /api/v1/daily-challenge` (fixed questions, one clear/day)
- **Leaderboards:** `GET /api/v1/leaderboards?scope=weekly|daily` (Redis + Postgres)
- **Adaptive:** create session with `adaptive=true`; Elo-lite `skill_ratings` per topic
- **Analytics:** `analytics_events` table (`ANALYTICS_PROVIDER=postgres`)
- **Entitlements:** `GET /api/v1/entitlements/me` (caps off by default); Profile Free/Premium + paywall sheet
- **Auth:** landing screen with **Play as Guest** + **Continue with Google** (`POST /auth/google`); Profile links a guest to Google and offers **Sign out** — see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#5-google-sign-in)
- **IAP:** `POST /api/v1/entitlements/purchases/verify` (`stub` default; `apple_google` with `APPLE_IAP_*` / `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`); Flutter store buy/restore when products exist
- **Share:** public `GET /api/v1/share/results/{id}`; landing `GET /r/{id}`; `speedquiz://` + optional `SHARE_PUBLIC_BASE_URL`
- **App Links:** `GET /.well-known/assetlinks.json` + `apple-app-site-association`; package `com.speedquiz.app`; set fingerprints + `APP_LINK_IOS_APP_ID` and point DNS at the API when ready


## Question bank (endless unique)

Gameplay never waits on an LLM. Questions are served from Postgres.

- Target unique bank size per topic: **1000** (then reshuffle-reuse is OK)
- When a topic falls below a **low watermark**, the worker generates the next **chunk** (~20) in the background
- Sessions prefer questions the player has not seen yet
- Free play is **unlimited** today (caps ready behind `ENTITLEMENTS_ENFORCE_QUESTION_CAPS`)

### Monetization roadmap

- Soft-gate free users after ~**30 unique questions / topic** (wired; flag off)
- Unlock more via **premium** (dev toggle now; StoreKit/Play later) or **diamonds**
- Flip `ENTITLEMENTS_ENFORCE_QUESTION_CAPS=true` when ready (server-side entitlements)

## License

Proprietary — all rights reserved.
