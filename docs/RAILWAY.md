# Deploy QuizVerse on Railway

Railway gives you **HTTPS out of the box** (no Caddy/VPS required). You run **four pieces**:

| Railway resource | Role | Public? |
|------------------|------|---------|
| **Postgres** plugin | Database | No |
| **Redis** plugin | Cache / rate limits / leaderboards | No |
| **api** service | FastAPI | Yes (HTTPS URL) |
| **worker** service | Background AI / bank top-ups | No |

Flutter talks only to the **api** HTTPS URL.

```text
Phone
  │ HTTPS
  ▼
api.up.railway.app  (or custom domain)
  ├── Postgres
  └── Redis
worker (private) ──► Postgres + Redis + OpenAI
```

VPS alternative: [HOSTING.md](HOSTING.md). Env meanings: [ENV_PROVIDERS.md](ENV_PROVIDERS.md).

---

## Prerequisites

- [Railway](https://railway.app) account
- This repo on GitHub/GitLab (or Railway CLI deploy from local)
- OpenAI API key (for generation; gameplay itself does not call the LLM)

---

## 1. Create a Railway project

1. Dashboard → **New Project**
2. **Deploy from GitHub** → select the QuizVerse repo  
   (or empty project and add services manually)

You will add **Postgres**, **Redis**, then two services from the same repo (`api` + `worker`).

---

## 2. Add Postgres

1. In the project → **+ New** → **Database** → **PostgreSQL**
2. Open the Postgres service → **Variables**
3. Note `DATABASE_URL` (Railway format looks like  
   `postgresql://postgres:…@….railway.internal:5432/railway`)

You will **not** paste that raw into the app as-is — FastAPI needs SQLAlchemy dialects (next section).

---

## 3. Add Redis

1. **+ New** → **Database** → **Redis**
2. Note `REDIS_URL` / `REDIS_PRIVATE_URL`  
   Prefer the **private** URL when both api and worker are in the same Railway project (cheaper, internal networking).

---

## 4. Create the API service

1. **+ New** → **GitHub Repo** (same QuizVerse repo) — name it **`api`**
2. **Settings** → **Build**:
   - **Builder:** Dockerfile
   - **Dockerfile path:** `infrastructure/docker/Dockerfile.api`
   - **Watch paths / root:** repository root (so `COPY backend` works)
3. **Settings** → **Networking**:
   - **Generate domain** (gives `https://something.up.railway.app`)
   - Or attach a **custom domain** (see §8)
4. **Settings** → **Health check** (optional): path `/health`
5. Do **not** override the start command unless needed — the Dockerfile runs:

```text
alembic upgrade head && uvicorn … --port $PORT
```

Railway sets `PORT` automatically.

---

## 5. Create the worker service

1. **+ New** → **GitHub Repo** (same repo) — name it **`worker`**
2. **Settings** → **Build**:
   - **Builder:** Dockerfile
   - **Dockerfile path:** `infrastructure/docker/Dockerfile.worker`
3. **Networking:** leave **private** (no public domain)
4. Start command is already `python -m workers.main` in the Dockerfile

---

## 6. Environment variables

Set variables on **both** `api` and `worker` unless noted.  
In Railway you can use **variable references** (e.g. `${{Postgres.DATABASE_URL}}`) so you don’t copy secrets by hand.

### 6.1 Database URLs (required)

Railway’s `DATABASE_URL` is usually `postgresql://…`.  
QuizVerse needs:

| Variable | Value |
|----------|--------|
| `DATABASE_URL` | Same URL with scheme **`postgresql+asyncpg://`** |
| `DATABASE_URL_SYNC` | Same URL with scheme **`postgresql+psycopg://`** |

**How to set in Railway (recommended):**

1. On **api** (and **worker**), add:

```env
DATABASE_URL=${{Postgres.DATABASE_URL}}
DATABASE_URL_SYNC=${{Postgres.DATABASE_URL}}
```

2. Then either:

**Option A — shared variable + two overrides**  
Create a project shared var is awkward for scheme swap. Easier:

**Option B — explicit transforms** (set once after copying from Postgres):

If Postgres gives:

```text
postgresql://postgres:SECRET@host:5432/railway
```

Set:

```env
DATABASE_URL=postgresql+asyncpg://postgres:SECRET@host:5432/railway
DATABASE_URL_SYNC=postgresql+psycopg://postgres:SECRET@host:5432/railway
```

Use the **internal** host (`.railway.internal`) for api/worker in the same project. Use the **public** proxy URL only if connecting from outside Railway.

### 6.2 Redis (required)

```env
REDIS_URL=${{Redis.REDIS_URL}}
```

If the plugin exposes `REDIS_PRIVATE_URL`, prefer that for api/worker.

### 6.3 Core app (required on api + worker)

```env
APP_NAME=QuizVerse
APP_ENV=production
DEBUG=false
API_PREFIX=/api/v1
LOG_LEVEL=INFO

# Long random string (openssl rand -hex 32)
JWT_SECRET=
JWT_ALGORITHM=HS256
JWT_ACCESS_TOKEN_EXPIRE_MINUTES=60
JWT_REFRESH_TOKEN_EXPIRE_DAYS=30

# Restrict if you have a web origin; mobile apps don’t need CORS wide open
CORS_ORIGINS=*

LLM_PROVIDER=openai
LLM_API_KEY=
LLM_MODEL_GENERATE=gpt-4o-mini
LLM_MODEL_VALIDATE=gpt-4o-mini
LLM_MODEL_CLASSIFY=gpt-4o-mini

ENTITLEMENTS_ENFORCE_QUESTION_CAPS=false
ENTITLEMENTS_DEV_TOGGLE=false
FREE_UNIQUE_QUESTIONS_PER_TOPIC=30

BILLING_VERIFY_MODE=stub
BILLING_ALLOW_STUB_IN_PRODUCTION=false
IAP_PREMIUM_PRODUCT_ID=quizverse_premium
IAP_ANDROID_PACKAGE=com.quizverse.app

ANALYTICS_PROVIDER=postgres
```

Generate `JWT_SECRET` locally:

```bash
openssl rand -hex 32
```

### 6.4 Public URL (required on api; useful on worker too)

After Railway generates a domain (or you attach a custom one):

```env
# Temporary Railway domain example:
SHARE_PUBLIC_BASE_URL=https://your-api.up.railway.app

# After custom domain:
# SHARE_PUBLIC_BASE_URL=https://quizverse.app
```

Also set App Link package (fingerprints later when Play signing exists):

```env
APP_LINK_ANDROID_PACKAGE=com.quizverse.app
APP_LINK_ANDROID_SHA256_CERT_FINGERPRINTS=
APP_LINK_IOS_APP_ID=
```

### 6.5 Optional / later

```env
# Google Sign-In (Web client ID) — see AUTH_GOOGLE.md
GOOGLE_CLIENT_ID=

GOOGLE_PLAY_SERVICE_ACCOUNT_JSON=
APPLE_IAP_ISSUER_ID=
APPLE_IAP_KEY_ID=
APPLE_IAP_PRIVATE_KEY=
APPLE_IAP_BUNDLE_ID=com.quizverse.app
APPLE_IAP_ENVIRONMENT=Production
SENTRY_DSN=
```

When Play billing is live: set the Google JSON and `BILLING_VERIFY_MODE=apple_google`.

### 6.6 Variables only the API needs publicly

All of the above can live on both services. The **worker** must have DB, Redis, JWT (if shared code paths), and **LLM_*** keys. The worker does not need a public domain.

---

## 7. Deploy and verify

1. Trigger **Deploy** on `api` and `worker` (or push to the connected branch).
2. Open **api** → **HTTP Logs**; confirm Alembic + Uvicorn start.
3. Visit:

```text
https://YOUR-API.up.railway.app/health
https://YOUR-API.up.railway.app/ready
https://YOUR-API.up.railway.app/docs
```

4. On a phone (any network): open `/health` in the browser — must return JSON.

### Seed data (topics / bank)

The API **seeds reference data + curated bank on startup** (see `app.main` lifespan). After the first successful deploy you should see topics without a manual seed step. If the DB was wiped, redeploy/restart **api**.

---

## 8. Custom domain on Railway

1. Buy `quizverse.app` (or your domain).
2. Railway **api** service → **Settings** → **Networking** → **Custom Domain** → add `quizverse.app` (and/or `www` / `api`).
3. Railway shows the DNS record to create (usually **CNAME** to `….up.railway.app`, or their documented target).
4. Wait for certificate **Active**.
5. Update:

```env
SHARE_PUBLIC_BASE_URL=https://quizverse.app
```

6. Redeploy **api** (so share links / landings use the new base).

Railway handles TLS — you do **not** run Caddy on Railway.

---

## 9. Point the Android app at Railway

```bash
cd mobile
# Railway-generated domain:
flutter build apk --release --dart-define=API_BASE_URL=https://YOUR-API.up.railway.app

# Or after custom domain:
flutter build appbundle --release --dart-define=API_BASE_URL=https://quizverse.app
```

Install/sideload the APK and test guest login on mobile data.

---

## 10. Railway vs local Compose — mapping

| Local Docker | Railway |
|--------------|---------|
| `postgres` service | Postgres plugin |
| `redis` service | Redis plugin |
| `api` + Caddy | `api` service + Railway HTTPS |
| `worker` | `worker` service |
| `.env` file | Service / shared **Variables** |
| `docker-compose.prod.yml` | Dockerfile CMD (migrations + uvicorn `$PORT`) |

---

## 11. Checklist

- [ ] Project + Postgres + Redis
- [ ] `api` service with `Dockerfile.api`, public domain
- [ ] `worker` service with `Dockerfile.worker`, private
- [ ] `DATABASE_URL` / `DATABASE_URL_SYNC` with `+asyncpg` / `+psycopg`
- [ ] `REDIS_URL`, `JWT_SECRET`, `LLM_API_KEY`, `APP_ENV=production`
- [ ] `SHARE_PUBLIC_BASE_URL` = public HTTPS URL
- [ ] `/health` works on phone
- [ ] Flutter built with matching `API_BASE_URL`
- [ ] (Optional) `GOOGLE_CLIENT_ID` + Flutter `GOOGLE_SERVER_CLIENT_ID` for Sign in with Google
- [ ] (Later) custom domain + Play SHA-256 fingerprints + `apple_google` billing

---

## 12. Troubleshooting

| Symptom | Fix |
|---------|-----|
| Build fails on `COPY backend` | Dockerfile path set but build context not repo root |
| App listens wrong port / 502 | Must use `${PORT}` — use current `Dockerfile.api` |
| DB connection errors | Wrong scheme (`asyncpg`/`psycopg`); using public URL with bad SSL; typo in password |
| Redis errors | `REDIS_URL` not set on that service |
| Worker idle / bank never grows | Worker not deployed or missing `LLM_API_KEY` / DB vars |
| Guest login timeout on phone | APK still points at tunnel/LAN — rebuild with Railway HTTPS URL |
| Alembic errors on boot | Check api logs; ensure Postgres is running and URL is reachable internally |

---

## 13. Cost notes

Railway bills for usage (compute + Postgres + Redis + egress). Start on the free/trial plan for smoke tests, then a hobby plan for always-on API + worker. Monitor the **Usage** tab.

CLI (optional): [Railway CLI](https://docs.railway.app/guides/cli) — `railway login`, `railway link`, `railway up`.
