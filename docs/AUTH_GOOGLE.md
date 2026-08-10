# Google Sign-In setup

QuizVerse uses **Google ID tokens**: the Flutter app signs in with Google, then `POST /api/v1/auth/google` verifies the token and returns QuizVerse JWTs. Guests are **upgraded in place** (progress kept) when a Bearer guest token is present.

## 1. Google Cloud Console

1. Open [Google Cloud Console](https://console.cloud.google.com/) → create or select a project.
2. **APIs & Services → OAuth consent screen** → configure (External is fine for testing). Add test users while in Testing.
3. **APIs & Services → Credentials → Create credentials → OAuth client ID**:
   - **Web application** (required) — this ID is both:
     - `GOOGLE_CLIENT_ID` on the API (token `aud` check)
     - Flutter `--dart-define=GOOGLE_SERVER_CLIENT_ID=...` (`serverClientId`)
   - **Android** — Application id `com.quizverse.app`, SHA-1 of your keystore (debug for local, upload for Play).

### Debug SHA-1 (Windows)

```bash
keytool -list -v -alias androiddebugkey -keystore %USERPROFILE%\.android\debug.keystore -storepass android -keypass android
```

Copy the **SHA1** fingerprint into the Android OAuth client.

## 2. Backend env

In root `.env` (local) or Railway Variables (prod):

```env
GOOGLE_CLIENT_ID=123456789-xxxx.apps.googleusercontent.com
```

Empty → `POST /auth/google` returns **503**.

Restart API after changing env (`docker compose restart api` or redeploy).

## 3. Flutter run / build

```bash
cd mobile
flutter run -d emulator-5554 --dart-define=GOOGLE_SERVER_CLIENT_ID=123456789-xxxx.apps.googleusercontent.com

# Physical / tunnel APK example:
flutter build apk --release ^
  --dart-define=API_BASE_URL=https://YOUR-API ^
  --dart-define=GOOGLE_SERVER_CLIENT_ID=123456789-xxxx.apps.googleusercontent.com
```

Use the **same Web client ID** as `GOOGLE_CLIENT_ID`.

## 4. In-app flow

1. App still boots as **guest** (splash).
2. Open **Profile** → **SIGN IN WITH GOOGLE**.
3. Pick a Google account → API links the guest row → Profile shows email / non-guest.

## 5. API contract

`POST /api/v1/auth/google`

```json
{ "id_token": "<google-jwt>" }
```

Optional `Authorization: Bearer <guest-access-token>` to upgrade the current guest.

Response: same `TokenResponse` as email login (`access_token`, `refresh_token`, `user`).

## 6. iOS (later)

Create an **iOS** OAuth client (bundle `com.quizverse.app`) and follow [google_sign_in iOS setup](https://pub.dev/packages/google_sign_in). Android-first is enough for the first Play launch.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| 503 from API | Set `GOOGLE_CLIENT_ID` and restart API |
| “ID token is null” | Missing/wrong Web client as `serverClientId` |
| ApiException: 10 / DEVELOPER_ERROR | Android OAuth client SHA-1 / package mismatch |
| 401 invalid token | Web client ID mismatch between app and API |
| 409 email conflict | Email already registered via email/password |

See also [OPEN_AND_RUN.md](OPEN_AND_RUN.md), [RAILWAY.md](RAILWAY.md), [ENV_PROVIDERS.md](ENV_PROVIDERS.md).
