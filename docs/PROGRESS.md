# SpeedQuiz Progress & Production Roadmap

Last updated: 2026-08-10

## Vision

Ship a production-ready Android/iOS quiz game where AI prepares a **validated question bank**, and players get fast, fair, server-scored runs with strong game UX.

---

## Completed Phases

### Phase 1 — Foundation ✅
- Monorepo + Docker (Postgres, Redis, API, worker).
- FastAPI modular app, Alembic, JWT guest/email auth.
- Full core schema, seed topics/categories/achievements.
- Flutter shell: Riverpod, GoRouter, Dio, design system, bottom nav.

### Phase 2 — Gameplay ✅
- Quiz sessions: create / answer / finish / result.
- Modes: casual, speedrun, survival, negative, sudden death.
- Curated question bank seed for offline play.
- Server-authoritative scoring (base, speed, streak).

### Phase 3 — UX Polish ✅
- Inline correct/incorrect + Why on the same screen.
- Speedrun 3s auto-advance; other modes Next / See results.
- Home / Setup / Results / Explore / Profile polish.

### Phase 4 — AI + Custom Topics ✅
- LLM provider abstraction (`mock` + `openai`).
- Pipeline: generate → schema/AI validate → quality → dedupe → store.
- Custom topics API + cache + free daily quota.
- Teach Me + report endpoints (rate-limited).
- Worker job processing.

### Bank Scale ✅
- Prefer unseen questions per user/topic.
- No in-session repeats while unused bank questions remain.
- Sync fill when topic inventory is critically low.
- Async chunk top-ups toward **1,000 unique / topic**.

### Phase 5a & 5b — Progression & Engagement ✅
- Calendar daily streak (`last_played_date` → `daily_streak`; Home 🔥).
- Lifetime answer streak kept on `profile.best_streak`.
- UTC daily challenge: fixed ~10 medium questions, one completed attempt/day.
- Leaderboards: Redis ZSET + Postgres `LeaderboardEntry`; weekly & daily scopes.

### Phase 6a & 6b — Adaptive, Entitlements & Share ✅
- Per-topic Elo-lite adaptive quiz start.
- `GET /entitlements/me` + soft-cap plumbing (`unique_question_allowance`).
- Finalize `share_payload` + Results share card.
- Anti-cheat timing resolve & rate limiting.

### Phase 7a, 7b, 7c — Deep Links, IAP & Web Landing ✅
- Public `GET /share/results/{session_id}` and HTML landing `GET /r/{session_id}`.
- Deep link `speedquiz://results/{id}`.
- Store verification adapters (`BILLING_VERIFY_MODE=apple_google`).

### Phase 8a, 8b, 8c, 8d — App Identity & Release Readiness ✅
- Native application ID set to **`com.speedquiz.app`**.
- Release signing via `mobile/android/key.properties`.
- Production Docker overlays (`docker-compose.prod.yml`, `docker-compose.caddy.yml`).

### Phase 8e — Master 1,000 CCU & Play Store Documentation ✅
- **[PLAYSTORE_PRODUCTION_GUIDE.md](PLAYSTORE_PRODUCTION_GUIDE.md)**: Created master source-of-truth document covering:
  - 1,000 CCU performance tuning & database pool formulas.
  - Interactive Test Build workflow (Google Sign-In, AI Custom topics, Stub/Sandbox IAP, App Links).
  - 3 Hosting Tiers ($0 No-Cost, $10–$20 Low-Cost, $60–$150+ Real Production).
  - Google Play Console end-to-end publishing guide.
  - Automated k6 load test scripts & verification matrix.

---

## Active Go-Live Phase: Play Store Upload & Launch

1. **Upload Keystore**: Generate `upload-keystore.jks` and extract SHA-1 / SHA-256 fingerprints.
2. **Build Test Release APK/AAB**: Run `flutter build appbundle --release --dart-define=API_BASE_URL=https://speedquiz.app`.
3. **Deploy Backend (Option A, B, or C)**: Tune database connection pools (`pool_size=25`) and Uvicorn workers (`--workers 4`).
4. **Link Google Services**: Set up Google Cloud OAuth 2.0 Web Client ID, Play Developer API Service Account JSON, and App Links fingerprints.
5. **Play Console Release**: Submit AAB to Internal Testing -> Closed Testing -> Production.

---

## Master Documentation Source of Truth

- **[PLAYSTORE_PRODUCTION_GUIDE.md](PLAYSTORE_PRODUCTION_GUIDE.md)** — Master Production & Launch Guide.
- **[DEPLOYMENT.md](DEPLOYMENT.md)** — Deployment Quick Reference.
- **[HOSTING.md](HOSTING.md)** — Docker Compose & Caddy Setup.
- **[ENV_PROVIDERS.md](ENV_PROVIDERS.md)** — Environment Variables & Secrets.
- **[AUTH_GOOGLE.md](AUTH_GOOGLE.md)** — Google Sign-In Setup.
- **[architecture.md](architecture.md)** — System Architecture & Concurrency Model.
