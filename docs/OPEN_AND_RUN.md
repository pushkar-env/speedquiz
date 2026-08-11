# SpeedQuiz — Open & Run (Cheat Sheet)

> **Master Production Blueprint**: For 1,000 CCU capacity planning, 3 hosting cost tiers, test build generation, and Play Store publishing, see **[PLAYSTORE_PRODUCTION_GUIDE.md](PLAYSTORE_PRODUCTION_GUIDE.md)**.
> Quick release reference: [DEPLOYMENT.md](DEPLOYMENT.md) · VPS hosting: [HOSTING.md](HOSTING.md) · Railway: [RAILWAY.md](RAILWAY.md) · Google Sign-In: [AUTH_GOOGLE.md](AUTH_GOOGLE.md) · Env providers: [ENV_PROVIDERS.md](ENV_PROVIDERS.md).

---

## One-time Setup (If Not Already Done)

```bash
cp .env.example .env
# Optional: set LLM_API_KEY in .env for real AI background question generation
```

Install Flutter dependencies:

```bash
cd mobile
flutter pub get
```

---

## Start the Backend (Every Dev Session)

From the **repo root** (`speedquiz/`):

```bash
docker compose up --build
```

- API: http://localhost:8000  
- Docs: http://localhost:8000/docs  
- Health: `curl http://localhost:8000/health`

Stop stack: `docker compose down` (add `-v` only if you want to wipe DB volumes).

---

## Run the App on Android Emulator

1. Start an emulator from Android Studio Device Manager, or:

```bash
flutter emulators --launch <emulator_id>
```

2. From `mobile/`:

```bash
flutter run -d emulator-5554
```

Defaults to API `http://10.0.2.2:8000` (emulator → host).

Pass custom API URL or Google Sign-In Client ID:

```bash
flutter run -d emulator-5554 \
  --dart-define=API_BASE_URL=http://10.0.2.2:8000 \
  --dart-define=GOOGLE_SERVER_CLIENT_ID=YOUR_WEB_CLIENT_ID.apps.googleusercontent.com
```

Google setup: [AUTH_GOOGLE.md](AUTH_GOOGLE.md).

If app installation fails after package rename (`com.speedquiz.app`):

```bash
# Windows
%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe uninstall com.example.mobile
%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe uninstall com.speedquiz.app
```

Then `flutter run` again.

---

## Physical Android Device Testing (Any Network)

Phones **cannot** reach `localhost` or `10.0.2.2` on your PC. For reliable testing across any network, expose your local API with a **public HTTPS tunnel**.

### Recommended: Cloudflare Quick Tunnel

1. Keep `docker compose up` running (API on `:8000`).
2. In a **second** terminal (repo root):

```powershell
powershell -ExecutionPolicy Bypass -File scripts/dev_tunnel.ps1
```

3. Copy printed URL (e.g. `https://something.trycloudflare.com`).
4. Rebuild & install test APK:

```bash
cd mobile
flutter build apk --release \
  --dart-define=API_BASE_URL=https://something.trycloudflare.com \
  --dart-define=GOOGLE_SERVER_CLIENT_ID=YOUR_WEB_CLIENT_ID.apps.googleusercontent.com
```

Install `mobile/build/app/outputs/flutter-apk/app-release.apk` on any Android device.

---

## Backend Tests

```bash
docker compose exec api pytest -q
```

---

## Useful Paths & Guides

| What | Reference |
| :--- | :--- |
| **Master Play Store & 1,000 CCU Guide** | **[docs/PLAYSTORE_PRODUCTION_GUIDE.md](PLAYSTORE_PRODUCTION_GUIDE.md)** |
| **Deployment Quick Reference** | **[docs/DEPLOYMENT.md](DEPLOYMENT.md)** |
| **Hosting & Caddy Setup** | **[docs/HOSTING.md](HOSTING.md)** |
| **Env Variables & Secrets** | **[docs/ENV_PROVIDERS.md](ENV_PROVIDERS.md)** |
| **Google Sign-In Guide** | **[docs/AUTH_GOOGLE.md](AUTH_GOOGLE.md)** |
| **Flutter Mobile App** | `mobile/` |
| **Backend API** | `backend/` |
