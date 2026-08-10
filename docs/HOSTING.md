# Hosting QuizVerse API on a Real Domain

> **Master Blueprint**: For complete 1,000 CCU capacity planning, 3 hosting cost tiers ($0 No-Cost, $10–$20 Low-Cost, $60–$150+ Enterprise), and Google Play publishing steps, see **[PLAYSTORE_PRODUCTION_GUIDE.md](PLAYSTORE_PRODUCTION_GUIDE.md)**.

This document details hosting the QuizVerse backend API on an Ubuntu VPS with Docker Compose and Caddy.

---

## 1. Stack Architecture for 1,000 CCU

QuizVerse handles **1,000 Concurrent Active Users (250–500 RPS)** easily because live gameplay APIs read validated questions directly from PostgreSQL and Redis without live LLM calls.

```text
Phone / Play Build
        │  HTTPS
        ▼
quizverse.app (Caddy Proxy :443)
        │  HTTP Internal
        ▼
api :8000 (4 Uvicorn Workers)  ──►  PostgreSQL 16 (Tuned Pool) + Redis 7
worker (AI Background Top-Up) ──►  PostgreSQL 16 + Redis 7 (+ OpenAI API)
```

---

## 2. Server Sizing Recommendations

| Tier | Spec / Provider | Cost | Target CCU |
| :--- | :--- | :--- | :--- |
| **No-Cost Tier** | Oracle Cloud Always Free (4 ARM vCPU, 24 GB RAM) | **$0 / mo** | **1,000 CCU** |
| **Low-Cost Tier** | Hetzner CPX31 / DigitalOcean (4 vCPU, 8 GB RAM) | **~$14–$24 / mo** | **1,000–1,500 CCU** |
| **Real Production Tier** | GCP Cloud Run / AWS ECS + Managed Postgres & Redis | **$60–$150+ / mo** | **3,000+ CCU (Auto-scaling)** |

---

## 3. High Concurrency Configuration Checklist (1,000 CCU)

### A. Uvicorn Worker Process Scaling (`docker-compose.prod.yml`)
Run **4 Uvicorn worker processes** on a 4-vCPU server:
```yaml
services:
  api:
    restart: always
    command: >
      sh -c "alembic upgrade head &&
             uvicorn app.main:app --host 0.0.0.0 --port 8000 --workers 4 --limit-concurrency 1000 --backlog 2048"
```

### B. PostgreSQL Connection Pool Tuning
In `.env` or database configuration:
- `pool_size = 25` per worker (100 base connections total).
- `max_overflow = 25` per worker (up to 200 total peak connections).
- Ensure PostgreSQL `max_connections` is set to `250` or higher in `postgresql.conf`.

### C. Reverse Proxy Optimization (`infrastructure/Caddyfile`)
Enable gzip/zstd compression and keep-alive connection pooling:
```caddy
quizverse.app {
    encode zstd gzip

    handle /api/* {
        reverse_proxy api:8000 {
            transport http {
                keepalive 75s
                keepalive_idle_conns 100
            }
        }
    }

    handle {
        reverse_proxy api:8000
    }
}
```

---

## 4. Operational Deployment Commands

```bash
# Clone repo & create production .env
git clone https://github.com/YOUR_USER/quizverse.git /opt/quizverse
cd /opt/quizverse
cp .env.example .env

# Start production stack with Caddy HTTPS
docker compose \
  -f docker-compose.yml \
  -f docker-compose.prod.yml \
  -f docker-compose.caddy.yml \
  up --build -d

# Verify API health
curl -fsS https://quizverse.app/health
```

For full setup procedures, see **[PLAYSTORE_PRODUCTION_GUIDE.md](PLAYSTORE_PRODUCTION_GUIDE.md)**.
