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

## Quick start

Master Play Store & 1,000 CCU Guide: **[docs/PLAYSTORE_PRODUCTION_GUIDE.md](docs/PLAYSTORE_PRODUCTION_GUIDE.md)**.  
Day-to-day open/run/build: **[docs/OPEN_AND_RUN.md](docs/OPEN_AND_RUN.md)**.  
Deployment quick reference: **[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md)**.  
Provider env checklist: **[docs/ENV_PROVIDERS.md](docs/ENV_PROVIDERS.md)**.  

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

Master Play Store launch & 1,000 CCU blueprint: **[docs/PLAYSTORE_PRODUCTION_GUIDE.md](docs/PLAYSTORE_PRODUCTION_GUIDE.md)**.  
Host API on a real domain: **[docs/HOSTING.md](docs/HOSTING.md)** (VPS) or **[docs/RAILWAY.md](docs/RAILWAY.md)** (Railway).  
Google Sign-In: **[docs/AUTH_GOOGLE.md](docs/AUTH_GOOGLE.md)**.  
Provider env checklist: **[docs/ENV_PROVIDERS.md](docs/ENV_PROVIDERS.md)**.

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

Point the app at your machine:

- Android emulator: `http://10.0.2.2:8000`
- Physical device (any network): public HTTPS tunnel — see [docs/OPEN_AND_RUN.md](docs/OPEN_AND_RUN.md) (`scripts/dev_tunnel.ps1`)
- Production / Play: `--dart-define=API_BASE_URL=https://speedquiz.app`

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
17. **Next** — Play Console upload (keystore + AAB) → internal test → production

See [docs/PROGRESS.md](docs/PROGRESS.md), [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md), and [docs/ENV_PROVIDERS.md](docs/ENV_PROVIDERS.md).

## Progression & engagement

- Calendar **daily streak** updates on quiz finish; Home 🔥 shows it
- Achievements evaluate on finish (`GET /api/v1/achievements`)
- XP level curve: need `level * 500` XP to advance
- **Daily challenge:** `GET/POST /api/v1/daily-challenge` (fixed questions, one clear/day)
- **Leaderboards:** `GET /api/v1/leaderboards?scope=weekly|daily` (Redis + Postgres)
- **Adaptive:** create session with `adaptive=true`; Elo-lite `skill_ratings` per topic
- **Analytics:** `analytics_events` table (`ANALYTICS_PROVIDER=postgres`)
- **Entitlements:** `GET /api/v1/entitlements/me` (caps off by default); Profile Free/Premium + paywall sheet
- **Auth:** guest bootstrap; Profile **Sign in with Google** (`POST /auth/google`) — see [docs/AUTH_GOOGLE.md](docs/AUTH_GOOGLE.md)
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
