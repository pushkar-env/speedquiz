# QuizVerse deployment guide

This document covers **local development**, **production API**, and **Google Play** release.
iOS / App Store stays configured in the codebase but is out of scope for the first public launch.

Package / bundle id: **`com.quizverse.app`**  
Share / App Links host: **`quizverse.app`** (point DNS at your API when ready)

---

## 1. Local development

### Prerequisites

- Docker Desktop
- Flutter (stable, matching repo)
- Android emulator or device
- (Optional) Python 3.12+ for host-side pytest

### Device testing without same Wi‑Fi

Phones cannot reach your PC’s `localhost`. For any network (mobile data included), run a temporary HTTPS tunnel to local `:8000`:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/dev_tunnel.ps1
```

Then rebuild with `--dart-define=API_BASE_URL=https://<tunnel-host>`. Details: [OPEN_AND_RUN.md](OPEN_AND_RUN.md).

**Production does not use tunnels.** Deploy the API behind a real domain with TLS; Play builds use that permanent URL.

| Service  | URL |
|----------|-----|
| API      | http://localhost:8000 |
| OpenAPI  | http://localhost:8000/docs |
| Postgres | localhost:5432 |
| Redis    | localhost:6379 |

```bash
curl http://localhost:8000/health
curl http://localhost:8000/ready
```

Local defaults:

- `APP_ENV=development`
- `BILLING_VERIFY_MODE=stub` (paywall can exercise verify without Play products)
- `ENTITLEMENTS_ENFORCE_QUESTION_CAPS=false` (unlimited free play)
- `SHARE_PUBLIC_BASE_URL=` empty, or `http://localhost:8000` to test HTML `/r/{id}`

Backend tests (inside API container or local venv):

```bash
docker compose exec api pytest -q
```

### Flutter (Android)

```bash
cd mobile
flutter pub get
# Uninstall old package if you previously used com.example.mobile:
#   %LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe uninstall com.example.mobile
flutter run -d emulator-5554
```

API base URL (debug defaults):

| Target | URL |
|--------|-----|
| Android emulator | `http://10.0.2.2:8000` |
| iOS simulator | `http://localhost:8000` |
| Physical device | `http://<LAN-IP>:8000` via `--dart-define` |

Override anytime:

```bash
flutter run --dart-define=API_BASE_URL=http://192.168.1.10:8000
```

---

## 2. Production API

**Full walkthrough (domain + VPS + Docker + HTTPS):** see **[HOSTING.md](HOSTING.md)**.

### Recommended shape

- Buy a domain → rent a small Ubuntu VPS → install Docker → clone this repo
- Put production secrets in `.env` on the server ([ENV_PROVIDERS.md](ENV_PROVIDERS.md))
- DNS **A** record → VPS IP; Caddy terminates TLS and proxies to the API
- Start: `docker compose -f docker-compose.yml -f docker-compose.prod.yml -f docker-compose.caddy.yml up --build -d`
- Flutter: `--dart-define=API_BASE_URL=https://quizverse.app`

### Compose (single-host)

```bash
cp .env.example .env
# Fill production values — see docs/ENV_PROVIDERS.md and docs/HOSTING.md
# Point DNS A record at this server, then:
docker compose \
  -f docker-compose.yml \
  -f docker-compose.prod.yml \
  -f docker-compose.caddy.yml \
  up --build -d
```

Prod overlay differences:

- No source bind-mounts (image code)
- Uvicorn without `--reload`, multi-worker
- `restart: always`
- Caddy on 80/443 with automatic Let’s Encrypt HTTPS (`infrastructure/Caddyfile`)

### Minimum production `.env` changes

| Variable | Production value |
|----------|------------------|
| `APP_ENV` | `production` |
| `DEBUG` | `false` |
| `JWT_SECRET` | long random secret |
| `POSTGRES_PASSWORD` | strong unique password |
| `CORS_ORIGINS` | your web origins only (not `*`) |
| `LLM_API_KEY` | OpenAI (or provider) key |
| `SHARE_PUBLIC_BASE_URL` | `https://quizverse.app` |
| `BILLING_VERIFY_MODE` | `apple_google` once Play verify credentials exist |
| `BILLING_ALLOW_STUB_IN_PRODUCTION` | `false` |
| `ENTITLEMENTS_DEV_TOGGLE` | `false` |
| `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` | Play service account JSON (one line) |
| `APP_LINK_ANDROID_SHA256_CERT_FINGERPRINTS` | upload + app signing cert SHA-256 |
| `APP_LINK_ANDROID_PACKAGE` | `com.quizverse.app` |

Optional later: `ENTITLEMENTS_ENFORCE_QUESTION_CAPS=true` when you turn on free caps.

### DNS / App Links

1. Point `quizverse.app` (A/AAAA or CNAME) at the API / reverse proxy.
2. Ensure these are publicly reachable over HTTPS:
   - `GET https://quizverse.app/.well-known/assetlinks.json`
   - `GET https://quizverse.app/r/{session_id}`
3. Put Play signing certificate SHA-256 fingerprints in `APP_LINK_ANDROID_SHA256_CERT_FINGERPRINTS` (comma-separated).

iOS Associated Domains / AASA remain configured (`applinks:quizverse.app`, `APP_LINK_IOS_APP_ID`) for a later App Store launch — leave empty until you have a Team ID.

---

## 3. Google Play release (Android)

### 3.1 One-time: upload keystore

```bash
cd mobile/android
keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
cp key.properties.example key.properties
# Edit key.properties — passwords, alias, storeFile path
```

`key.properties` and `*.jks` are gitignored. Back up the keystore offline — losing it blocks updates.

### 3.2 Build an App Bundle

Point the app at your **HTTPS** API:

```bash
cd mobile
flutter pub get
flutter build appbundle --release --dart-define=API_BASE_URL=https://quizverse.app
```

Artifact: `mobile/build/app/outputs/bundle/release/app-release.aab`

APK (sideload / internal testing only):

```bash
flutter build apk --release --dart-define=API_BASE_URL=https://quizverse.app
```

### 3.3 Play Console checklist

1. Create app with application id **`com.quizverse.app`**.
2. Complete store listing (title, short/full description, screenshots, feature graphic).
3. Privacy policy URL (required) — host a page; link it in Console.
4. Content rating questionnaire; target audience; Data safety form.
5. Upload AAB to Internal testing → closed → production.
6. **Play App Signing**: enroll; copy **App signing** and **Upload** certificate SHA-256 into `APP_LINK_ANDROID_SHA256_CERT_FINGERPRINTS`.
7. In-app products: create product id matching `IAP_PREMIUM_PRODUCT_ID` (default `quizverse_premium`).
8. Link a Google Cloud service account with Play Android Developer API access; paste JSON into `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`.
9. Set backend `BILLING_VERIFY_MODE=apple_google` and redeploy API.
10. Verify purchase on a licensed test account before production rollout.

### 3.4 Versioning

`mobile/pubspec.yaml`:

```yaml
version: 0.1.0+1   # name+build  → versionName + versionCode
```

Bump **build number** (`+N`) for every Play upload; bump **name** for user-visible releases.

---

## 4. Pre-flight test matrix (Android)

Before production track:

- [ ] Guest login + play a casual quiz end-to-end against prod API
- [ ] Results share sheet; open `https://quizverse.app/r/{id}` on device
- [ ] App Link opens shared result in-app (after assetlinks verified)
- [ ] Paywall → purchase (license testers) → `is_premium` true via `/entitlements/me`
- [ ] Restore purchases
- [ ] Cold start with no network shows a recoverable error (no crash)
- [ ] `APP_ENV=production` refuses stub billing

---

## 5. Related docs

- [ENV_PROVIDERS.md](ENV_PROVIDERS.md) — every env var and which provider supplies it
- [PROGRESS.md](PROGRESS.md) — phase status
- [architecture.md](architecture.md) — engineering decisions
- Root [README.md](../README.md) — quick start
