# Environment & Provider Checklist

> **Single Source of Truth**: For step-by-step production deployment instructions, 1,000 CCU tuning, and Play Store publishing details, see **[PLAYSTORE_PRODUCTION_GUIDE.md](PLAYSTORE_PRODUCTION_GUIDE.md)**.

Use this checklist when taking SpeedQuiz live. Variables reside in the root `.env` file (gitignored). Template: [`.env.example`](../.env.example).

---

## 1. Flutter Compile-Time Defines (Not `.env`)

Pass these parameters when building the Flutter app via `--dart-define`:

| Variable | Example | Description |
| :--- | :--- | :--- |
| `API_BASE_URL` | `https://speedquiz.app` | Base HTTPS URL of the backend API. |
| `GOOGLE_SERVER_CLIENT_ID` | `123456-xxx.apps.googleusercontent.com` | Web OAuth Client ID for Google Sign-In. |

---

## 2. Core App & Performance Tuning Variables

| Variable | Local / Dev | Production (1,000 CCU) | Provider / Notes |
| :--- | :--- | :--- | :--- |
| `APP_NAME` | SpeedQuiz | SpeedQuiz | Application branding name. |
| `APP_ENV` | `development` | `production` | Enables production security checks & disables stub billing. |
| `DEBUG` | `true` | `false` | Disables verbose SQL logging and debug pages. |
| `CORS_ORIGINS` | `*` | `https://speedquiz.app` | Restrict origins in production. |
| `JWT_SECRET` | Dev string | 64-char random hex string | Generate via `openssl rand -hex 32`. |
| `WEB_CONCURRENCY` | `1` | `4` | Number of Uvicorn API worker processes. |
| `DB_POOL_SIZE` | `10` | `25` | SQLAlchemy asyncpg pool size per worker process. |
| `DB_MAX_OVERFLOW` | `20` | `25` | Overflow pool connections per worker process. |

---

## 3. Database & Cache Variables

| Variable | Production Example | Provider / Notes |
| :--- | :--- | :--- |
| `POSTGRES_USER` | `speedquiz` | Database user name. |
| `POSTGRES_PASSWORD` | Strong Random Password | Database user password. |
| `POSTGRES_DB` | `speedquiz` | Primary database name. |
| `DATABASE_URL` | `postgresql+asyncpg://...` | Async SQLAlchemy URL. |
| `DATABASE_URL_SYNC` | `postgresql+psycopg://...` | Sync SQLAlchemy URL (Alembic migrations). |
| `REDIS_URL` | `redis://redis:6379/0` | Redis instance URL. |

---

## 4. Google Auth & Play Store Verification Secrets

| Variable | Production Value | Provider / Notes |
| :--- | :--- | :--- |
| `GOOGLE_CLIENT_ID` | Web Client ID string | Google Cloud Console OAuth 2.0 Client ID (Web Application). |
| `BILLING_VERIFY_MODE` | `apple_google` | Set to `apple_google` when Google Play service account is linked. |
| `BILLING_ALLOW_STUB_IN_PRODUCTION` | `false` | Security latch preventing stub purchases in production. |
| `IAP_PREMIUM_PRODUCT_ID` | `speedquiz_premium` | Must match product ID created in Play Console. |
| `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` | Single-line JSON string | Google Cloud Service Account with Play Developer API access. |

---

## 5. Share & App Links Fingerprints

| Variable | Production Value | Provider / Notes |
| :--- | :--- | :--- |
| `SHARE_PUBLIC_BASE_URL` | `https://speedquiz.app` | Base URL used for public result cards (`/r/{id}`). |
| `APP_LINK_ANDROID_PACKAGE` | `com.speedquiz.app` | Android Application ID. |
| `APP_LINK_ANDROID_SHA256_CERT_FINGERPRINTS` | `SHA256_FINGERPRINT_1,SHA256_FINGERPRINT_2` | Comma-separated SHA-256 fingerprints for `/.well-known/assetlinks.json`. |

---

## 6. AI Generator Worker Variables

| Variable | Production Value | Provider / Notes |
| :--- | :--- | :--- |
| `LLM_PROVIDER` | `openai` | AI provider implementation (`openai` or `mock`). |
| `LLM_API_KEY` | `sk-proj-YOUR_API_KEY` | OpenAI API Key for worker bank generation. |
| `LLM_MODEL_GENERATE` | `gpt-4o-mini` | Model for batch question generation. |
| `LLM_MODEL_VALIDATE` | `gpt-4o-mini` | Model for question validation & quality check. |
