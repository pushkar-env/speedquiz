# Deployment

Putting the stack online with HTTPS so the app works on any network.

- Running locally: [DEVELOPMENT.md](DEVELOPMENT.md)
- Shipping to Play: [RELEASE.md](RELEASE.md)

---

## 1. The stack

```text
Phone ──HTTPS/IPv6──► Cloudflare Worker ──► Railway `api` ──► Neon Postgres (pooled)
                      (IPv6 front door)                   └─► Upstash Redis
                                          Railway `worker` ──► same DB + Redis + OpenAI
```

| Piece | Choice | Why not the obvious alternative |
|---|---|---|
| Postgres | **Neon** | Railway's Postgres plugin is a single container with no connection pooler and a thin backup story |
| Redis | **Upstash** | Same reasoning; free tier is ample for rate limits and leaderboard ZSETs |
| API + worker | **Railway** | Dockerfiles are already PaaS-shaped; the worker is a long-lived process, which rules out request-scoped platforms |
| Public entry | **Cloudflare Worker** | Railway's `*.up.railway.app` is IPv4-only — see §6. This is the free fix |

Roughly $5–10/month. A single-VPS alternative is in §9.

### Why the worker rules out serverless

`workers/main.py` is a persistent polling loop, not a request handler. Vercel,
Netlify and default Cloud Run cannot host it without restructuring.

---

## 2. Prerequisites

- Repo pushed to GitHub
- Accounts: [Railway](https://railway.app), [Neon](https://neon.tech), [Upstash](https://upstash.com), [Cloudflare](https://cloudflare.com)
- An OpenAI API key
- A JWT secret: `openssl rand -hex 32` (Git Bash), or `python -c "import secrets; print(secrets.token_hex(32))"`

---

## 3. Postgres on Neon

1. **New Project**, region closest to your users.
2. **Connection Details** → turn **Connection pooling ON**. The host gains a `-pooler` suffix. Use that one.

The project needs two URLs for the same database, because SQLAlchemy picks its
driver from the scheme: the app is async (`asyncpg`), Alembic is sync
(`psycopg`).

Let the script do the conversion rather than hand-editing:

```bash
python scripts/split_db_url.py "postgresql://user:pass@ep-...-pooler.../neondb?sslmode=require&channel_binding=require"
```

It prints `DATABASE_URL`, `DATABASE_URL_SYNC` and
`DB_DISABLE_PREPARED_STATEMENTS`, and warns if you copied the **direct**
endpoint instead of the pooled one.

Two things it handles that are easy to get wrong:

- **The asyncpg URL must have no libpq query parameters.** SQLAlchemy forwards `sslmode` and `channel_binding` verbatim to `asyncpg.connect()`, which accepts neither and has no `**kwargs` — you get `TypeError: connect() got an unexpected keyword argument 'sslmode'` at connect time, which reads like an outage rather than a typo. TLS still happens; asyncpg negotiates it itself. Keep the parameters on the psycopg URL, which understands them.
- **`DB_DISABLE_PREPARED_STATEMENTS=true` is mandatory on a pooled endpoint.** Transaction-mode pooling multiplexes connections between transactions, so server-side prepared statements collide once traffic overlaps.

> Neon's free tier scales to zero; the first request after idle pays roughly a
> second of cold start.

---

## 4. Redis on Upstash

**Create Database**, same region as Neon, then copy the connection string.

Upstash often presents it as a `redis-cli` invocation:

```text
redis-cli --tls -u redis://default:TOKEN@fair-bluejay-111963.upstash.io:6379
```

**Do not paste that URL as-is.** `redis-cli` takes TLS as a separate `--tls`
flag; redis-py derives it from the **scheme**. `redis://` builds a plaintext
`Connection` and Upstash closes it (`ConnectionError: Connection closed by
server`). Add the second `s`, drop the flag:

```env
REDIS_URL=rediss://default:TOKEN@fair-bluejay-111963.upstash.io:6379
```

Redis is not the source of truth for anything. Losing it degrades ranking
freshness, not data.

---

## 5. Railway services

### `api`

1. **New Project → Deploy from GitHub repo**, rename the service to `api`.
2. **Settings → Build**: Builder **Dockerfile**, path `infrastructure/docker/Dockerfile.api`, **root directory empty** (the Dockerfile does `COPY backend`, so the build context must be the repo root).
3. **Settings → Networking → Generate Domain** → target port **8000**.
4. **Settings → Deploy**: health check path `/health`, timeout `120` (first boot migrates and seeds).

Do not override the start command. The Dockerfile already runs migrations,
then uvicorn on `$PORT` with `--proxy-headers` so client IPs survive Railway's
proxy.

> **Port mismatch is the most common first failure.** The dialog pre-fills
> `8080`; the container listens on `8000` (`ENV PORT=8000`). Mismatch gives a
> 502 from `railway-hikari` on every path, which looks like a crash. Either
> enter 8000, or set a `PORT` variable to 8080 — not half of each.

### `worker`

**+ New → GitHub Repo**, same repo, rename to `worker`, Dockerfile path
`infrastructure/docker/Dockerfile.worker`. **No domain** — it has no HTTP
server, and giving it one produces a permanently failing health check.

One replica is enough.

---

## 6. Cloudflare Worker (IPv6 front door)

**Railway's generated domains publish an A record but no AAAA.** Phones on
IPv6-only mobile networks cannot reach an IPv4-only host unless the carrier's
NAT64/DNS64 translates. When it doesn't, the app works on dual-stack Wi-Fi and
dies on mobile data — which users experience as a broken app, not a network
quirk, and you will never see it because your Wi-Fi is fine.

Verified at the time of writing:

```text
platform                  v4  v6
up.railway.app (yours)     1   0   <- broken for IPv6-only clients
workers.dev (Cloudflare)   2   1
fly.dev                    1   1
onrender.com               1   0
koyeb.app                  1   0
vercel.app                 2   0
```

Render, Koyeb and Vercel are IPv4-only too, so switching host does not fix it.
The free fix is a ~30-line Cloudflare Worker that terminates the IPv6
connection and forwards to Railway over IPv4. Setup:
[`infrastructure/cloudflare-worker/`](../infrastructure/cloudflare-worker/README.md).

`*.workers.dev` is free with a 100,000 request/day cap — roughly 6,500 quiz
runs. When you buy a domain for the Play listing, put it on Cloudflare with the
proxy enabled and point it straight at Railway; that removes both the cap and
the extra hop.

---

## 7. Environment variables

Set them on **both** services. Rather than pasting your local `.env` — which
carries development values the app now refuses to boot with, plus keys that
only configure the local Docker Postgres — generate the block:

```bash
python scripts/railway_env.py --public-url https://YOUR-PUBLIC-URL
```

It drops local-only keys, applies production values, adds the ones your `.env`
never needed, and **validates the result against the app's real `Settings`
model**. If it prints, that config boots. If it can't, it exits non-zero with
the reason.

A few that catch people out:

- **`LLM_API_KEY` belongs on both services.** The worker grows the bank; the API serves custom topics and Teach me. Omitting it on the worker is the usual reason the bank never grows.
- **`SHARE_PUBLIC_BASE_URL` must be your public URL** (the Worker URL if you use one), or share links point somewhere IPv6-only users cannot open. It is chicken-and-egg: deploy once, take the domain, re-run the script with `--public-url`.
- **`APP_ENV=production` activates the safety latches** in [DEVELOPMENT.md §4](DEVELOPMENT.md#4-environment-variables). A container that exits immediately after deploy is almost always one of those three.

---

## 8. Verify

```bash
curl https://YOUR-PUBLIC-URL/ready
```

Expect `200` with `{"status":"ready","database":true,"redis":true}`. It returns
**503** when either dependency is down, so the platform's health check actually
pulls a broken instance out of rotation.

```bash
curl https://YOUR-PUBLIC-URL/api/v1/topics
```

Expect 18 topics. Empty means seeding failed — grep the logs for `seed_failed`.
With several replicas only one seeds; the others log
`seed_skipped_lock_held_by_another_replica`, which is correct.

Then open `/health` in the **phone's browser**, on mobile data with Wi-Fi off.
That separates "backend unreachable" from "app misconfigured", and catches the
IPv6 problem in §6.

Finally build the app against it:

```bash
flutter build apk --release --dart-define=API_BASE_URL=https://YOUR-PUBLIC-URL --dart-define=GOOGLE_SERVER_CLIENT_ID=YOUR-WEB-CLIENT-ID.apps.googleusercontent.com
```

---

## 9. Load testing

Do not trust a capacity claim — including the ones in this file.

```bash
k6 run -e BASE_URL=https://YOUR-PUBLIC-URL scripts/loadtest.js
```

```bash
k6 run -e BASE_URL=https://YOUR-PUBLIC-URL -e PROFILE=peak scripts/loadtest.js
```

Profiles: `smoke`, `load`, `peak` (1,000 concurrent), `breakpoint`. The script
runs the real journey — guest auth, topics, session, ten answers with human
think time, finish, leaderboard — and fails the run if answer latency p95
exceeds 400 ms or errors exceed 1%.

**VUs are not RPS.** A player answers every 6–13 s, so 1,000 concurrent players
is roughly 100–150 req/s.

**It writes real guest accounts.** Point it at a Neon branch, not the database
your users are on.

---

## 10. Scaling

In this order, and only in response to measurements:

1. **`WEB_CONCURRENCY=4`** on a larger instance. Cheapest win.
2. **Railway replicas.** Safe — migrations take a Postgres advisory lock and seeding is idempotent.
3. **Recheck the connection maths** every time:
   ```text
   (DB_POOL_SIZE + DB_MAX_OVERFLOW) x WEB_CONCURRENCY x replicas + worker
   ```
   Behind Neon's pooler there is plenty of headroom, but know the number.
4. **Neon compute size** when database CPU is the bottleneck.

The worker never needs scaling. It can be down for an hour without affecting
gameplay, because questions are served from the bank.

---

## 11. Single-VPS alternative

For a flat bill or full control, one box runs everything. A Hetzner CX22
(~€4/mo, 2 vCPU / 4 GB) is ample; Oracle Cloud's Always Free ARM instance is
the $0 version if you can get capacity.

```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml -f docker-compose.caddy.yml up --build -d
```

Point an A record at the box and edit `infrastructure/Caddyfile` to your
domain — Caddy obtains and renews the certificate itself. Set
`WEB_CONCURRENCY` to your core count, and keep Postgres and Redis firewalled
off the public internet.

Trade-off: cheaper and no IPv6 problem, but you own SSH, firewall, backups and
upgrades.

---

## 12. Backups and operations

- **Neon** keeps history; set the retention window and confirm point-in-time restore works *before* you need it.
- **Railway** keeps deploy history — use **Rollback** rather than force-pushing a fix.
- Every response carries `X-Request-ID`. Set `SENTRY_DSN` once you have real users so unhandled exceptions are findable.

---

## 13. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Container exits instantly, log says "Unsafe production configuration" | Placeholder `JWT_SECRET`, `ENTITLEMENTS_DEV_TOGGLE=true`, or `DEBUG=true`. The message names it |
| 502 on every path, `server: railway-hikari` | Nothing listening on the target port. See the port note in §5 |
| `TypeError: connect() got an unexpected keyword argument 'sslmode'` | Query parameters left on the **asyncpg** URL. Use `scripts/split_db_url.py` |
| `prepared statement "__asyncpg_stmt_x__" already exists` | Pooled endpoint without `DB_DISABLE_PREPARED_STATEMENTS=true` |
| `FATAL: sorry, too many clients already` | Connection maths in §10 exceeded, or you are on a direct (non-pooled) endpoint |
| Redis `ConnectionError: Connection closed by server` | `redis://` instead of `rediss://` |
| Build fails on `COPY backend` | Root directory set on the service — clear it |
| `/api/v1/topics` returns `{"items": []}` | Seeding failed — grep logs for `seed_failed` |
| `/ready` returns 503 | The body names which dependency is down |
| Worker idle, bank never grows | `LLM_API_KEY` missing on **worker** |
| **Works on Wi-Fi, fails on mobile data** | IPv4-only endpoint. See §6 |
| App says "Cannot reach the server" on a real phone | Built without `--dart-define=API_BASE_URL` → fell back to the emulator address `10.0.2.2:8000` |
| Sudden 403s with Cloudflare error 1010 | Cloudflare bot protection fingerprinting the client. Flutter's `dart:io` stack passes; some scripting clients do not. Check **Security → Bots** |
| Google Sign-In cancels instantly | Signing SHA-1 not registered for that key — see [RELEASE.md](RELEASE.md) |

---

## 14. Checklist

- [ ] Neon project, **pooled** string, both URL variants, `DB_DISABLE_PREPARED_STATEMENTS=true`
- [ ] Upstash Redis, `rediss://`
- [ ] `api` — Dockerfile.api, domain on the right port, `/health` check
- [ ] `worker` — Dockerfile.worker, no domain
- [ ] Variables generated by `scripts/railway_env.py` on both services
- [ ] `SHARE_PUBLIC_BASE_URL` = the public URL
- [ ] Cloudflare Worker deployed, AAAA record confirmed
- [ ] `/ready` green from the phone's browser **on mobile data**
- [ ] `/api/v1/topics` returns the seeded catalog
- [ ] APK built with matching `API_BASE_URL`, quiz plays end to end
- [ ] k6 smoke run passes
