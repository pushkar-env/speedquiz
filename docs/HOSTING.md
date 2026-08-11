# Hosting SpeedQuiz API on a Real Domain

> **Master Blueprint**: For complete 1,000 CCU capacity planning, 3 hosting cost tiers ($0 No-Cost, $10–$20 Low-Cost, $60–$150+ Enterprise), and Google Play publishing steps, see **[PLAYSTORE_PRODUCTION_GUIDE.md](PLAYSTORE_PRODUCTION_GUIDE.md)**.

This document details hosting the SpeedQuiz backend API on an Ubuntu VPS with Docker Compose and Caddy.

---

## 1. Stack Architecture for 1,000 CCU

SpeedQuiz handles **1,000 Concurrent Active Users (250–500 RPS)** easily because live gameplay APIs read validated questions directly from PostgreSQL and Redis without live LLM calls.

```text
Phone / Play Build
        │  HTTPS
        ▼
speedquiz.app (Caddy Proxy :443)
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

### A. Uvicorn Worker Process Scaling

Worker count is read from `WEB_CONCURRENCY` (see `infrastructure/docker/Dockerfile.api`),
so on a 4-vCPU server just set it in `.env`:

```env
WEB_CONCURRENCY=4
```

Migrations take a Postgres advisory lock, so several replicas may boot at once
without racing Alembic against each other.

To override the command entirely instead:

```yaml
services:
  api:
    restart: always
    command: >
      sh -c "alembic upgrade head &&
             uvicorn app.main:app --host 0.0.0.0 --port 8000
             --workers 4 --limit-concurrency 1000 --backlog 2048
             --proxy-headers --forwarded-allow-ips='*'"
```

`--proxy-headers` matters behind Caddy: without it every request looks like it
came from the proxy's own IP.

### B. PostgreSQL Connection Pool Tuning

Set these in `.env` — they are read by `app/core/database.py`:

```env
DB_POOL_SIZE=5
DB_MAX_OVERFLOW=10
DB_POOL_TIMEOUT_SECONDS=30
DB_POOL_RECYCLE_SECONDS=1800
```

**Do the multiplication before you raise these.** Total server connections are:

```text
(DB_POOL_SIZE + DB_MAX_OVERFLOW) x uvicorn workers x replicas   + the worker service
```

With the defaults and `--workers 4`, that is `15 x 4 = 60` connections from the
API plus 15 from the background worker — comfortably inside PostgreSQL's default
`max_connections = 100`.

Small numbers are correct here, not timid. Async handlers only hold a connection
while a query is in flight, so real usage is roughly
`requests/sec x seconds of DB time per request`. At 200 RPS with ~20 ms of database
time that is about **4 concurrent connections**. Oversizing the pool does not buy
throughput; it just moves the failure from "wait briefly for a pooled connection"
to `FATAL: sorry, too many clients already`, which is an outage.

If you do raise the pool, raise `max_connections` in `postgresql.conf` to match
**and** give Postgres the RAM for it — every connection is a backend process.

Behind a transaction-mode pooler (PgBouncer, Supavisor, Neon's `-pooler`
endpoint), also set:

```env
DB_DISABLE_PREPARED_STATEMENTS=true
```

Connections are multiplexed between transactions there, so server-side prepared
statements must be off or queries fail with
`prepared statement "__asyncpg_stmt_x__" already exists` under load.

### C. Reverse Proxy Optimization (`infrastructure/Caddyfile`)
Enable gzip/zstd compression and keep-alive connection pooling:
```caddy
speedquiz.app {
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
git clone https://github.com/YOUR_USER/speedquiz.git /opt/speedquiz
cd /opt/speedquiz
cp .env.example .env

# Start production stack with Caddy HTTPS
docker compose \
  -f docker-compose.yml \
  -f docker-compose.prod.yml \
  -f docker-compose.caddy.yml \
  up --build -d

# Verify API health
curl -fsS https://speedquiz.app/health
```

For full setup procedures, see **[PLAYSTORE_PRODUCTION_GUIDE.md](PLAYSTORE_PRODUCTION_GUIDE.md)**.
