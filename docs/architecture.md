# QuizVerse Architecture & Scale Specifications

> **Single Source of Truth**: For complete 1,000 CCU capacity planning, 3 hosting cost tiers, test build procedures, and Play Store publishing details, see **[PLAYSTORE_PRODUCTION_GUIDE.md](PLAYSTORE_PRODUCTION_GUIDE.md)**.

---

## 1. Architectural Principles

1. **Question Bank Before Gameplay**: Live LLM calls are **never** made during active quiz sessions. All questions are pre-generated, validated, and stored in PostgreSQL by background workers (`workers.main`).
2. **High Concurrency & Low Latency**: Fast DB lookups, server-authoritative scoring, and Redis caching allow the backend to process **250 to 500 Requests Per Second (RPS)**, effortlessly supporting **1,000+ Concurrent Active Users (CCU)** at P99 latency `< 80ms`.
3. **Guest-First Authentication**: Anonymous JWT accounts are upgraded seamlessly when linked to Google Sign-In (`POST /api/v1/auth/google`).
4. **Resilient Rate-Limiting & Anti-Cheat**: Redis sliding window rate-limiting (~3 answers/sec max) and timing checks prevent automated cheating.
5. **Decoupled AI Watermark Top-Ups**: Asynchronous background jobs top up topic inventory toward target watermarks (~1,000 unique questions per topic).

---

## 2. 1,000 CCU Concurrency Model

```text
[ 1,000 Concurrent Mobile Players ]
                 │
                 │ 250 - 500 RPS (Answer / Session Requests)
                 ▼
[ Reverse Proxy / TLS Termination (Caddy / Cloudflare) ]
                 │
                 │ Load Balanced Internal HTTP
                 ▼
[ Multi-Worker FastAPI Backend (4 - 8 Uvicorn Processes) ]
        │                               │
        │ Async DB Pool (Asyncpg)       │ Redis Connection Pool
        ▼                               ▼
[ PostgreSQL 16 Cluster ]       [ Redis 7 ZSET Leaderboards ]
        ▲                               ▲
        │                               │
        └───── [ Async AI Workers ] ────┘
```

### Resource Sizing & Connection Pools

- **Web Workers**: 4 Uvicorn processes per 4 CPU cores (`uvicorn app.main:app --workers 4`).
- **PostgreSQL Connection Pool**: 25 connections per worker (`pool_size=25`, `max_overflow=25`), allowing up to 200 total active database connections.
- **Redis Connection Pool**: Max 500 connections for ZSET leaderboards, rate limits, and caching.

---

## 3. Core Subsystems

- **Quiz Engine**: `backend/app/quiz` (Session state machine, server-authoritative scoring, adaptive difficulty).
- **Leaderboard Engine**: `backend/app/leaderboard` (Dual-write Redis ZSET + PostgreSQL fallback).
- **Entitlements & Monetization**: `backend/app/payments` (Play Developer API verification, free/premium caps).
- **AI Pipeline**: `workers/` (LLM generation, schema validation, quality scoring, deduplication).
- **Mobile Client**: `mobile/` (Flutter 3.44+, Riverpod state management, Dio HTTP client with automatic JWT refresh retry, GoRouter navigation).

---

## 4. Documentation References

- **[PLAYSTORE_PRODUCTION_GUIDE.md](PLAYSTORE_PRODUCTION_GUIDE.md)** — Master Production & Play Store Release Blueprint.
- **[DEPLOYMENT.md](DEPLOYMENT.md)** — Pre-flight test builds & quick launch procedures.
- **[HOSTING.md](HOSTING.md)** — Server hosting & Caddy proxy setup.
- **[ENV_PROVIDERS.md](ENV_PROVIDERS.md)** — Environment variables & provider secrets checklist.
