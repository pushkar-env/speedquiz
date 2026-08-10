# QuizVerse Deployment & Production Release Guide

> **Master Guide**: For the comprehensive end-to-end blueprint, 1,000 CCU performance tuning, test build generation, 3 hosting cost categories, and step-by-step Play Store publishing, refer to **[PLAYSTORE_PRODUCTION_GUIDE.md](PLAYSTORE_PRODUCTION_GUIDE.md)**.

This document covers quick deployment references for **local development**, **production API hosting**, and **Google Play Store** release.

---

## Production Quick Reference

- **Application ID / Package**: `com.quizverse.app`
- **Primary HTTPS Domain**: `https://quizverse.app`
- **App Links URL**: `https://quizverse.app/.well-known/assetlinks.json`
- **Result Share URL**: `https://quizverse.app/r/{session_id}`
- **Master Operational Blueprint**: **[PLAYSTORE_PRODUCTION_GUIDE.md](PLAYSTORE_PRODUCTION_GUIDE.md)**

---

## 1. Test Build & Pre-Flight Verification

To test all app features (Google Sign-In, AI Custom Topics, IAP stub/sandbox, Leaderboards, Share cards, Deep Links) before store submission:

### A. Quick Cloudflare Dev Tunnel Build (Physical Device Anywhere)
```bash
# Terminal 1: Run local backend
docker compose up --build

# Terminal 2: Launch tunnel (repo root)
powershell -ExecutionPolicy Bypass -File scripts/dev_tunnel.ps1

# Terminal 3: Build release test APK
cd mobile
flutter build apk --release \
  --dart-define=API_BASE_URL=https://<your-tunnel-subdomain>.trycloudflare.com \
  --dart-define=GOOGLE_SERVER_CLIENT_ID=<your-web-client-id>.apps.googleusercontent.com
```

### B. Production Target App Bundle (Play Store Release)
```bash
# Create upload keystore & key.properties first (see PLAYSTORE_PRODUCTION_GUIDE.md § 2.2)
cd mobile
flutter build appbundle --release \
  --dart-define=API_BASE_URL=https://quizverse.app \
  --dart-define=GOOGLE_SERVER_CLIENT_ID=<your-web-client-id>.apps.googleusercontent.com
```

---

## 2. 1,000 CCU Production Architecture & Hosting Options

QuizVerse isolates gameplay from LLM calls (serving questions directly from PostgreSQL and Redis), allowing high throughput (250–500 RPS).

### Three Hosting Categories (See [PLAYSTORE_PRODUCTION_GUIDE.md](PLAYSTORE_PRODUCTION_GUIDE.md) for full configs)

1. **No-Cost Category ($0/mo)**: Oracle Cloud Infrastructure (OCI) Always Free 4-Core ARM VPS (24 GB RAM) + Cloudflare Free DNS/Proxy + Docker Compose.
2. **Low-Cost Category ($10–$20/mo)**: Single Ubuntu VPS (4 vCPU / 8 GB RAM on Hetzner or DigitalOcean) with Docker Compose (`uvicorn --workers 4`), tuned PostgreSQL connection pool (`pool_size=25`), and Caddy HTTP/2 proxy.
3. **Real Production Enterprise Category ($60–$150+/mo)**: GCP Cloud Run / AWS ECS Auto-Scaling containers (2 to 10 instances) + Managed PostgreSQL (AWS RDS / Cloud SQL) + Managed Redis (Upstash / ElastiCache) + Cloudflare WAF/CDN.

---

## 3. Google Play Store Submission Steps

1. **Upload Keystore**: Create `mobile/android/key.properties` and extract SHA-1 / SHA-256 fingerprints.
2. **Google Cloud Credentials**: Register Web Client ID (`GOOGLE_CLIENT_ID`) and Android Client ID in Google Cloud Console.
3. **Play Developer API Service Account**: Generate JSON key, invite to Play Console, and set `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` on backend with `BILLING_VERIFY_MODE=apple_google`.
4. **App Links Fingerprints**: Add SHA-256 certificate fingerprints to `APP_LINK_ANDROID_SHA256_CERT_FINGERPRINTS` so `https://quizverse.app/.well-known/assetlinks.json` verifies successfully.
5. **App Bundle Upload**: Upload `mobile/build/app/outputs/bundle/release/app-release.aab` to Play Console Internal Testing track -> Closed Testing -> Production.

---

## 4. Operational Documentation Links

- **[PLAYSTORE_PRODUCTION_GUIDE.md](PLAYSTORE_PRODUCTION_GUIDE.md)** — Master Play Store & 1,000 CCU Production Guide.
- **[HOSTING.md](HOSTING.md)** — Docker Compose & Caddy server hosting setup.
- **[ENV_PROVIDERS.md](ENV_PROVIDERS.md)** — Environment variables & provider secrets checklist.
- **[AUTH_GOOGLE.md](AUTH_GOOGLE.md)** — Google Sign-In setup guide.
- **[OPEN_AND_RUN.md](OPEN_AND_RUN.md)** — Local development & quick start cheat sheet.
