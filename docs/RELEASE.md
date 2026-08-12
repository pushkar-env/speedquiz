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

## 4. Store setup (Play + App Store)

**Create app** — SpeedQuiz, English (US), **Game**, Free. Confirm the
application ID matches `com.speedquiz.app`.

### Subscription products

**Monetize → Subscriptions** → create two subscriptions, each with a single
base plan and **auto-renewing** enabled:

| Product ID | Base plan | Billing period | Env var |
|---|---|---|---|
| `speedquiz_premium_monthly` | `monthly` | 1 month | `IAP_PRODUCT_MONTHLY` |
| `speedquiz_premium_annual` | `annual` | 1 year | `IAP_PRODUCT_ANNUAL` |

Both must be **Active**, and the ids must match the env vars exactly — the
backend refuses any product it does not sell.

For the intro price, add an **offer** on each base plan (Play models an
introductory price as an offer, not a separate SKU). The client passes no
offer token, so Play applies the eligible offer automatically at checkout.

The retired one-time product `speedquiz_premium` should be set to **inactive**,
not deleted. Deleting it would break restore for anyone who bought it before
the subscription launch; the backend still honours it as a lifetime unlock.

#### Pricing for India and the US

Set prices per country in the console — never in code. The client renders
`ProductDetails.price`, which is already localised and tax-inclusive, so a
player in Mumbai sees ₹ and one in Austin sees $ with no backend involvement.

A reasonable starting ladder (annual ≈ 8 months of monthly, which lands the
"Save 33%" badge the paywall computes from real prices):

| Market | Monthly | Annual |
|---|---|---|
| India (INR) | ₹99 | ₹799 |
| United States (USD) | $2.99 | $23.99 |

India-specific notes that matter:

- **Play supports UPI, net banking and wallets in India.** These settle
  asynchronously, so a purchase can sit in `PENDING` for minutes or days. The
  app shows "waiting for your payment to clear" and the entitlement arrives via
  RTDN — do not treat pending as failure.
- **Recurring card mandates (RBI e-mandate) fail far more often than in the
  US.** Grace period and account hold are normal states, not edge cases. Enable
  a grace period on both base plans in the console (Play defaults to none).
- **Google is the merchant of record** and remits GST in India and sales tax in
  the US. Declare prices as tax-inclusive for India in the console.

### Real-time developer notifications (RTDN)

Without these, renewals, cancellations and refunds never reach the backend.

1. Google Cloud → **Pub/Sub** → create topic `play-rtdn`.
2. Play Console → **Monetize → Monetization setup** → paste the full topic name
   (`projects/PROJECT/topics/play-rtdn`) and enable notifications.
3. Grant `google-play-developer-notifications@system.gserviceaccount.com` the
   **Pub/Sub Publisher** role on that topic.
4. Create a **push subscription** pointing at the backend:

```text
https://YOUR-PUBLIC-URL/api/v1/billing/webhooks/google?token=SHARED_SECRET
```

5. Authenticate it. Set at least one of these, or the endpoint refuses to
   process in production:

```env
GOOGLE_RTDN_SHARED_SECRET=<the same value as ?token=>
# Stronger: attach a service account to the push subscription and verify its
# OIDC token instead of (or as well as) the URL secret.
GOOGLE_RTDN_OIDC_AUDIENCE=https://YOUR-PUBLIC-URL
GOOGLE_RTDN_OIDC_SERVICE_ACCOUNT=pubsub-push@PROJECT.iam.gserviceaccount.com
```

Send a test notification from Monetization setup and confirm a `billing_events`
row appears with `notification_type = 'test'`.

### App Store Connect subscriptions

**Monetization → Subscriptions** → create **one subscription group**
(`SpeedQuiz Premium`) containing both products. The group is what makes a plan
change an upgrade/downgrade instead of two active subscriptions — with two
separate groups a user could end up paying twice.

| Product ID | Duration | Level |
|---|---|---|
| `speedquiz_premium_monthly` | 1 month | 2 |
| `speedquiz_premium_annual` | 1 year | 1 (higher rank = upgrade) |

Add an **introductory offer** to each for the intro price. Apple applies
eligibility itself, so the client asks for nothing special.

Set prices per storefront from the same ladder as Play. Apple is the merchant
of record and handles GST/sales tax in both markets.

#### App Store Server API key

**Users and Access → Integrations → In-App Purchase** → generate a key.

```env
APPLE_IAP_ISSUER_ID=<issuer uuid>
APPLE_IAP_KEY_ID=<key id>
APPLE_IAP_PRIVATE_KEY=-----BEGIN PRIVATE KEY-----\nMIG...\n-----END PRIVATE KEY-----
APPLE_IAP_BUNDLE_ID=com.speedquiz.app
APPLE_IAP_ENVIRONMENT=Production
```

The `.p8` body goes in as one line with `\n` escapes.

#### App Store Server Notifications V2

**App Information → App Store Server Notifications** → set the **Version 2**
production and sandbox URLs to:

```text
https://YOUR-PUBLIC-URL/api/v1/billing/webhooks/apple
```

Apple does not send a shared secret — it signs the body instead, so the
endpoint verifies the JWS `x5c` chain against Apple's pinned root. Fetch it
once during setup:

```bash
curl -o backend/certs/AppleRootCA-G3.cer https://www.apple.com/certificateauthority/AppleRootCA-G3.cer
```

Production **refuses to boot** with Apple IAP configured and no root CA
available, because an unverifiable notification endpoint would let anyone POST
a forged subscription event. Set `APPLE_ROOT_CA_PEM` instead if you inject it
as a secret rather than a file.

Use **Request a Test Notification** in App Store Connect and confirm a
`billing_events` row lands with `notification_type = 'TEST'`.

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
- [ ] Profile edit persists name and avatar across a restart
- [ ] Achievements and statistics load

Subscriptions, with a **licensed test account** (Play) or **sandbox tester**
(App Store) and `BILLING_VERIFY_MODE=apple_google`:

- [ ] Paywall shows both plans with **store-localised prices** — check on an
      India account and a US account; a hardcoded currency shows up here
- [ ] "Save X%" matches the real prices in both currencies
- [ ] Buying monthly grants premium and the caps lift immediately
- [ ] Switching monthly → annual **replaces** the subscription (Play should
      prorate, not sell a second one); check only one row in `subscriptions`
- [ ] Cancelling in the store keeps premium until the period ends, and the
      status card says "Premium stays active until …"
- [ ] Refunding in the console revokes premium within a notification cycle
- [ ] Reinstalling and tapping **Restore purchases** brings premium back
- [ ] A guest who buys, then signs in with Google, keeps the subscription
- [ ] `billing_events` has a row per store notification, with no duplicates
      after a redelivery
- [ ] Premium avatars are locked for a free account, and `PATCH /users/me`
      with `avatar_p01` returns 403 for a free user (test with curl — the UI
      lock is not the gate)

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

Billing specifically:

- `BILLING_VERIFY_MODE=apple_google` and `BILLING_ALLOW_STUB_IN_PRODUCTION=false`.
  Leaving stub mode on in production would let any client mint premium with an
  arbitrary string
- `APPLE_ROOT_CA_PATH` resolves (boot fails otherwise when Apple IAP is set)
- At least one of `GOOGLE_RTDN_SHARED_SECRET` / `GOOGLE_RTDN_OIDC_AUDIENCE` is
  set, or the Play webhook returns 503 and renewals never land
- Both webhook URLs are reachable over HTTPS from outside your network
- `ENTITLEMENTS_ENFORCE_QUESTION_CAPS=true` when you actually want to sell —
  with it false, premium buys unlimited access to something already unlimited

---

## 7. After launch

- Watch `/ready` and the worker's `worker_heartbeat` logs
- Set `SENTRY_DSN` — every response already carries `X-Request-ID`
- Re-run `k6 run -e PROFILE=peak scripts/loadtest.js` against a Neon branch before any traffic spike
- Confirm question counts climb; a flat bank means the worker cannot reach the LLM
