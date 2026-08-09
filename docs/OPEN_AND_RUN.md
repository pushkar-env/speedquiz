# QuizVerse — open & run (cheat sheet)

Use this the next time you open the project. Full Play/prod detail: [DEPLOYMENT.md](DEPLOYMENT.md) · env providers: [ENV_PROVIDERS.md](ENV_PROVIDERS.md).

## One-time (if not already done)

```bash
cp .env.example .env
# Optional: set LLM_API_KEY in .env for real AI generation
```

Install Flutter deps:

```bash
cd mobile
flutter pub get
```

## Start the backend (every session)

From the **repo root** (`quizverse/`):

```bash
docker compose up --build
```

- API: http://localhost:8000  
- Docs: http://localhost:8000/docs  
- Health: `curl http://localhost:8000/health`

Stop: `docker compose down` (add `-v` only if you want to wipe DB volumes).

## Run the app on Android emulator

1. Start an emulator (Android Studio Device Manager), or:

```bash
flutter emulators --launch <emulator_id>
```

2. From `mobile/`:

```bash
flutter run -d emulator-5554
```

Defaults to API `http://10.0.2.2:8000` (emulator → host).

Other devices:

```bash
flutter devices
flutter run -d <device_id>
```

Custom API URL:

```bash
flutter run -d emulator-5554 --dart-define=API_BASE_URL=http://10.0.2.2:8000
```

After the **package rename** (`com.quizverse.app`), if install fails:

```bash
# Windows
%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe uninstall com.example.mobile
%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe uninstall com.quizverse.app
```

Then `flutter run` again.

## Physical Android device (any network)

A phone **cannot** reach `localhost` or `10.0.2.2` on your PC. Same-Wi‑Fi LAN IPs often fail (AP isolation / firewall). For reliable device testing, expose the local API with a **public HTTPS tunnel**.

### Recommended: Cloudflare quick tunnel

1. Keep `docker compose up` running (API on `:8000`).
2. In a **second** terminal (repo root):

```powershell
powershell -ExecutionPolicy Bypass -File scripts/dev_tunnel.ps1
```

3. Copy the printed URL, e.g. `https://something.trycloudflare.com`.
4. Confirm on the phone browser: `https://something.trycloudflare.com/health`
5. Rebuild + install:

```bash
cd mobile
flutter build apk --release --dart-define=API_BASE_URL=https://something.trycloudflare.com
```

Install `build/app/outputs/flutter-apk/app-release.apk` on any device (Wi‑Fi or mobile data).

**Keep the tunnel window open** while testing. Quick tunnels get a **new URL each start** — rebuild the APK when the URL changes.

### Optional: same Wi‑Fi LAN (fragile)

Only if the phone browser can open `http://<PC-LAN-IP>:8000/health`:

```bash
flutter build apk --release --dart-define=API_BASE_URL=http://192.168.1.7:8000
```

### How production works (no tunnel)

In production the API is hosted on the public internet with a real domain + TLS (e.g. `https://quizverse.app`). Store builds bake that URL in:

```bash
flutter build appbundle --release --dart-define=API_BASE_URL=https://quizverse.app
```

Also set server `SHARE_PUBLIC_BASE_URL=https://quizverse.app` and App Link fingerprints (see [DEPLOYMENT.md](DEPLOYMENT.md)). Phones talk to that HTTPS API from any network — same as any commercial app. The tunnel is **dev-only** so you can test before you rent hosting.

## Local release build (debug-signed)

No Play upload keystore needed — Gradle uses the **debug** keystore when `mobile/android/key.properties` is missing.

From `mobile/`:

```bash
# Prefer the tunnel HTTPS URL for real phones (see above).
flutter build apk --release --dart-define=API_BASE_URL=https://YOUR-TUNNEL.trycloudflare.com

# Emulator-only shortcut:
flutter build apk --release --dart-define=API_BASE_URL=http://10.0.2.2:8000

# App Bundle (practice Play upload flow)
flutter build appbundle --release --dart-define=API_BASE_URL=https://quizverse.app
```

Outputs:

| Artifact | Path |
|----------|------|
| APK | `mobile/build/app/outputs/flutter-apk/app-release.apk` |
| AAB | `mobile/build/app/outputs/bundle/release/app-release.aab` |

Install APK on a running emulator:

```bash
# Windows
%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe -s emulator-5554 install -r build\app\outputs\flutter-apk\app-release.apk
```

Or:

```bash
flutter install -d emulator-5554 --release
```

**Note:** Debug-signed release builds are for local/QA only — **not** for Play Store. For Play, create `android/key.properties` from `android/key.properties.example` and build with your production `API_BASE_URL` (see [DEPLOYMENT.md](DEPLOYMENT.md)).

## Backend tests

```bash
docker compose exec api pytest -q
```

## Hot reload while developing

With `flutter run` attached:

- `r` — hot reload  
- `R` — hot restart  
- `q` — quit  

## Useful paths

| What | Where |
|------|--------|
| Flutter app | `mobile/` |
| API | `backend/` |
| Env template | `.env.example` → copy to `.env` |
| Dev tunnel | `scripts/dev_tunnel.ps1` |
| Package id | `com.quizverse.app` |
| This cheat sheet | `docs/OPEN_AND_RUN.md` |
