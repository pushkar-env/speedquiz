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
- Achievements evaluate only on session finalize (not per-answer). `daily_completed` waits for Phase 5b.
- XP curve: spend `level * 500` XP to advance; Flutter XP bar matches.

## Decision: Entitlements later

`payments/entitlements.py` stubs free vs premium caps. `ENTITLEMENTS_ENFORCE_QUESTION_CAPS=false` keeps free unlimited until monetization ships.

## Risks

1. AI generation latency / cost for cold topics — mitigated by caching, chunking, watermarks, loading UX.
2. Enum proliferation in Postgres — keep shared enum types and migrations explicit.
3. Leaderboard hot paths — Redis sorted sets (Phase 5b), Postgres as source of truth.
4. OpenAI spend if periodic top-ups are too aggressive — tune `TOPIC_BANK_*` env knobs.
