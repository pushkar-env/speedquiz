# Hosting QuizVerse API on a real domain

This is the **production** path: phones (any network) call your API over HTTPS on a domain you control. No Cloudflare quick tunnel, no LAN IP.

Recommended first setup for this repo: **one Linux VPS + Docker Compose + Caddy (auto HTTPS)**.

Target example throughout: domain **`quizverse.app`** → API at **`https://quizverse.app`**.

---

## What you are hosting

| Piece | Role | Public? |
|-------|------|---------|
| **api** | FastAPI (gameplay, auth, share, well-known) | Yes — via HTTPS |
| **worker** | Background bank top-ups / AI jobs | No |
| **postgres** | Question bank + users | No |
| **redis** | Rate limits / leaderboards cache | No |
| **Caddy** (or Nginx) | TLS certificates + reverse proxy | Ports 80/443 only |

Flutter never talks to Postgres/Redis. Only `https://your-domain` (the API).

```text
Phone / Play build
    │  HTTPS
    ▼
quizverse.app (Caddy :443)
    │  HTTP localhost
    ▼
api :8000  ──►  postgres + redis
worker     ──►  postgres + redis (+ OpenAI)
```

---

## Step 0 — Buy a domain

1. Register a domain (Cloudflare Registrar, Namecheap, Google Domains, etc.).
2. You will create DNS records pointing at your server IP (Step 3).
3. Prefer managing DNS in **Cloudflare** (free) even if you bought the domain elsewhere — optional but makes TLS/DNS easy.

You do **not** need the domain before renting a server, but you need it before HTTPS will work.

---

## Step 1 — Rent a server (VPS)

Pick any Ubuntu 22.04/24.04 VPS with a public IPv4:

- **Hetzner**, **DigitalOcean**, **Linode**, **Vultr**, **AWS Lightsail**, etc.
- Size to start: **1–2 vCPU, 2 GB RAM**, 40+ GB disk (enough for Docker images + Postgres).
- Region: closest to your users (or you).

Note the server’s **public IP**, e.g. `203.0.113.10`.

SSH in (from your PC):

```bash
ssh root@203.0.113.10
# or: ssh ubuntu@203.0.113.10
```

---

## Step 2 — Install Docker on the VPS

On Ubuntu:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl git
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
# log out and back in if needed
docker --version
docker compose version
```

---

## Step 3 — Point DNS at the server

In your DNS panel (Cloudflare / registrar):

| Type | Name | Value | TTL |
|------|------|-------|-----|
| **A** | `@` (root) | `203.0.113.10` (your VPS IP) | Auto / 300 |
| **A** | `www` | same IP (optional) | Auto |

If you prefer `api.quizverse.app` instead of the root:

| Type | Name | Value |
|------|------|-------|
| **A** | `api` | VPS IP |

Then use `https://api.quizverse.app` as `API_BASE_URL` / `SHARE_PUBLIC_BASE_URL`.

Wait until DNS resolves (can take minutes):

```bash
# from your PC
nslookup quizverse.app
ping quizverse.app
```

**Important:** For Caddy to issue Let’s Encrypt certificates, port **80** must be reachable on the VPS before/during first start.

---

## Step 4 — Put the code on the server

```bash
# on the VPS
sudo mkdir -p /opt/quizverse
sudo chown $USER:$USER /opt/quizverse
cd /opt/quizverse
git clone https://github.com/YOUR_USER/quizverse.git .
# or scp/rsync the repo from your PC if private
```

Create production env:

```bash
cp .env.example .env
nano .env   # or vim
```

### Minimum `.env` for production

```env
APP_NAME=QuizVerse
APP_ENV=production
DEBUG=false
API_PREFIX=/api/v1
CORS_ORIGINS=https://quizverse.app

POSTGRES_USER=quizverse
POSTGRES_PASSWORD=GENERATE_A_LONG_RANDOM_PASSWORD
POSTGRES_DB=quizverse
DATABASE_URL=postgresql+asyncpg://quizverse:GENERATE_A_LONG_RANDOM_PASSWORD@postgres:5432/quizverse
DATABASE_URL_SYNC=postgresql+psycopg://quizverse:GENERATE_A_LONG_RANDOM_PASSWORD@postgres:5432/quizverse

REDIS_URL=redis://redis:6379/0

JWT_SECRET=GENERATE_ANOTHER_LONG_RANDOM_SECRET
JWT_ALGORITHM=HS256
JWT_ACCESS_TOKEN_EXPIRE_MINUTES=60
JWT_REFRESH_TOKEN_EXPIRE_DAYS=30

LLM_PROVIDER=openai
LLM_API_KEY=sk-...your-openai-key...
LLM_MODEL_GENERATE=gpt-4o-mini
LLM_MODEL_VALIDATE=gpt-4o-mini
LLM_MODEL_CLASSIFY=gpt-4o-mini

ENTITLEMENTS_ENFORCE_QUESTION_CAPS=false
ENTITLEMENTS_DEV_TOGGLE=false
BILLING_VERIFY_MODE=stub
BILLING_ALLOW_STUB_IN_PRODUCTION=false

SHARE_PUBLIC_BASE_URL=https://quizverse.app
APP_LINK_ANDROID_PACKAGE=com.quizverse.app
APP_LINK_ANDROID_SHA256_CERT_FINGERPRINTS=
APP_LINK_IOS_APP_ID=

IAP_PREMIUM_PRODUCT_ID=quizverse_premium
IAP_ANDROID_PACKAGE=com.quizverse.app
GOOGLE_PLAY_SERVICE_ACCOUNT_JSON=
ANALYTICS_PROVIDER=postgres
LOG_LEVEL=INFO
```

Generate secrets on the VPS:

```bash
openssl rand -hex 32   # use for JWT_SECRET
openssl rand -hex 24   # use for POSTGRES_PASSWORD (update both DATABASE_URL lines too)
```

Full variable meanings: [ENV_PROVIDERS.md](ENV_PROVIDERS.md).

---

## Step 5 — Reverse proxy with automatic HTTPS (Caddy)

This repo includes:

- [`infrastructure/Caddyfile`](../infrastructure/Caddyfile) — proxies `quizverse.app` → `api:8000`
- [`docker-compose.caddy.yml`](../docker-compose.caddy.yml) — adds the Caddy service

Edit the Caddyfile if your domain differs (replace `quizverse.app`).

Open firewall (UFW example):

```bash
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
sudo ufw status
```

**Do not** expose Postgres `5432` or Redis `6379` to the public internet. Prefer removing their `ports:` in a hardened compose later; at minimum block them in the firewall.

---

## Step 6 — Start production stack

On the VPS, from `/opt/quizverse`:

```bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose.prod.yml \
  -f docker-compose.caddy.yml \
  up --build -d
```

Check:

```bash
docker compose ps
curl -fsS https://quizverse.app/health
curl -fsS https://quizverse.app/ready
curl -fsS https://quizverse.app/docs   # optional; consider disabling docs in hard prod later
```

From your **phone browser** (mobile data): open `https://quizverse.app/health` — you should see JSON. That means the world can reach your API.

Logs:

```bash
docker compose logs -f api
docker compose logs -f caddy
docker compose logs -f worker
```

Update code later:

```bash
cd /opt/quizverse
git pull
docker compose \
  -f docker-compose.yml \
  -f docker-compose.prod.yml \
  -f docker-compose.caddy.yml \
  up --build -d
```

---

## Step 7 — Point the Android app at production

On your PC, build with the real HTTPS URL (no tunnel):

```bash
cd mobile
flutter build apk --release --dart-define=API_BASE_URL=https://quizverse.app
# Play Store:
flutter build appbundle --release --dart-define=API_BASE_URL=https://quizverse.app
```

Install that APK on any device — guest login should work without same Wi‑Fi.

---

## Step 8 — App Links + billing (after Play Console exists)

1. Upload AAB → Play App Signing → copy **SHA-256** fingerprints into  
   `APP_LINK_ANDROID_SHA256_CERT_FINGERPRINTS` on the server `.env` → recreate API container.
2. Confirm `https://quizverse.app/.well-known/assetlinks.json` returns JSON (not 503).
3. When ready for real IAP: set `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` and `BILLING_VERIFY_MODE=apple_google`.

---

## Cost ballpark (order of magnitude)

| Item | Typical |
|------|---------|
| Domain | ~$10–15 / year |
| Small VPS | ~$5–12 / month |
| OpenAI API | usage-based (bank generation only) |
| Cloudflare DNS | free |

---

## Alternatives (same idea, different ops)

| Option | When to use |
|--------|-------------|
| **This guide (VPS + Compose + Caddy)** | Matches this repo; full control; cheapest learning path |
| **Fly.io / Railway / Render** | Less server babysitting; you still set env vars + domain; may need separate Postgres/Redis add-ons |
| **AWS/GCP/Azure** | Overkill early; use later for scale |
| **Cloudflare Tunnel (named, with account)** | Expose a home/lab machine without opening ports — still not a substitute for a real always-on host for Play |

Whatever you pick, the app only needs:

1. Stable **HTTPS base URL**
2. That URL in `--dart-define=API_BASE_URL=...`
3. Matching `SHARE_PUBLIC_BASE_URL` on the server

---

## Checklist

- [ ] Domain purchased; A record → VPS IP
- [ ] Docker installed on VPS
- [ ] Repo cloned; production `.env` filled (`APP_ENV=production`, strong secrets, `LLM_API_KEY`)
- [ ] Firewall: 22/80/443 only (SSH/HTTP/HTTPS)
- [ ] `docker compose ...caddy.yml up --build -d`
- [ ] `https://your-domain/health` works on phone mobile data
- [ ] Flutter release built with `--dart-define=API_BASE_URL=https://your-domain`
- [ ] (Later) Play SHA-256 → assetlinks; billing mode `apple_google`

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Certificate errors / Caddy won’t get cert | DNS not pointing yet; port 80 blocked; wrong domain in Caddyfile |
| `/health` OK on server, fail on phone | Wrong domain in APK; still using tunnel/LAN build — rebuild with HTTPS domain |
| 502 from Caddy | API container down — `docker compose logs api` |
| Guest login 500 | Check `JWT_SECRET`, DB migrations (`alembic` runs on API start), `docker compose logs api` |
| LLM / custom topics fail | `LLM_API_KEY` missing or invalid |

Dev/tunnel workflow (not production): [OPEN_AND_RUN.md](OPEN_AND_RUN.md).  
Play Store packaging: [DEPLOYMENT.md](DEPLOYMENT.md).
