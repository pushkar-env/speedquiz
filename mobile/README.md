# SpeedQuiz mobile (Flutter)

Application id / bundle id: **`com.speedquiz.app`**

## Local run (Android)

```bash
# From repo root
docker compose up --build   # API on :8000

cd mobile
flutter pub get
flutter run -d emulator-5554
```

Emulator API default: `http://10.0.2.2:8000`  
Override: `flutter run --dart-define=API_BASE_URL=http://<host>:8000`

## Release App Bundle (Play Store)

1. Create `android/key.properties` from `android/key.properties.example` + upload keystore.
2. Build:

```bash
flutter build appbundle --release --dart-define=API_BASE_URL=https://speedquiz.app
```

3. Upload `build/app/outputs/bundle/release/app-release.aab` in Play Console.

Day-to-day: [docs/OPEN_AND_RUN.md](../docs/OPEN_AND_RUN.md).  
Google Sign-In: [docs/AUTH_GOOGLE.md](../docs/AUTH_GOOGLE.md).  
Railway deploy: [docs/RAILWAY.md](../docs/RAILWAY.md).  
Full Play steps: [docs/DEPLOYMENT.md](../docs/DEPLOYMENT.md).

## iOS

Associated Domains + bundle id are configured for a later App Store launch. Prefer Android Play first; see deployment docs when you are ready for TestFlight.
