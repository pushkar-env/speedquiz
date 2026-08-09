# QuizVerse architecture

## Decision: Question bank before gameplay

Gameplay APIs read validated `questions` rows. LLM calls happen only in workers / custom-topic preparation / rare sync fill for cold topics.

## Decision: Guest-first auth

Anonymous JWT accounts are first-class. Access + refresh tokens; refresh rotates with unique `jti`. Dio retries once on 401 after refresh.

## Decision: Server-authoritative scoring

`ScoringService` awards points. Clients send selected option index + client elapsed hint. Server must **not** start the question clock when preparing `next_question` (feedback reading time must not force timeouts).

## Decision: Endless unique via watermark top-up

- Target ~1000 unique active questions per topic, then reshuffle-reuse is acceptable.
- Low watermark triggers async `bank_topup` generation jobs (chunk size ~20).
- Sessions exclude already-used question IDs in the run while unused bank items exist.
- Critically thin topics may sync-fill one chunk at session start so the first hand is not repetitive.

## Decision: Progression (Phase 5a)

- `daily_streak` is calendar play streak; Home 🔥 uses it. `best_streak` on profile is lifetime answer streak.
- Achievements evaluate only on session finalize (not per-answer).
- XP curve: spend `level * 500` XP to advance; Flutter XP bar matches.

## Decision: Daily + leaderboards (Phase 5b)

- Daily challenge is bank-only (no LLM): same seeded question IDs for UTC day; one completed attempt; resume ACTIVE.
- Leaderboards dual-write Redis ZSET (hot) + Postgres `leaderboards` (durable). Scopes: weekly ISO week + daily date.
- Score = best `final_score` per user per board.

## Decision: Adaptive + analytics (Phase 6a)

- Per-topic Elo-lite in `player_statistics.skill_ratings`; Adaptive sessions pick start difficulty server-side.
- Casual + adaptive mid-run nudges from rolling last-5 accuracy (no LLM).
- Product events land in `analytics_events` (best-effort); never on the answer hot path.

## Decision: Entitlements + share (Phase 6b / 7a / 7b / 7c / 8a / 8b / 8c)

`payments/entitlements.py` + `GET /entitlements/me` wire free vs premium caps. `ENTITLEMENTS_ENFORCE_QUESTION_CAPS=false` keeps free unlimited until monetization ships. Deal path raises `entitlement_unique_cap` when enforced. Anti-cheat helpers live in `services/anticheat.py` (timing, rate limit, points clamp). Finalize stores rich `share_payload` (`text`, `deep_link`, `web_url?`, `stats`). Public `GET /share/results/{session_id}` exposes safe share-card fields only (no auth). Custom scheme `quizverse://results/{id}` opens the shared result screen. Public HTML landing `GET /r/{session_id}` (set `SHARE_PUBLIC_BASE_URL` to include `web_url` in share text). Association files: `GET /.well-known/assetlinks.json` and `apple-app-site-association` (503 until `APP_LINK_ANDROID_SHA256_CERT_FINGERPRINTS` / `APP_LINK_IOS_APP_ID` set); Android HTTPS `/r` autoVerify + iOS Associated Domains stub for `quizverse.app`. App / IAP identity: `com.quizverse.app`. Purchases: `POST /entitlements/purchases/verify` upserts `subscriptions` and sets `is_premium`; `BILLING_VERIFY_MODE=stub` for non-prod, or `apple_google` via App Store Server API / Play Developer API adapters (`APPLE_IAP_*`, `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` — empty → 503). Live store products + RTDN still later.

## Risks

1. AI generation latency / cost for cold topics — mitigated by caching, chunking, watermarks, loading UX.
2. Enum proliferation in Postgres — keep shared enum types and migrations explicit.
3. Leaderboard hot paths — Redis sorted sets with Postgres fallback.
4. OpenAI spend if periodic top-ups are too aggressive — tune `TOPIC_BANK_*` env knobs.
