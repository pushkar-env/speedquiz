# Release

Getting SpeedQuiz onto Google Play.

- Running locally: [DEVELOPMENT.md](DEVELOPMENT.md)
- Hosting the API: [DEPLOYMENT.md](DEPLOYMENT.md)

Application ID: **`com.speedquiz.app`**

---

## 1. Signing key

Everything downstream — Google Sign-In, App Links, IAP — is keyed to your
signing certificate, so do this first.

```bash
cd mobile/android && keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

Then `mobile/android/key.properties` (copy from `key.properties.example`):

```properties
storePassword=YOUR_STORE_PASSWORD
keyPassword=YOUR_KEY_PASSWORD
keyAlias=upload
storeFile=upload-keystore.jks
```

Both files are gitignored. **Back up the keystore somewhere you will still
have in five years** — losing it means you can never update the app under the
same listing.

`build.gradle.kts` uses the release config when `key.properties` exists and
falls back to debug signing when it doesn't, so a missing file produces a
silently unshippable build rather than an error.

### Fingerprints

```bash
keytool -list -v -keystore mobile/android/upload-keystore.jks -alias upload
```

To read them back off a built artifact instead (works with v2/v3 signatures,
which `keytool -printcert -jarfile` cannot read):

```bash
"$ANDROID_HOME/build-tools/36.0.0/apksigner.bat" verify --print-certs mobile/build/app/outputs/flutter-apk/app-release.apk
```

| Fingerprint | Goes to |
|---|---|
| **SHA-1** | Google Cloud Console → Android OAuth client |
| **SHA-256** | Backend `APP_LINK_ANDROID_SHA256_CERT_FINGERPRINTS` |

Once Play App Signing is enabled you have **two** certificates — your upload
key and Play's signing key. Both SHA-256 values belong in the App Links
variable, comma-separated, or links break for store installs even though they
work on your sideloaded build.

---

## 2. Google Cloud

### OAuth clients

1. [Google Cloud Credentials](https://console.cloud.google.com/apis/credentials)
2. **OAuth client ID → Web application** — this ID is used twice: `GOOGLE_CLIENT_ID` on the API, and `--dart-define=GOOGLE_SERVER_CLIENT_ID` in the build.
3. **OAuth client ID → Android** — package `com.speedquiz.app`, plus the **SHA-1** of every key you sign with (debug for local testing, upload, and Play's signing key).

> A missing SHA-1 is the single most common Google Sign-In failure, and it
> surfaces as the picker opening then closing instantly — which looks like the
> user cancelled. Guest play keeps working, so it is easy to miss.

### Play Developer API service account (for IAP verification)

1. Enable **Google Play Android Developer API** in Google Cloud.
2. Create a service account, download a **JSON key**.
3. Play Console → **Users and permissions** → invite that service account with **View financial data** and **Manage orders and subscriptions**.
4. On the backend:

```env
GOOGLE_PLAY_SERVICE_ACCOUNT_JSON={"type":"service_account",...}
BILLING_VERIFY_MODE=apple_google
BILLING_ALLOW_STUB_IN_PRODUCTION=false
```

The JSON must be a single line. Until this is set, leave
`BILLING_VERIFY_MODE=stub` — the app shows "coming soon" and charges nothing.

---

## 3. App Links

```env
APP_LINK_ANDROID_PACKAGE=com.speedquiz.app
APP_LINK_ANDROID_SHA256_CERT_FINGERPRINTS=UPLOAD_SHA256,PLAY_SIGNING_SHA256
```

Play Console → **App integrity → App signing** has the Play certificate.
Verify what the API actually serves:

```bash
curl -fsS https://YOUR-PUBLIC-URL/.well-known/assetlinks.json
```

It must contain `com.speedquiz.app` and match the fingerprint of the build you
are testing. Compare against the APK:

```bash
"$ANDROID_HOME/build-tools/36.0.0/apksigner.bat" verify --print-certs mobile/build/app/outputs/flutter-apk/app-release.apk
```

The `speedquiz://results/{id}` custom scheme works regardless; App Links only
govern `https://` deep links.

---

## 4. Play Console setup

**Create app** — SpeedQuiz, English (US), **Game**, Free. Confirm the
application ID matches `com.speedquiz.app`.

### In-app product

**Monetize → In-app products** → create `speedquiz_premium` (must equal
`IAP_PREMIUM_PRODUCT_ID`), set pricing, status **Active**.

### Mandatory listing tasks

| Task | Notes |
|---|---|
| **Privacy policy** | A hosted URL is required. The app's landing screen also references Terms and Privacy — wire those up |
| **App access** | Declare everything is reachable without login, since guest play is the default |
| **Ads** | Declare none, unless that changes |
| **Content rating** | IARC questionnaire |
| **Target audience** | 13+ is the usual fit |
| **Data safety** | Declare what you collect: email (Google Sign-In only), user IDs, gameplay/performance data |

---

## 5. Build and submit

Bump the version — Play rejects a duplicate `versionCode`:

```yaml
version: 1.0.0+1   # versionName+versionCode
```

```bash
flutter build appbundle --release --dart-define=API_BASE_URL=https://YOUR-PUBLIC-URL --dart-define=GOOGLE_SERVER_CLIENT_ID=YOUR-WEB-CLIENT-ID.apps.googleusercontent.com
```

Artifact: `mobile/build/app/outputs/bundle/release/app-release.aab`.

Upload to **Internal testing** first, then promote **Internal → Closed →
Production**. Internal testing is where licensed test accounts can exercise
real IAP without being charged.

> An AAB is around 50 MB, but most of that is Play-stripped debug symbols and
> three ABIs. Actual per-device download is roughly 8–12 MB.

---

## 6. Before you submit

Pre-flight on a **physical device**, on **mobile data**, with a **release**
build — several of these cannot fail on an emulator or on Wi-Fi:

- [ ] Guest play works from a cold install
- [ ] Google Sign-In completes and links the guest account (progress kept)
- [ ] Sign out returns to the landing screen, sign back in restores progress
- [ ] A quiz run scores, awards XP, and appears on the leaderboard
- [ ] Custom topic generates
- [ ] Share sheet opens; the shared link opens the public card
- [ ] `speedquiz://results/{id}` opens the app
- [ ] Premium sheet opens; with `BILLING_VERIFY_MODE=stub` it charges nothing
- [ ] Profile edit persists name and avatar across a restart
- [ ] Achievements and statistics load

### Turn off development cleartext

`mobile/android/app/src/main/res/xml/network_security_config.xml` currently
permits cleartext HTTP globally so local LAN testing works. Production should
be HTTPS-only, with cleartext scoped to development hosts if you still want
LAN builds.

### Backend production checks

- `APP_ENV=production`, `DEBUG=false`, `ENTITLEMENTS_DEV_TOGGLE=false` — the app refuses to boot otherwise
- `JWT_SECRET` is a real 32+ char secret. **Rotating it signs out every existing user**, and guest accounts live only on the device — do it before launch, not after
- `SHARE_PUBLIC_BASE_URL` matches the public URL
- Question bank is deep enough that a long run cannot exhaust a topic

---

## 7. After launch

- Watch `/ready` and the worker's `worker_heartbeat` logs
- Set `SENTRY_DSN` — every response already carries `X-Request-ID`
- Re-run `k6 run -e PROFILE=peak scripts/loadtest.js` against a Neon branch before any traffic spike
- Confirm question counts climb; a flat bank means the worker cannot reach the LLM
