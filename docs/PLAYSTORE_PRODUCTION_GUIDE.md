# SpeedQuiz: Master Play Store Release & 1,000 CCU Production Architecture Guide

> **Single Source of Truth** for preparing, testing, hardening, hosting, and publishing SpeedQuiz to the Google Play Store while smoothly handling **at least 1,000 Concurrent Active Users (CCU)**.

---

## Table of Contents

1. [Executive Summary & 1,000 CCU Concurrency Analysis](#1-executive-summary--1000-ccu-concurrency-analysis)
2. [Phase 1: Creating & Verifying a Full Test Build](#2-phase-1-creating--verifying-a-full-test-build)
3. [Phase 2: Three Hosting Tiers for 1,000 CCU](#3-phase-2-three-hosting-tiers-for-1000-ccu)
   - [Option A: No-Cost Tier ($0 / month)](#option-a-no-cost-tier-0--month)
   - [Option B: Low-Cost Tier ($10 - $20 / month)](#option-b-low-cost-tier-10---20--month)
   - [Option C: Real Production Enterprise Tier ($60 - $150+ / month)](#option-c-real-production-enterprise-tier-60---150--month)
4. [Phase 3: Complete Google Play Store Publishing Walkthrough](#4-phase-3-complete-google-play-store-publishing-walkthrough)
5. [Phase 4: Load Testing, Observability & Verification Matrix](#5-phase-4-load-testing-observability--verification-matrix)
6. [Summary Checklist & Quick Reference](#6-summary-checklist--quick-reference)

---

## 1. Executive Summary & 1,000 CCU Concurrency Analysis

### 1.1 Architecture Advantage
SpeedQuiz is engineered for high throughput:
- **Zero In-Game LLM Latency**: Live LLM calls are **never** triggered during active gameplay. All questions are served directly from pre-validated PostgreSQL tables.
- **Async Workers**: Background worker processes (`workers.main`) generate and top up the question bank asynchronously when topic inventories fall below low watermarks.
- **Server-Authoritative Gameplay**: Answering questions, calculating speed/streak bonuses, and awarding achievements/XP are executed in lightweight database transactions and cached via Redis.

```text
[ 1,000 Active Players (Flutter App) ]
                 │
                 │ HTTPS (JSON / REST API)
                 ▼
[ Reverse Proxy / Load Balancer (Caddy / Nginx / Cloudflare) ]
                 │
                 │ Internal HTTP
                 ▼
[ FastAPI / Uvicorn Web Cluster (4 - 8 Workers) ]
        │                               │
        ▼                               ▼
[ PostgreSQL (Question Bank & Users) ]   [ Redis (ZSET Leaderboards & Rate Limits) ]
        ▲                               ▲
        │                               │
        └─── [ Async AI Worker Jobs ] ──┘ (OpenAI Background Top-Ups)
```

### 1.2 What Does 1,000 CCU Mean Mathematically?
- **Concurrency Definition**: 1,000 active users concurrently taking quizzes.
- **Request Rate Calculation**:
  - A user takes ~3 to 5 seconds per question.
  - Submitting an answer or fetching the next question generates 1 request every 4 seconds per user.
  - Total Throughput = `1,000 users / 4 seconds` = **250 Requests Per Second (RPS)**.
  - Spikes (e.g., Daily Challenge release at midnight UTC): Up to **500 RPS**.
- **Capacity Sizing Targets**:
  - Target **P99 API Latency**: `< 80 ms`.
  - Target **Error Rate**: `< 0.01%`.
  - Database connection pool capacity: Minimum **150–200 concurrent database connections**.

---

## 2. Phase 1: Creating & Verifying a Full Test Build

Before releasing to the public, you must build and test an interactive **Test Build** where **all features** operate exactly like the production app.

### 2.1 Pre-Flight Feature Testing Scope

| Feature Area | Verification Objective | Local / Test Mode Setting |
| :--- | :--- | :--- |
| **Guest Auth & Upgrade** | Guest login auto-created; Google Sign-In upgrades guest row without losing stats. | `GOOGLE_CLIENT_ID` set; `AUTH_GOOGLE.md` followed. |
| **Quiz Gameplay** | Timed sessions, score multipliers, streak bonuses, adaptive difficulty. | `API_BASE_URL` pointing to backend API. |
| **AI Custom Topics** | Prompting custom topic -> worker generates & validates questions within seconds. | Valid `LLM_API_KEY` on worker container. |
| **Daily Challenge & Streaks** | Fixed UTC day questions; streak increments on finish. | Backend date logic / system clock test. |
| **Leaderboards** | Redis ZSET dual-write with PostgreSQL fallback. | Redis service active. |
| **In-App Purchases (IAP)** | Paywall UI, purchase verification, entitlement grants. | `BILLING_VERIFY_MODE=stub` (or Play License Testers). |
| **Share Links & App Links** | Result share card, HTML landing `/r/{id}`, deep link `speedquiz://results/{id}`. | `SHARE_PUBLIC_BASE_URL` configured. |

### 2.2 Step 1: Create the Android Keystore (One-Time)
A signed build is required to test Google Sign-In, App Links, and IAP properly on actual Android devices.

1. Navigate to `mobile/android`:
   ```bash
   cd mobile/android
   keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
   ```
2. Create `mobile/android/key.properties` from `key.properties.example`:
   ```properties
   storePassword=YOUR_STORE_PASSWORD
   keyPassword=YOUR_KEY_PASSWORD
   keyAlias=upload
   storeFile=upload-keystore.jks
   ```
   > [!CAUTION]
   > Never commit `upload-keystore.jks` or `key.properties` to version control! Back up your keystore securely.

### 2.3 Step 2: Extract SHA-1 & SHA-256 Cert Fingerprints
You need certificate fingerprints for Google Sign-In and Android App Links:

```bash
# Extract Upload Keystore SHA-1 and SHA-256 (Windows)
keytool -list -v -keystore mobile/android/upload-keystore.jks -alias upload -storepass YOUR_STORE_PASSWORD
```
- Copy the **SHA-1** into Google Cloud Console for OAuth 2.0 Client Credentials (Android).
- Copy the **SHA-256** into your backend `.env`: `APP_LINK_ANDROID_SHA256_CERT_FINGERPRINTS`.

### 2.4 Step 3: Build the Test APK / App Bundle

#### Method A: Testing with Cloudflare Dev Tunnel (Fastest Live Test)
To test physical Android devices anywhere without deploying a server yet:
1. Start local backend with `docker compose up --build`.
2. Launch Cloudflare Dev Tunnel from repo root:
   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts/dev_tunnel.ps1
   ```
3. Copy printed HTTPS URL (e.g., `https://random-subdomain.trycloudflare.com`).
4. Build the test APK:
   ```bash
   cd mobile
   flutter build apk --release \
     --dart-define=API_BASE_URL=https://random-subdomain.trycloudflare.com \
     --dart-define=GOOGLE_SERVER_CLIENT_ID=YOUR_WEB_CLIENT_ID.apps.googleusercontent.com
   ```
5. Install on test device: `mobile/build/app/outputs/flutter-apk/app-release.apk`.

#### Method B: Testing against Staging/Production HTTPS Domain
```bash
cd mobile
flutter build appbundle --release \
  --dart-define=API_BASE_URL=https://speedquiz.app \
  --dart-define=GOOGLE_SERVER_CLIENT_ID=YOUR_WEB_CLIENT_ID.apps.googleusercontent.com
```

---

## 3. Phase 2: Three Hosting Tiers for 1,000 CCU

To achieve 1,000 CCU (250–500 RPS), the backend must be optimized across compute, memory, database connection pools, and web workers. Below are 3 implementation categories:

---

### Option A: No-Cost Tier ($0 / month)

**Target Audience**: Developers launching on a strict $0 budget who still demand smooth 1,000 CCU performance.

#### Infrastructure Architecture
- **Compute Server**: Oracle Cloud Infrastructure (OCI) **Always Free ARM Instance** (4 Ampere vCPUs, 24 GB RAM, 200 GB Storage, 10 TB Egress/mo).
- **DNS & Security**: Cloudflare Free Tier (Free DNS, Free SSL/TLS, Free DDOS Protection, Free CDN).
- **Deployment**: Docker Compose with Caddy reverse proxy on the OCI instance.

```text
[ Cloudflare Free Edge (DNS + WAF) ]
                 │
                 ▼ HTTPS
[ OCI Always Free Instance (4 vCPU / 24 GB RAM) ]
   ├── Caddy Container (Port 80/443 Auto-TLS)
   ├── FastAPI API Container (4 Uvicorn Workers)
   ├── AI Worker Container
   ├── PostgreSQL 16 (Tuned 1.5 GB Shared Buffers)
   └── Redis 7 (Tuned Memory Limits)
```

#### Step-by-Step Implementation Guide (No-Cost)

1. **Provision Oracle Cloud Always Free Instance**:
   - Register for Oracle Cloud.
   - Create instance: `VM.Standard.A1.Flex` (4 OCPUs / 4 vCPUs, 24 GB RAM, Ubuntu 24.04 ARM64).
   - In OCI Console -> VCN Security List: Open ingress ports `80` and `443` (0.0.0.0/0).

2. **Configure Ubuntu Firewall & Install Docker**:
   ```bash
   ssh ubuntu@YOUR_OCI_IP
   sudo iptables -F
   sudo netfilter-persistent save
   curl -fsSL https://get.docker.com | sh
   sudo usermod -aG docker ubuntu
   ```

3. **Configure Cloudflare DNS**:
   - Add `A` record: `@` -> `YOUR_OCI_IP` (Proxied).
   - Set SSL/TLS Encryption mode to **Full (strict)**.

4. **Deploy SpeedQuiz Stack via Docker Compose**:
   Clone repository to `/opt/speedquiz` and set `.env`:
   ```env
   APP_ENV=production
   DEBUG=false
   CORS_ORIGINS=https://speedquiz.app
   POSTGRES_USER=speedquiz
   POSTGRES_PASSWORD=STRONG_RANDOM_PASSWORD_HERE
   POSTGRES_DB=speedquiz
   DATABASE_URL=postgresql+asyncpg://speedquiz:STRONG_RANDOM_PASSWORD_HERE@postgres:5432/speedquiz
   DATABASE_URL_SYNC=postgresql+psycopg://speedquiz:STRONG_RANDOM_PASSWORD_HERE@postgres:5432/speedquiz
   REDIS_URL=redis://redis:6379/0
   JWT_SECRET=GENERATE_64_CHAR_HEX_SECRET
   LLM_PROVIDER=openai
   LLM_API_KEY=sk-proj-YOUR_KEY
   SHARE_PUBLIC_BASE_URL=https://speedquiz.app
   BILLING_VERIFY_MODE=stub
   ```

5. **Tune for 1,000 CCU on OCI**:
   - In `docker-compose.prod.yml`, update API workers:
     ```yaml
     services:
       api:
         command: sh -c "alembic upgrade head && uvicorn app.main:app --host 0.0.0.0 --port 8000 --workers 4"
     ```
   - Launch production stack:
     ```bash
     docker compose -f docker-compose.yml -f docker-compose.prod.yml -f docker-compose.caddy.yml up --build -d
     ```

---

### Option B: Low-Cost Tier ($10 - $20 / month)

**Target Audience**: Indie developers wanting high reliability, dedicated compute, and single-click backups at minimal cost.

#### Infrastructure Architecture
- **VPS Provider**: Hetzner Cloud (CPX31: 4 vCPU AMD EPYC, 8 GB RAM, 160 GB NVMe ~$14/mo) or DigitalOcean Droplet (4 vCPU, 8 GB RAM ~$24/mo).
- **Stack**: Docker Compose + Caddy + Tuned Postgres 16 + Redis 7.

#### 1,000 CCU Optimization Blueprint for Low-Cost VPS

##### 1. Database Connection & System Tuning
Modify `backend/app/core/database.py` settings via environment or configuration:
```python
# Optimal for 4 Uvicorn workers handling up to 300 RPS
engine = create_async_engine(
    settings.database_url,
    pool_pre_ping=True,
    pool_size=25,        # 25 connections per worker
    max_overflow=25,     # Up to 50 max connections per worker
    pool_recycle=1800,
)
```

##### 2. PostgreSQL Configuration (`postgres.conf` overrides)
Add a custom `infrastructure/postgres/postgresql.conf`:
```ini
max_connections = 250
shared_buffers = 2GB
effective_cache_size = 6GB
maintenance_work_mem = 512MB
checkpoint_completion_target = 0.9
wal_buffers = 16MB
default_statistics_target = 100
random_page_cost = 1.1
effective_io_concurrency = 200
work_mem = 8MB
min_wal_size = 1GB
max_wal_size = 4GB
```

##### 3. Uvicorn Worker Configuration (`docker-compose.prod.yml`)
```yaml
services:
  api:
    restart: always
    command: >
      sh -c "alembic upgrade head &&
             uvicorn app.main:app --host 0.0.0.0 --port 8000 --workers 4 --limit-concurrency 1000 --backlog 2048"
```

##### 4. Caddy Reverse Proxy Configuration (`infrastructure/Caddyfile`)
```caddy
speedquiz.app {
    encode zstd gzip

    # Handle health endpoints directly
    handle /health {
        reverse_proxy api:8000
    }

    # API endpoints
    handle /api/* {
        reverse_proxy api:8000 {
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
            transport http {
                keepalive 75s
                keepalive_idle_conns 100
            }
        }
    }

    # Fallback to API
    handle {
        reverse_proxy api:8000
    }
}
```

---

### Option C: Real Production Enterprise Tier ($60 - $150+ / month)

**Target Audience**: Commercial deployment with auto-scaling, managed zero-downtime databases, automated failover, and global distribution.

#### Infrastructure Architecture

```text
                                [ Cloudflare Pro / Enterprise (WAF + Global CDN) ]
                                                        │
                                                        ▼
                        [ Managed Cloud Load Balancer (AWS ALB / GCP HTTPS LB) ]
                                                        │
                                                        ▼
                        [ Auto-Scaling API Cluster (GCP Cloud Run / AWS ECS / DO App Platform) ]
                        (Min: 2 instances, Max: 10 instances; Auto-scaling on CPU > 60%)
                                        │                               │
                                        ▼                               ▼
      [ Managed PostgreSQL (AWS RDS / GCP Cloud SQL) ]    [ Managed Redis (Upstash / ElastiCache) ]
      (Primary + Standby Read Replica, Auto Backups)      (Cluster mode, Auto eviction policies)
```

#### Managed Infrastructure Setup Details

1. **Managed Database (PostgreSQL)**:
   - **Service**: AWS RDS PostgreSQL (db.t4g.medium, 2 vCPU, 4 GB RAM) or DigitalOcean Managed PostgreSQL.
   - **Benefits**: Automatic daily snapshots, point-in-time recovery, automatic minor version updates, dedicated connection pooling.
   - **Env Config**: Set `DATABASE_URL` pointing to the managed DB connection string.

2. **Serverless / Container Auto-Scaling (GCP Cloud Run or AWS ECS)**:
   - Build API Docker image: `infrastructure/docker/Dockerfile.api`.
   - Push image to Google Container Registry (GCR) or AWS ECR.
   - Configure Cloud Run container:
     - **CPU**: 2 vCPU per instance.
     - **Memory**: 2 GB RAM per instance.
     - **Min Instances**: 2 (eliminates cold starts).
     - **Max Instances**: 10.
     - **Concurrency**: 80 requests per instance.
   - Total capacity with 10 instances: Up to **800 concurrent requests**, effortlessly supporting **3,000+ CCU**.

3. **Managed Redis Cluster**:
   - **Service**: Upstash Redis (Pay-per-request) or AWS ElastiCache for Redis.
   - Dedicated for rate limiting (`redis-py`), Leaderboard ZSETs, and user session cache.

4. **CI/CD Pipeline (GitHub Actions)**:
   Create `.github/workflows/deploy.yml`:
   - Automatically runs `pytest` in `backend/`.
   - On tag release (`v*`), builds Flutter App Bundle & publishes API container image to cloud environment.

---

## 4. Phase 3: Complete Google Play Store Publishing Walkthrough

### Step 1: Play Console App Setup
1. Log in to [Google Play Console](https://play.google.com/console).
2. Click **Create app**:
   - **App name**: SpeedQuiz
   - **Default language**: English (US)
   - **App or game**: Game
   - **Free or paid**: Free
3. Verify Application ID matches `mobile/android/app/build.gradle`: **`com.speedquiz.app`**.

### Step 2: Configure Google Cloud OAuth 2.0 & Service Account

#### A. Google Sign-In Credentials
1. Go to [Google Cloud Credentials](https://console.cloud.google.com/apis/credentials).
2. Create **OAuth 2.0 Client ID (Web Application)**:
   - Name: `SpeedQuiz Web Backend`
   - Copy Client ID -> Set on server as `GOOGLE_CLIENT_ID` and in Flutter build as `--dart-define=GOOGLE_SERVER_CLIENT_ID=...`.
3. Create **OAuth 2.0 Client ID (Android)**:
   - Package Name: `com.speedquiz.app`
   - SHA-1 Certificate Fingerprint: Paste Upload & Play Signing SHA-1.

#### B. Google Play Developer API Service Account (for Server-Side IAP Verification)
1. In Google Cloud Console, enable **Google Play Android Developer API**.
2. Create a **Service Account** (e.g., `play-billing-verifier@project.iam.gserviceaccount.com`).
3. Create & Download a **JSON key**.
4. In Google Play Console -> **Users and permissions** -> Invite Service Account email with permissions:
   - **View financial data**
   - **Manage orders and subscriptions**
5. Format JSON key into a single line string and set in server `.env`:
   ```env
   GOOGLE_PLAY_SERVICE_ACCOUNT_JSON={"type":"service_account","project_id":"...","private_key_id":"..."}
   BILLING_VERIFY_MODE=apple_google
   BILLING_ALLOW_STUB_IN_PRODUCTION=false
   ```

### Step 3: Android App Links Setup (`.well-known/assetlinks.json`)
Google Play require HTTPS App Links for verification.

1. Go to Play Console -> **App integrity** -> **App signing**.
2. Copy the **App signing key certificate SHA-256 fingerprint**.
3. Update server `.env`:
   ```env
   APP_LINK_ANDROID_PACKAGE=com.speedquiz.app
   APP_LINK_ANDROID_SHA256_CERT_FINGERPRINTS=UPLOAD_CERT_SHA256,PLAY_SIGNING_CERT_SHA256
   ```
4. Confirm assetlinks works publicly:
   ```bash
   curl -fsS https://speedquiz.app/.well-known/assetlinks.json
   ```
   *Expected Response*: JSON array containing target package `com.speedquiz.app` and sha256 fingerprints.

### Step 4: Configure In-App Products in Play Console
1. Play Console -> **Monetize** -> **In-app products**.
2. Create Product:
   - **Product ID**: `speedquiz_premium` (must match `IAP_PREMIUM_PRODUCT_ID` in `.env`).
   - **Name**: SpeedQuiz Premium Lifetime / Pass.
   - **Price**: Set local pricing (e.g., $4.99).
   - Status: **Active**.

### Step 5: Complete Mandatory Store Listing Tasks
1. **Privacy Policy**: Host a privacy policy (e.g., `https://speedquiz.app/privacy`) and enter link.
2. **App Access**: Declare all features are accessible without special restrictions (or provide test account credentials).
3. **Ads**: Declare whether app contains ads.
4. **Content Rating**: Complete questionnaire to obtain IARC rating certificate.
5. **Target Audience**: Select age group (13+ recommended).
6. **Data Safety**: Declare data collection (Email, User IDs, Performance data).

### Step 6: Build & Submit Release App Bundle (AAB)

1. Bump version in `mobile/pubspec.yaml`:
   ```yaml
   version: 1.0.0+1   # versionName + versionCode
   ```
2. Run release build command:
   ```bash
   cd mobile
   flutter pub get
   flutter build appbundle --release \
     --dart-define=API_BASE_URL=https://speedquiz.app \
     --dart-define=GOOGLE_SERVER_CLIENT_ID=YOUR_WEB_CLIENT_ID.apps.googleusercontent.com
   ```
3. Artifact generated at: `mobile/build/app/outputs/bundle/release/app-release.aab`.
4. Upload `app-release.aab` to Play Console -> **Internal testing** track.
5. Add internal tester email addresses to verify installation and real IAP purchases via licensed test accounts.
6. Promote build from **Internal testing** -> **Closed testing** -> **Production**.

---

## 5. Phase 4: Load Testing, Observability & Verification Matrix

### 5.1 Automated 1,000 CCU Load Test Script (k6)
Save as `scripts/load_test_1000_ccu.js`:

```javascript
import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  stages: [
    { duration: '1m', target: 200 },   // Ramp up to 200 users
    { duration: '3m', target: 1000 },  // Sustained 1000 CCU peak
    { duration: '1m', target: 0 },     // Ramp down
  ],
  thresholds: {
    http_req_duration: ['p(95)<100', 'p(99)<250'], // 95% requests < 100ms
    http_req_failed: ['rate<0.001'],               // Error rate < 0.1%
  },
};

const BASE_URL = __ENV.API_BASE_URL || 'https://speedquiz.app';

export default function () {
  // 1. Health check
  let res = http.get(`${BASE_URL}/health`);
  check(res, { 'status is 200': (r) => r.status === 200 });

  // 2. Fetch Leaderboards (Hot Redis Path)
  res = http.get(`${BASE_URL}/api/v1/leaderboards?scope=weekly`);
  check(res, { 'leaderboard status is 200': (r) => r.status === 200 });

  // 3. Simulate gameplay answer pause (3-5s per question)
  sleep(Math.floor(Math.random() * 3) + 3);
}
```

Run load test:
```bash
k6 run -e API_BASE_URL=https://speedquiz.app scripts/load_test_1000_ccu.js
```

### 5.2 Key Metrics Monitoring Dashboard

| Metric | Normal Range | Alert Threshold | Remediation |
| :--- | :--- | :--- | :--- |
| **CPU Utilization** | 30% - 50% | `> 85%` for 5 min | Increase Uvicorn workers or scale instances. |
| **RAM Utilization** | 40% - 60% | `> 90%` | Restart workers / increase server RAM size. |
| **DB Active Connections** | 40 - 100 | `> 200` | Scale connection pool max_overflow or add PgBouncer. |
| **Redis Memory** | 100MB - 500MB | `> 1.5 GB` | Adjust eviction policy to `volatile-lru`. |
| **HTTP 5xx Error Rate** | 0.00% | `> 0.5%` | Inspect container logs via `docker compose logs api`. |

---

## 6. Summary Checklist & Quick Reference

- [ ] **Phase 1 Test Build**: Keystore generated (`upload-keystore.jks`), `key.properties` set, SHA fingerprints registered, test APK built with `--dart-define=API_BASE_URL=...`.
- [ ] **1,000 CCU Capacity**: Database connection pool tuned (`pool_size=25`, `max_connections=250`), Uvicorn multi-worker active (`--workers 4`), Caddy proxy keep-alive configured.
- [ ] **Hosting Tier Selected**:
  - Option A ($0/mo): OCI 4-Core ARM VPS + Cloudflare Free.
  - Option B ($10-20/mo): Hetzner / DigitalOcean Dedicated VPS + Docker Compose.
  - Option C ($60-150+/mo): Managed Cloud Run / AWS RDS + Managed Redis.
- [ ] **Google Play Store**: App ID `com.speedquiz.app`, Google Cloud OAuth Web & Android Client IDs, Play Service Account JSON set on server (`BILLING_VERIFY_MODE=apple_google`), Privacy policy & Data Safety completed, signed AAB uploaded to Internal Testing.
- [ ] **Verification**: `assetlinks.json` publicly returns 200 OK, k6 load test succeeds at 1,000 CCU with P95 < 100ms.
