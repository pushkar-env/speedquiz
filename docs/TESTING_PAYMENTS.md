# Testing payments

Two phases. **Phase 1** needs no Play Console, no money, and no new build —
three environment variables on Railway and the APK you already have. **Phase 2**
is the real Play sandbox, for when you are close to launching.

Do Phase 1 first. It proves the paywall, the gates, the cosmetics and the
entitlement plumbing all work. Phase 2 only adds the store itself.

---

## Phase 1 — test on your existing build (15 minutes)

### 1. Run the migration

The subscription columns do not exist in Neon yet. Nothing below works until
this runs:

```bash
cd backend && alembic upgrade head
```

Run it against the **Neon** database (the one `DATABASE_URL` points at on
Railway), not a local one. Confirm it landed:

```sql
select column_name from information_schema.columns
where table_name = 'subscriptions' and column_name = 'store_subscription_id';
```

One row back means you are good.

### 2. Set three variables on Railway

Railway → your API service → **Variables**:

```env
ENTITLEMENTS_ENFORCE_QUESTION_CAPS=true
FREE_UNIQUE_QUESTIONS_PER_TOPIC=5
BILLING_ALLOW_STUB_IN_PRODUCTION=true
```

What each one does:

| Variable | Why |
|---|---|
| `ENTITLEMENTS_ENFORCE_QUESTION_CAPS=true` | **Without this Premium unlocks nothing.** Free play is unlimited by default, so the paywall would never appear and buying would change nothing observable. |
| `FREE_UNIQUE_QUESTIONS_PER_TOPIC=5` | Hit the paywall in one quiz instead of six. Put this back to `30` before launch. |
| `BILLING_ALLOW_STUB_IN_PRODUCTION=true` | Railway runs `APP_ENV=production`, where simulated purchases are refused by default. This opts in. **Remove it before you take real money.** |

**Leave `APP_ENV=production`.** Do not switch it to `development` to make
testing easier — the variable above already does that, which is the whole
reason it exists. Dropping out of production mode on a live deployment makes
`/docs` public, disables the `JWT_SECRET` and `DEBUG` guards, and leaves you
one forgotten variable away from launching in the wrong mode.

Redeploy. The API returns `"stub_purchase_allowed": true`, and the app switches
the paywall into test mode by itself — no rebuild.

**`ENTITLEMENTS_DEV_TOGGLE` must be `false`, or not set at all.** If it is
already `true` from earlier experimenting, delete it now — the service refuses
to boot with it on in production, and you do not need it. It exposes an endpoint
that hands out Premium to anyone who asks; `BILLING_ALLOW_STUB_IN_PRODUCTION`
routes through real purchase verification instead.

While you are in there, `DEBUG` must also be `false` — same guard, same result
if it is on.

### API service or worker service?

All three billing variables above go on the **API service only**. The worker
never verifies a purchase or serves the paywall.

But the safety guards are a different story, and this catches people out:

> **Both services build a `Settings` object at startup, so both run the
> production validator.** `ENTITLEMENTS_DEV_TOGGLE=true` or `DEBUG=true` crashes
> the **worker** exactly as it crashes the API. If you fixed the API and the
> worker is still dead, this is why.

| Variable | API | Worker | Notes |
|---|:--:|:--:|---|
| `APP_ENV` | ✅ | ✅ | **Must match.** See the warning below. |
| `DEBUG`, `JWT_SECRET` | ✅ | ✅ | Validated on both; a mismatch or a bad value stops either service booting. |
| `ENTITLEMENTS_DEV_TOGGLE` | ✅ `false` | ✅ `false` | Or absent on both. |
| `DATABASE_URL`, `DATABASE_URL_SYNC`, `REDIS_URL` | ✅ | ✅ | Worker reads jobs and runs the subscription sweep. |
| `LOG_LEVEL`, `SENTRY_DSN` | ✅ | ✅ | |
| `ENTITLEMENTS_ENFORCE_QUESTION_CAPS` | ✅ | ➖ | Read in the request path only. |
| `FREE_UNIQUE_QUESTIONS_PER_TOPIC` | ✅ | ➖ | |
| `BILLING_ALLOW_STUB_IN_PRODUCTION` | ✅ | ➖ | |
| `BILLING_VERIFY_MODE`, `IAP_PRODUCT_*` | ✅ | ➖ | Phase 2. |
| `GOOGLE_PLAY_*`, `GOOGLE_RTDN_*`, `APPLE_*` | ✅ | ❌ | Phase 2. **Do not copy these to the worker** — it cannot use them, and setting the Apple ones without the root CA file will stop it booting. |
| `LLM_API_KEY`, `LLM_MODEL_*`, `TOPIC_BANK_*` | ➖ | ✅ | Question generation. |

✅ set · ➖ harmless but unused · ❌ actively avoid

> **`APP_ENV` must be identical on both services.** The worker's hourly
> subscription sweep recomputes `is_premium`, and that calculation depends on
> `APP_ENV` — a worker on `development` while the API is on `production` will
> keep flipping test subscriptions back to Premium that the API considers
> invalid. Two services disagreeing about who is a paying customer is a
> genuinely nasty bug to chase.

If Railway shows both services under one project, use **shared variables** for
the rows marked ✅/✅ so they cannot drift apart.

### 3. Check the server before touching the app

```bash
API=https://your-railway-url

TOKEN=$(curl -sX POST $API/api/v1/auth/guest \
  | python -c "import sys,json;print(json.load(sys.stdin)['access_token'])")

curl -s $API/api/v1/entitlements/me -H "Authorization: Bearer $TOKEN"
```

You want to see:

```json
{ "is_premium": false, "enforce_caps": true,
  "unique_per_topic_limit": 5, "stub_purchase_allowed": true }
```

If `enforce_caps` is `false`, the variables did not apply — check the deploy
finished. If `stub_purchase_allowed` is `false`, `BILLING_ALLOW_STUB_IN_PRODUCTION`
is missing or misspelt.

### 4. Test in the app

Open the build you already have. No rebuild needed — all of this is
server-driven.

1. **Profile → Premium.** A cyan **Test mode** banner appears, both plans are
   listed, and the button reads `TEST PURCHASE · ANNUAL`.
2. **Play a quiz** past 5 unique questions in one topic. The paywall sheet
   should interrupt you.
3. **Tap the test purchase button.** Premium unlocks, the caps lift, and the
   status card shows the plan with a renewal date.
4. **Profile → Edit.** The six premium avatars (crown, eclipse, aurora, meteor,
   diamond, phoenix) are now unlocked — they showed a gold padlock before.
5. **Leaderboard.** Your row has a gold badge and a premium avatar ring.
6. **Custom topics.** Generate more than the free daily limit.

Confirm it stuck server-side:

```bash
curl -s $API/api/v1/entitlements/me -H "Authorization: Bearer $TOKEN"
# is_premium: true, unique_per_topic_limit: null, plan_code: "annual"
```

### 5. Reset to free and go again

There is no "unbuy" in the app, so clear it in Neon:

```sql
delete from subscriptions where user_id = '<your-user-id>';
update users set is_premium = false where id = '<your-user-id>';
```

Your user id is the `user_id` in the `/entitlements/me` response, or just take
the newest row:

```sql
select id, is_premium from users order by created_at desc limit 5;
```

### If the deploy fails to boot

The API refuses to start on an unsafe production config rather than serving
traffic that looks healthy while handing out free Premium. The error names the
variable:

| Error mentions | Fix |
|---|---|
| `ENTITLEMENTS_DEV_TOGGLE` | Set it to `false` or delete it. Use `BILLING_ALLOW_STUB_IN_PRODUCTION=true` to test purchases instead. |
| `DEBUG` | Set `DEBUG=false`. |
| `JWT_SECRET` | Needs a real 32+ character secret: `openssl rand -hex 32`. Rotating it signs out every existing user. |
| `Apple Root CA` | Only when Apple IAP is configured — see [RELEASE.md](RELEASE.md#app-store-server-notifications-v2). Not relevant to Phase 1. Usually means store credentials were copied to the worker by mistake. |

These are all boot-time, so a failed deploy leaves the previous version running.

**Check both services.** The same validator runs in the API and the worker, so
a variable that stops one will stop the other. Fixing only the API leaves the
worker crash-looping, and the symptom is indirect: no new questions get
generated and lapsed subscriptions never expire.

### What Phase 1 does **not** prove

Everything that needs a real store: actual prices, ₹ vs $, renewals,
cancellation, failed payments, refunds, and restore-after-reinstall. That is
Phase 2.

---

## Phase 2 — real Play sandbox (when you are near launch)

Real Play purchases, still no charge. Android only; iOS is in
[RELEASE.md](RELEASE.md#app-store-connect-subscriptions).

### 1. Create the subscriptions

Play Console → **Monetize → Subscriptions**. Two products, one base plan each,
auto-renewing:

| Product ID | Base plan | Period |
|---|---|---|
| `speedquiz_premium_monthly` | `monthly` | 1 month |
| `speedquiz_premium_annual` | `annual` | 1 year |

The ids must match exactly — the backend refuses any product it does not sell.
Set a **grace period** on both (Play defaults to none, and you cannot test
failed renewals without it). Set India and US prices; suggested starting point
is ₹99 / ₹799 and $2.99 / $23.99. Allow a few hours to propagate.

### 2. Service account

Enable the **Google Play Android Developer API**, create a service account,
download the JSON key, and invite it in Play Console → **Users and permissions**
with *View financial data* and *Manage orders and subscriptions*.

Railway:

```env
GOOGLE_PLAY_SERVICE_ACCOUNT_JSON={"type":"service_account",...}
BILLING_VERIFY_MODE=apple_google
```

The JSON must be on one line.

### 3. License testers

Play Console → **Setup → License testing** → add your Gmail account. This makes
purchases free *and* compresses renewals so a year passes in about half an hour.

### 4. Real-time notifications

Without these, renewals and refunds never reach the backend.

1. Google Cloud → Pub/Sub → create topic `play-rtdn`.
2. Grant `google-play-developer-notifications@system.gserviceaccount.com` the
   **Pub/Sub Publisher** role on it.
3. Play Console → **Monetize → Monetization setup** → paste the topic name,
   enable notifications.
4. Create a **push subscription** to:

   ```text
   https://your-railway-url/api/v1/billing/webhooks/google?token=SOME_LONG_RANDOM_STRING
   ```

5. Railway: `GOOGLE_RTDN_SHARED_SECRET=SOME_LONG_RANDOM_STRING`

Then hit **Send test notification** in Monetization setup and check:

```sql
select provider, notification_type, processed_at, error
from billing_events order by created_at desc limit 5;
```

A row with `notification_type = 'test'` means the pipe works. **If this does not
appear, stop and fix it** — nothing below works without it.

### 5. Switch off test mode

```env
BILLING_ALLOW_STUB_IN_PRODUCTION=false
```

The app drops the test banner on its own and starts using real store products.

### 6. Upload to internal testing

IAP does not work against an unpublished app. Upload the AAB to **Internal
testing** and install from the Play link — not `flutter run`.

### 7. What to actually test

License testers get fake payment methods at checkout:

| Instrument | Tests |
|---|---|
| Test card, always approves | Purchase, renewal, plan switch |
| Test card, always declines | Failed renewal → grace → hold |
| Test instrument, slow approval | The `pending` state (this is the UPI path) |

The two that cost real money if broken:

- **Monthly → annual must replace, not stack.** After switching:
  `select count(*) from subscriptions where user_id = '...';` must be `1`. If
  it is `2`, the user is being billed twice.
- **Refund revokes.** Refund in the console, wait a minute, confirm
  `status = 'revoked'` and premium is gone in the app.

Then the rest: cancel (premium survives to period end), reinstall + **Restore
purchases**, and a guest who buys then signs in with Google keeps it.

---

## Before charging real money

```env
BILLING_VERIFY_MODE=apple_google
BILLING_ALLOW_STUB_IN_PRODUCTION=false
ENTITLEMENTS_DEV_TOGGLE=false
ENTITLEMENTS_ENFORCE_QUESTION_CAPS=true
FREE_UNIQUE_QUESTIONS_PER_TOPIC=30
```

Verify with a fresh guest token that `stub_purchase_allowed` is `false` and
`billing_mode` is `store`. Then check the paywall on an **India-region store
account and a US one** — wrong-currency bugs only show up there.

Full store setup, iOS, and the launch checklist: [RELEASE.md](RELEASE.md).
