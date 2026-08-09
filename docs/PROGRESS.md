# QuizVerse progress & goals

Last updated: 2026-08-10

## Vision

Ship a production-ready Android/iOS quiz game where AI prepares a **validated question bank**, and players get fast, fair, server-scored runs with strong game UX.

## North-star acceptance (MVP)

A real user can: open app → guest/account → pick topic/difficulty/mode → play timed MCQs → get server scores/streaks → results → create custom topic → get AI-validated questions → report bad items → see stats/achievements/leaderboard/daily (latter items land in Phase 5+).

## Completed

### Phase 1 — Foundation
- Monorepo + Docker (Postgres, Redis, API, worker)
- FastAPI modular app, Alembic, JWT guest/email auth
- Full core schema, seed topics/categories/achievements
- Flutter shell: Riverpod, GoRouter, Dio, design system, bottom nav

### Phase 2 — Gameplay
- Quiz sessions: create / answer / finish / result
- Modes: casual, speedrun, survival, negative, sudden death
- Curated question bank seed for offline play
- Server-authoritative scoring (base, speed, streak)

### Phase 3 — UX polish
- Inline correct/incorrect + Why on the same screen
- Speedrun 3s auto-advance; other modes Next / See results
- Home / Setup / Results / Explore / Profile polish

### Phase 4 — AI + custom
- LLM provider abstraction (`mock` + `openai`)
- Pipeline: generate → schema/AI validate → quality → dedupe → store
- Custom topics API + cache + free daily quota
- Teach Me + report endpoints (rate-limited)
- Worker job processing

### Bank scale (post–Phase 4)
- Prefer unseen questions per user/topic
- No in-session repeats while unused bank questions remain
- Sync fill when topic inventory is critically low
- Async chunk top-ups toward **1000 unique / topic**
- Entitlement stubs for future free-cap (~30) + premium/diamonds (**unlimited free today**)

### Phase 5a — Progression
- Calendar daily streak (`last_played_date` → `daily_streak`; Home 🔥)
- Lifetime answer streak kept on `profile.best_streak`
- Achievement evaluation on quiz finish + XP/coin rewards
- `GET /achievements` catalog with unlock status
- Flutter Profile achievements list + Results unlock cards
- XP bar uses `level * 500` threshold (matches backend)

### Phase 5b — Engagement
- UTC daily challenge: fixed ~10 medium questions, one completed attempt/day, resume ACTIVE
- `GET /daily-challenge`, `POST /daily-challenge/start` (mode `daily`, no endless append)
- Leaderboards: Redis ZSET + Postgres `LeaderboardEntry`; scopes `weekly` + `daily`
- `GET /leaderboards?scope=weekly|daily`; Flutter Leaderboard tabs + Home daily tile
- `daily_completed` / First Daily achievement enabled

### Phase 6a — Adaptive + analytics
- Per-topic Elo-lite in `skill_ratings`; Adaptive quiz start (`adaptive=true`)
- Casual mid-run difficulty nudges from last 5 answers
- `analytics_events` table + Postgres provider; events: quiz_started/finished, daily_started, achievement_unlocked

### Phase 6b — Entitlements foundation + share + anti-cheat
- Soft-cap plumbing wired into deal/refill (`unique_question_allowance`); caps still **off** by default
- `GET /entitlements/me` + `POST /entitlements/dev/premium` (non-prod / `ENTITLEMENTS_DEV_TOGGLE`)
- Flutter Profile Free/Premium badge + dev premium toggle; friendly cap errors on play
- Finalize `share_payload` (`text`, `deep_link`, `stats`); Results share card + `share_plus` sheet
- Anti-cheat: timing resolve for instant-correct claims, Redis ~3 answers/s rate limit, points clamp

### Phase 7a — Share deep links + paywall UX
- Public `GET /share/results/{session_id}` (safe fields only, no auth)
- Flutter `app_links` + `quizverse://results/{id}` → shared result screen; owner results fetch without `extra`
- `PremiumPaywallSheet` on entitlement cap + Profile Upgrade card (dev enable or Coming soon)

### Phase 7b — IAP foundation
- `POST /entitlements/purchases/verify` + `/restore`; upserts `subscriptions`, sets `user.is_premium`
- `BILLING_VERIFY_MODE=stub` (non-prod); `apple_google` uses store adapters (503 until credentials set)
- Flutter `in_app_purchase` BillingService; paywall Buy / Restore / stub-dev path

### Phase 7c — HTTPS share landing foundation
- Public HTML `GET /r/{session_id}` (Jinja score card + Open in QuizVerse deep link)
- `SHARE_PUBLIC_BASE_URL` adds `web_url` to finalize `share_payload` / share text
- Flutter deep-link mapper accepts `/r/{id}`

### Phase 8a — App Links / Universal Links foundation
- `GET /.well-known/assetlinks.json` + `apple-app-site-association` (503 until fingerprints / iOS app id set)
- Android HTTPS intent-filter `/r` with `autoVerify` (host `quizverse.app` placeholder)
- iOS `Runner.entitlements` Associated Domains `applinks:quizverse.app`

### Phase 8b — Store verification adapters
- `BILLING_VERIFY_MODE=apple_google` calls App Store Server API + Play Developer API adapters
- Missing `APPLE_IAP_*` / `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` → **503** (no fake grants)
- Stub mode remains default for local/CI; Flutter buy path unchanged

### Phase 8c — Production app identity
- Native application/bundle id → `com.quizverse.app` (Android, iOS, macOS, Linux)
- Backend defaults: `APP_LINK_ANDROID_PACKAGE`, `IAP_ANDROID_PACKAGE`, `APPLE_IAP_BUNDLE_ID`
- Caps still off; fingerprints / Team ID still env-only

## In progress / next

**Later:** Store Console products + RTDN/ASN webhooks; set signing fingerprints / Team ID; enable caps when monetizing.

## Release checklist (store launch)

1. Set `APP_LINK_ANDROID_SHA256_CERT_FINGERPRINTS` + `APP_LINK_IOS_APP_ID=TEAMID.com.quizverse.app`
2. Point `quizverse.app` DNS at the API; `SHARE_PUBLIC_BASE_URL=https://quizverse.app`
3. Create Play / App Store products matching `IAP_PREMIUM_PRODUCT_ID`
4. Fill Apple/Google verify secrets; `BILLING_VERIFY_MODE=apple_google`
5. Only then consider `ENTITLEMENTS_ENFORCE_QUESTION_CAPS=true`

## Architecture reminders

```text
AI workers / custom prep → validated questions (Postgres)
                         → gameplay APIs (no LLM)
                         → Flutter client
```

## Commit hygiene

- Never commit `.env` or API keys
- Prefer `.env.example` for documented knobs
- Suggested first commit scope: full Phase 1–4 scaffold + bank growth (see README)
