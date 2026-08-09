# Environment & provider checklist

Use this when taking QuizVerse live. Values live in root `.env` (gitignored). Templates: [`.env.example`](../.env.example).

Flutter compile-time only (not `.env`):

| Define | Example | Where |
|--------|---------|--------|
| `API_BASE_URL` | `https://quizverse.app` | `flutter build/run --dart-define=API_BASE_URL=...` |

Android signing (not `.env`):

| File | Purpose |
|------|---------|
| `mobile/android/key.properties` | From `key.properties.example` |
| `mobile/android/upload-keystore.jks` | Upload keystore (backup offline) |

---

## Core app / security

| Variable | Local | Production | Provider / notes |
|----------|-------|------------|------------------|
| `APP_NAME` | QuizVerse | QuizVerse | — |
| `APP_ENV` | `development` | `production` | Gates stub billing + some toggles |
| `DEBUG` | `true` | `false` | — |
| `API_PREFIX` | `/api/v1` | `/api/v1` | — |
| `CORS_ORIGINS` | `*` OK | Explicit HTTPS origins | Reverse proxy / web if any |
| `JWT_SECRET` | Dev default OK | **Required strong secret** | Generate yourself |
| `JWT_*_EXPIRE_*` | Defaults OK | Tune as needed | — |

## Database & Redis

| Variable | Local | Production | Provider |
|----------|-------|------------|----------|
| `POSTGRES_USER` / `PASSWORD` / `DB` | Compose defaults | Strong password | Docker / RDS / Cloud SQL / Neon / etc. |
| `DATABASE_URL` | asyncpg URL to `postgres` service | Managed URL | Same |
| `DATABASE_URL_SYNC` | psycopg URL | Managed URL | Alembic / sync tools |
| `REDIS_URL` | `redis://redis:6379/0` | Managed Redis URL | Docker / ElastiCache / Upstash |

## LLM (question bank generation — never on play hot path)

| Variable | Local | Production | Provider |
|----------|-------|------------|----------|
| `LLM_PROVIDER` | `openai` or `mock` | `openai` | OpenAI (or future providers) |
| `LLM_API_KEY` | Your key | Your key | [OpenAI API keys](https://platform.openai.com/api-keys) |
| `LLM_MODEL_*` | `gpt-4o-mini` | Same or stronger | OpenAI model list |

## Share / App Links

| Variable | Local | Production | Provider |
|----------|-------|------------|----------|
| `SHARE_PUBLIC_BASE_URL` | empty or `http://localhost:8000` | `https://quizverse.app` | Your DNS + TLS |
| `APP_LINK_ANDROID_PACKAGE` | `com.quizverse.app` | Same | Play application id |
| `APP_LINK_ANDROID_SHA256_CERT_FINGERPRINTS` | empty → well-known 503 | Play **App signing** + **Upload** cert SHA-256 (comma-separated) | [Play Console → App signing](https://play.google.com/console) |
| `APP_LINK_IOS_APP_ID` | empty | `TEAMID.com.quizverse.app` when shipping iOS | Apple Developer Team ID |

DNS: point `quizverse.app` at the API so `/.well-known/assetlinks.json` and `/r/{id}` are public HTTPS.

## Entitlements & billing

| Variable | Local | Production | Provider |
|----------|-------|------------|----------|
| `ENTITLEMENTS_ENFORCE_QUESTION_CAPS` | `false` | `false` until monetizing | Feature flag |
| `FREE_UNIQUE_QUESTIONS_PER_TOPIC` | `30` | `30` | Used when caps on |
| `ENTITLEMENTS_DEV_TOGGLE` | `false` / `true` for QA | **`false`** | — |
| `IAP_PREMIUM_PRODUCT_ID` | `quizverse_premium` | Must match Play product | [Play Console → Monetize](https://play.google.com/console) |
| `IAP_ANDROID_PACKAGE` | `com.quizverse.app` | Same | Play application id |
| `BILLING_VERIFY_MODE` | `stub` | `apple_google` | — |
| `BILLING_ALLOW_STUB_IN_PRODUCTION` | `false` | **`false`** | Safety latch |
| `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` | empty | One-line service account JSON | Google Cloud + Play API access |
| `APPLE_IAP_*` | empty / sandbox | Fill when launching iOS | App Store Connect API key |

### Google Play service account (Android verify)

1. Google Cloud project → create service account → JSON key.
2. Play Console → Users and permissions → invite SA email → **View financial data** + **Manage orders and subscriptions** (or Android Publisher equivalent).
3. Enable **Google Play Android Developer API** on the Cloud project.
4. Paste the JSON as a **single line** into `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`.

### Apple (configured, deferred for first launch)

| Variable | Purpose |
|----------|---------|
| `APPLE_IAP_ISSUER_ID` | App Store Connect API issuer |
| `APPLE_IAP_KEY_ID` | Key id |
| `APPLE_IAP_PRIVATE_KEY` | `.p8` PEM with `\n` escapes |
| `APPLE_IAP_BUNDLE_ID` | `com.quizverse.app` |
| `APPLE_IAP_ENVIRONMENT` | `Sandbox` then `Production` |

## Observability (optional)

| Variable | Provider |
|----------|----------|
| `SENTRY_DSN` | Sentry project DSN |
| `LOG_LEVEL` | `INFO` / `WARNING` in prod |
| `ANALYTICS_PROVIDER` | `postgres` or `null` |

## OAuth (optional / future)

| Variable | Provider |
|----------|----------|
| `GOOGLE_CLIENT_ID` | Google Cloud OAuth client |
| `APPLE_CLIENT_ID` | Apple Services id |

## Bank growth tuning (usually leave defaults)

`TOPIC_BANK_TARGET_UNIQUE`, `TOPIC_BANK_LOW_WATERMARK`, `TOPIC_BANK_CHUNK_SIZE`, `TOPIC_BANK_SESSION_BATCH`, scoring knobs — see `.env.example`.

---

## Go-live order (Android-first)

1. Provision Postgres + Redis + API + worker with production `.env`.
2. Put TLS + DNS on `quizverse.app`.
3. Create Play app `com.quizverse.app`, privacy policy, listing.
4. Create upload keystore; build AAB with `--dart-define=API_BASE_URL=https://quizverse.app`.
5. Upload to Internal testing; copy signing SHA-256 → `APP_LINK_ANDROID_SHA256_CERT_FINGERPRINTS`; redeploy API.
6. Create IAP product + service account; set `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` + `BILLING_VERIFY_MODE=apple_google`.
7. License-tester purchase / restore verification.
8. Promote to production track.
9. (Later) Enable caps; ship iOS with Apple IAP + AASA Team ID.
