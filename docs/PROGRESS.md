# QuizVerse progress & goals

Last updated: 2026-08-09

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

## In progress / next

**Phase 5b (next):** leaderboards (Redis + Postgres), daily challenge, `daily_completed` achievement.

**Phase 6:** adaptive difficulty, analytics events, StoreKit/Play Billing, sharing, anti-cheat hardening.

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
