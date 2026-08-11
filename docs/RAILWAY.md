# Deploy SpeedQuiz — step by step

End-to-end guide for putting the whole stack online with HTTPS, so the Android
app works on mobile data and you can drop the Cloudflare tunnel.

Two supported shapes:

| | Recommended | Railway-only |
|---|---|---|
| Postgres | **Neon** (free tier, built-in pooler, PITR backups) | Railway Postgres plugin |
| Redis | **Upstash** (free tier) | Railway Redis plugin |
| API + worker | Railway | Railway |
| Cost | ~$5–10/mo | ~$10–20/mo |
| Survives a DB restart | Yes | No failover |

The recommended shape is what the rest of this guide uses. Railway's database
plugins are single containers with no connection pooler and a thin backup
story — fine for a smoke test, not what you want holding real user progress.

VPS alternative: [HOSTING.md](HOSTING.md). Env meanings: [ENV_PROVIDERS.md](ENV_PROVIDERS.md).

```text
Phone ──HTTPS──► Railway `api` service ──► Neon Postgres (pooled)
                                       └─► Upstash Redis
                 Railway `worker` (private) ──► same DB + Redis + OpenAI
```

---

## 0. Before you start

- A GitHub repo with this project pushed
- Accounts: [Railway](https://railway.app), [Neon](https://neon.tech), [Upstash](https://upstash.com)
- An OpenAI API key (only the worker needs it — gameplay never calls an LLM)
- A JWT secret:

```bash
openssl rand -hex 32
```

Keep that value. The API **refuses to boot** in production with the placeholder
secret, by design.

---

## 1. Postgres on Neon

1. [console.neon.tech](https://console.neon.tech) → **New Project** → pick the region closest to your users.
2. Open **Connection Details**.
3. Toggle **Connection pooling ON**. The host gains a `-pooler` suffix — you want that one.

You get something like:

```text
postgresql://neondb_owner:PASSWORD@ep-cool-thing-123456-pooler.us-east-2.aws.neon.tech/neondb?sslmode=require
```

This project needs two variants of it, because SQLAlchemy picks its driver from
the URL scheme:

| Variable | Scheme | Used by |
|---|---|---|
| `DATABASE_URL` | `postgresql+asyncpg://` | the app at runtime |
| `DATABASE_URL_SYNC` | `postgresql+psycopg://` | Alembic migrations |

**Drop the query string from the asyncpg URL.** SQLAlchemy forwards `sslmode`
and `channel_binding` verbatim to `asyncpg.connect()`, which accepts neither —
you get `TypeError: connect() got an unexpected keyword argument 'sslmode'` at
connect time, which reads like an outage rather than a typo. Nothing is lost:
asyncpg negotiates TLS itself. Keep the parameters on the `psycopg` URL, which
does understand them.

Rather than editing by hand, let the script do it:

```bash
python scripts/split_db_url.py "postgresql://user:pass@ep-...-pooler.../neondb?sslmode=require"
```

It prints all three variables ready to paste, and warns if you copied the
direct endpoint instead of the pooled one.

```env
DATABASE_URL=postgresql+asyncpg://neondb_owner:PASSWORD@ep-...-pooler.us-east-2.aws.neon.tech/neondb
DATABASE_URL_SYNC=postgresql+psycopg://neondb_owner:PASSWORD@ep-...-pooler.us-east-2.aws.neon.tech/neondb?sslmode=require
DB_DISABLE_PREPARED_STATEMENTS=true
```

That last flag is **required** on a pooled endpoint. Connections are multiplexed
between transactions, so server-side prepared statements have to be off or you
get `prepared statement "__asyncpg_stmt_x__" already exists` once traffic
overlaps.

> Neon's free tier scales to zero. The first request after an idle period pays
> a ~1s cold start. Fine for testing; upgrade when it stops being fine.

---

## 2. Redis on Upstash

1. [console.upstash.com](https://console.upstash.com) → **Create Database** → same region as Neon.
2. Copy the connection details.

Upstash often shows the credentials as a `redis-cli` invocation:

```text
redis-cli --tls -u redis://default:TOKEN@fair-bluejay-111963.upstash.io:6379
```

**Do not paste that URL as-is.** `redis-cli` takes TLS as a separate `--tls`
flag, but redis-py derives it from the **scheme** — `redis://` builds a plain
`Connection`, `rediss://` builds an `SSLConnection`. Upstash refuses plaintext,
so a single-`s` URL fails with `ConnectionError: Connection closed by server`.

Take the URL, add the second `s`, drop the flag:

```env
REDIS_URL=rediss://default:TOKEN@fair-bluejay-111963.upstash.io:6379
```

Redis holds rate limits, leaderboard sorted sets and generation locks. It is not
the source of truth for anything: losing it degrades ranking freshness, not data.

---

## 3. Railway project + API service

1. Railway → **New Project** → **Deploy from GitHub repo** → select this repo.
2. Rename the created service to **`api`**.
3. **Settings → Build**:
   - Builder: **Dockerfile**
   - Dockerfile path: `infrastructure/docker/Dockerfile.api`
   - Root directory: **leave empty** (the Dockerfile does `COPY backend`, so it needs repo root as build context)
4. **Settings → Networking** → **Generate Domain**. You get `https://api-production-xxxx.up.railway.app`.
5. **Settings → Deploy**:
   - Health check path: `/health`
   - Health check timeout: `120` (first boot runs migrations and seeding)

Do **not** override the start command. The Dockerfile already runs migrations
then uvicorn on Railway's `$PORT`, with `--proxy-headers` set so client IPs
survive Railway's proxy.

---

## 4. Worker service

1. **+ New** → **GitHub Repo** → same repo → rename to **`worker`**.
2. **Settings → Build**:
   - Builder: **Dockerfile**
   - Dockerfile path: `infrastructure/docker/Dockerfile.worker`
3. **Networking**: no domain. It is a polling loop, not an HTTP service.
4. One replica is enough — it takes Redis locks per topic, but there is no
   benefit to running several.

---

## 5. Environment variables

Set these on **both** `api` and `worker` unless marked otherwise. Railway's
**Variables → Raw Editor** accepts this whole block pasted at once.

```env
# --- Core ---
APP_NAME=SpeedQuiz
APP_ENV=production
DEBUG=false
API_PREFIX=/api/v1
LOG_LEVEL=INFO
CORS_ORIGINS=*

# --- Secrets ---
JWT_SECRET=<paste openssl rand -hex 32 output>
JWT_ALGORITHM=HS256
JWT_ACCESS_TOKEN_EXPIRE_MINUTES=60
JWT_REFRESH_TOKEN_EXPIRE_DAYS=30

# --- Data ---
DATABASE_URL=postgresql+asyncpg://...-pooler.../neondb
DATABASE_URL_SYNC=postgresql+psycopg://...-pooler.../neondb?sslmode=require
DB_DISABLE_PREPARED_STATEMENTS=true
DB_POOL_SIZE=5
DB_MAX_OVERFLOW=10
REDIS_URL=rediss://default:...@....upstash.io:6379

# --- Runtime ---
WEB_CONCURRENCY=2

# --- AI (worker needs this; api can have it too) ---
LLM_PROVIDER=openai
LLM_API_KEY=sk-...
LLM_MODEL_GENERATE=gpt-4o-mini
LLM_MODEL_VALIDATE=gpt-4o-mini
LLM_MODEL_CLASSIFY=gpt-4o-mini

# --- Product flags ---
ENTITLEMENTS_ENFORCE_QUESTION_CAPS=false
ENTITLEMENTS_DEV_TOGGLE=false
FREE_UNIQUE_QUESTIONS_PER_TOPIC=30
BILLING_VERIFY_MODE=stub
BILLING_ALLOW_STUB_IN_PRODUCTION=false
IAP_PREMIUM_PRODUCT_ID=speedquiz_premium
IAP_ANDROID_PACKAGE=com.speedquiz.app
ANALYTICS_PROVIDER=postgres

# --- Public URL (api; set after step 3 gives you a domain) ---
SHARE_PUBLIC_BASE_URL=https://api-production-xxxx.up.railway.app
APP_LINK_ANDROID_PACKAGE=com.speedquiz.app
APP_LINK_ANDROID_SHA256_CERT_FINGERPRINTS=
APP_LINK_IOS_APP_ID=

# --- Optional ---
GOOGLE_CLIENT_ID=
SENTRY_DSN=
```

### Three settings that will refuse to boot production

The app validates these at startup rather than running insecurely:

| Setting | Why it fails |
|---|---|
| `JWT_SECRET` still the placeholder, or under 32 chars | anyone could forge tokens |
| `ENTITLEMENTS_DEV_TOGGLE=true` | exposes `POST /entitlements/dev/premium` — free Premium for any user |
| `DEBUG=true` | verbose errors and SQL echo in production |

If the container exits immediately after deploy, read the logs — the error names
the exact problem.

---

## 6. Deploy and verify

Trigger a deploy on `api`, then `worker`.

Watch the `api` logs for, in order: Alembic migrations, `seed_complete`,
then Uvicorn listening.

```bash
curl https://YOUR-API.up.railway.app/health
```

```bash
curl https://YOUR-API.up.railway.app/ready
```

`/ready` returns **200** with `{"status":"ready","database":true,"redis":true}`
when healthy, and **503** when either dependency is down — so Railway's health
check actually pulls a broken instance out of rotation.

Confirm the catalog seeded:

```bash
curl https://YOUR-API.up.railway.app/api/v1/topics
```

You should get 18 topics. If `items` is empty, check the logs for `seed_failed`.

> With multiple replicas, only one runs the seed — the others log
> `seed_skipped_lock_held_by_another_replica`. That is correct behaviour, not
> an error.

Finally, open `/health` in the **phone's browser** before touching the app. It
separates "backend unreachable" from "app misconfigured".

---

## 7. Point the app at it

```bash
flutter build apk --release --dart-define=API_BASE_URL=https://YOUR-API.up.railway.app
```

With Google Sign-In (see [AUTH_GOOGLE.md](AUTH_GOOGLE.md)):

```bash
flutter build apk --release --dart-define=API_BASE_URL=https://YOUR-API.up.railway.app --dart-define=GOOGLE_SERVER_CLIENT_ID=YOUR-WEB-CLIENT-ID.apps.googleusercontent.com
```

Install it and play a run. If topics load and a quiz scores, the stack is wired
correctly end to end.

---

## 8. Load test before you trust it

Never take a capacity claim on faith — including the ones in these docs.

Install [k6](https://k6.io/docs/get-started/installation/), then:

```bash
k6 run -e BASE_URL=https://YOUR-API.up.railway.app scripts/loadtest.js
```

Simulate 1,000 concurrent players:

```bash
k6 run -e BASE_URL=https://YOUR-API.up.railway.app -e PROFILE=peak scripts/loadtest.js
```

Find where it actually breaks:

```bash
k6 run -e BASE_URL=https://YOUR-API.up.railway.app -e PROFILE=breakpoint scripts/loadtest.js
```

The script runs the real journey — guest auth, topics, session, ten answers with
human think time, finish, leaderboard. Thresholds fail the run if answer latency
p95 exceeds 400 ms or the error rate exceeds 1%.

**This writes real guest accounts and sessions.** Point it at a staging Neon
branch, not the database your users are on. Neon branching makes that a
one-click copy.

Reading the output: VUs are not RPS. A player answers every 6–13 s, so 1,000 VUs
is roughly 100–150 req/s — which is what 1,000 real concurrent users looks like.

---

## 9. Scaling when you need it

Do this in order, and only in response to numbers from §8.

1. **`WEB_CONCURRENCY=4`** on a larger `api` instance. Cheapest win.
2. **Railway replicas** (Settings → Replicas). Stateless, so this is safe —
   migrations are advisory-locked and seeding is idempotent.
3. **Watch connection maths** every time you scale:
   ```text
   (DB_POOL_SIZE + DB_MAX_OVERFLOW) x WEB_CONCURRENCY x replicas + worker
   ```
   Behind Neon's pooler you have plenty of headroom, but the number is still
   worth knowing.
4. **Neon compute size** when database CPU is the bottleneck.

The worker does not need scaling. It is a background top-up loop; it can be down
for an hour and gameplay is unaffected because questions are served from the
bank.

---

## 10. Custom domain

1. Railway → `api` → **Settings → Networking → Custom Domain** → add `api.yourdomain.com`.
2. Create the CNAME Railway shows you at your DNS provider.
3. Wait for the certificate to go **Active**.
4. Update `SHARE_PUBLIC_BASE_URL` to the new HTTPS URL and redeploy, so share
   links and the App Links association file use it.
5. Rebuild the app with the new `API_BASE_URL`.

Railway terminates TLS for you. Do not run Caddy here — that is only for the VPS
path in [HOSTING.md](HOSTING.md).

---

## 11. Backups and operations

- **Neon** keeps automatic history; set the retention window in project settings and confirm point-in-time restore works *before* you need it.
- **Upstash** persistence is on by default; nothing here is irreplaceable.
- **Railway** keeps deploy history — use **Rollback** rather than force-pushing a fix.
- Set `SENTRY_DSN` once you have real users. Unhandled exceptions already log with a request id (`X-Request-ID`, echoed on every response) — Sentry just makes them findable.

---

## 12. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Container exits instantly, log says "Unsafe production configuration" | Read the listed items — placeholder `JWT_SECRET`, `ENTITLEMENTS_DEV_TOGGLE=true`, or `DEBUG=true` |
| `TypeError: connect() got an unexpected keyword argument 'sslmode'` | `?sslmode=` (or `channel_binding=`) left on the **asyncpg** URL. SQLAlchemy forwards it to `asyncpg.connect()`, which has no such keyword. Strip the query string there; keep it on `DATABASE_URL_SYNC`. `scripts/split_db_url.py` does this for you |
| `prepared statement "__asyncpg_stmt_x__" already exists` | Pooled endpoint without `DB_DISABLE_PREPARED_STATEMENTS=true` |
| `FATAL: sorry, too many clients already` | Connection maths in §9.3 exceeded, or you are on a direct (non-pooled) endpoint |
| Build fails on `COPY backend` | Root directory set on the service — clear it, the build context must be repo root |
| 502 from Railway | App not listening on `$PORT`. Do not override the start command |
| `/api/v1/topics` returns `{"items": []}` | Seeding failed — grep logs for `seed_failed` |
| `/ready` returns 503 | `database` / `redis` in the body tells you which one; check that service's URL |
| Redis: `ConnectionError: Connection closed by server` | `redis://` instead of `rediss://`. Upstash refuses plaintext; redis-py picks TLS from the scheme, not a flag |
| Redis: `SSL: CERTIFICATE_VERIFY_FAILED ... certificate has expired` **locally only** | Your machine's Python trust store has a stale root CA — not an Upstash problem. Run with `SSL_CERT_FILE=$(python -c "import certifi;print(certifi.where())")`. Linux containers on Railway ship current CAs and are unaffected |
| Worker idle, bank never grows | `LLM_API_KEY` missing on **worker**, or the service is not deployed |
| App times out on the phone | APK still built against the old tunnel/LAN URL — rebuild with `API_BASE_URL` |
| Google Sign-In cancels immediately | `GOOGLE_SERVER_CLIENT_ID` missing at build time, or SHA-1 not registered — see [AUTH_GOOGLE.md](AUTH_GOOGLE.md) |

---

## 13. Checklist

- [ ] Neon project, **pooled** connection string, both URL variants set
- [ ] `DB_DISABLE_PREPARED_STATEMENTS=true`
- [ ] Upstash Redis, `rediss://` URL
- [ ] `api` service — Dockerfile.api, public domain, `/health` check
- [ ] `worker` service — Dockerfile.worker, private
- [ ] `JWT_SECRET` from `openssl rand -hex 32`
- [ ] `APP_ENV=production`, `DEBUG=false`, `ENTITLEMENTS_DEV_TOGGLE=false`
- [ ] `SHARE_PUBLIC_BASE_URL` = public HTTPS URL
- [ ] `/health` and `/ready` green from the phone's browser
- [ ] `/api/v1/topics` returns a seeded catalog
- [ ] APK built with matching `API_BASE_URL`, quiz plays end to end
- [ ] k6 smoke run passes against the deployment
- [ ] (Later) custom domain, Play SHA-256 fingerprints, `BILLING_VERIFY_MODE=apple_google`
