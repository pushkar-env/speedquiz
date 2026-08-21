# SpeedQuiz

Production-grade AI-powered quiz game for Android and iOS.

Gameplay is served from a validated question bank — not live LLM calls per question.

## Architecture

```text
mobile/          Flutter client (Riverpod, GoRouter, Dio)
backend/         FastAPI + SQLAlchemy + Alembic
workers/         Background AI generation / validation jobs
tools/ingest/    Exam paper PDF -> playable mock test
infrastructure/  Docker and deployment assets
docs/            Product and engineering docs
scripts/         Dev utilities
```

## Client design system

The Flutter client is built on one shared token + widget layer. Screens should
reach for these instead of hand-rolling colours, timings or feedback.

| Concern | Location |
|---|---|
| Colour, type, full `ThemeData` (light + dark) | `mobile/lib/core/theme/app_theme.dart` |
| Durations and curves | `mobile/lib/core/theme/app_motion.dart` |
| Haptics (with a global kill switch) | `mobile/lib/core/feedback/haptics.dart` |
| Sound cues and ambient loop | `mobile/lib/core/feedback/audio_service.dart` |
| Sound / haptics / music preferences | `mobile/lib/core/settings/app_settings.dart` |
| Route transitions | `mobile/lib/core/routing/page_transitions.dart` |
| Buttons, cards, dialogs, toasts, confetti, skeletons, … | `mobile/lib/shared/widgets/` (import `sq_widgets.dart`) |

Notes:

- Resolve colours via `context.sq` (a `SqPalette`) rather than branching on
  `Theme.of(context).brightness`.
- Space Grotesk and DM Sans are **bundled** in `mobile/assets/fonts/`, so there
  is no runtime font fetch and no first-launch fallback flash.
- Audio in `mobile/assets/audio/` is fully synthesised (see the generator note
  in `audio_service.dart`); playback is decorative and fails silently.
- Every animated widget honours the platform *reduce motion* setting.
- **Dialogs must pop with the dialog's own context.** `showSqDialog` hands its
  route context to the builder for exactly this reason: popping with the
  caller's context resolves to the GoRouter navigator and tears the current
  page off the stack, leaving a blank route.

### Screen map

```text
/splash            boot, restores a stored session
/onboarding        first run only: language, then name (device-local)
/landing           signed-out: play as guest / continue with Google
/home              hero play, surprise-me, daily challenge, topic rail   ┐
/explore           search, category rail, trending, grouped topic grid   │ tabs
/leaderboard       weekly + daily podium and ranks                       │
/profile           identity hub, links to the screens below              ┘
/profile/edit      display name + avatar picker (PATCH /users/me)
/profile/achievements
/profile/stats     lifetime accuracy, speed, topic mastery
/premium           full-screen store (also shown as a mid-game sheet)
/settings          appearance, sound, haptics, account, sign out
/studio            quizzes you wrote + quizzes shared with you
/studio/new        write a quiz
/studio/quiz/:id   play it, challenge with it, its own leaderboard
/studio/code/:code redeem a share code (deep-link target)
/exams             past-year papers, by exam                          ┐
/exams/:slug       every published paper for one exam                 │ exam mode
/exams/paper/…     a full-length timed mock test                      │
/exams/attempt/…   score, percentile, chapter analysis, solutions     ┘
/quiz/*            setup → play → results
/share/results/:id public share card (reachable signed-out)
```

## Documentation

Each guide is self-contained:

| Guide | Covers |
|---|---|
| **[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)** | Architecture, running locally, environment reference, Google Sign-In setup, tests, client design system |
| **[docs/TESTING_PAYMENTS.md](docs/TESTING_PAYMENTS.md)** | Testing Premium end to end — test mode with no Play Console, then the real Play sandbox |
| **[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md)** | Railway + Neon + Upstash + Cloudflare Worker, scaling, load testing, troubleshooting, VPS alternative |
| **[docs/RELEASE.md](docs/RELEASE.md)** | Signing, App Links, IAP verification, Play Console, pre-submission checklist |
| **[tools/ingest/README.md](tools/ingest/README.md)** | Turning exam paper PDFs into playable mock tests — the pipeline, the answer-key cross-check, figures, and how to add an exam |
| **[docs/LANGUAGES.md](docs/LANGUAGES.md)** | The two language systems — app chrome (English/Hindi) and the per-run quiz language, and how to add a third |

## Quick start

### Prerequisites

- Docker Desktop
- Flutter 3.44+
- Python 3.12+ (optional for local non-Docker backend)

### Start infrastructure + API

```bash
cp .env.example .env
docker compose up --build
```

Production-style (no reload / no source mounts):

```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml up --build -d
```

Services:

| Service  | URL                    |
|----------|------------------------|
| API      | http://localhost:8000  |
| Docs     | http://localhost:8000/docs |
| Postgres | localhost:5432         |
| Redis    | localhost:6379         |

Health:

```bash
curl http://localhost:8000/health
curl http://localhost:8000/ready
```

### Run Flutter

```bash
cd mobile
flutter pub get
flutter run
```

Point the app at a backend:

- **Android emulator** — nothing to pass; falls back to `http://10.0.2.2:8000`
- **Physical device, same Wi-Fi** — `--dart-define=API_BASE_URL=http://<your-LAN-ip>:8000`
- **Physical device, any network** — deploy first, then pass the public URL

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#3-run-the-app) for the details.

### Android builds

Use the script — it supplies both `--dart-define`s, and getting either wrong
fails quietly rather than loudly (no `API_BASE_URL` means the app only works on
an emulator; the Railway URL instead of the Cloudflare Worker means it works on
Wi-Fi and dies on mobile data):

```bash
scripts/build_android.sh              # release APK for sideloading
scripts/build_android.sh appbundle    # AAB for Play Console
```

Override the target API with `API_BASE_URL=... scripts/build_android.sh`. The
Google client id is read from `.env`. The AAB path additionally needs
`mobile/android/key.properties` (see `key.properties.example`).

### Backend tests

```bash
cd backend
pip install -r requirements/dev.txt
pytest
```

## Phases

1. **Phase 1** — Monorepo, Docker, auth, models, API skeleton ✅
2. **Phase 2** — Topics, sessions, scoring, game modes ✅
3. **Phase 3** — Polished Flutter gameplay UI ✅
4. **Phase 4** — AI generation, custom topics, Teach Me ✅
5. **Bank scale** — Watermark top-ups toward ~1000 unique/topic ✅ (ongoing refill)
6. **Phase 5a** — XP/daily streaks + achievements unlock ✅
7. **Phase 5b** — Leaderboards + daily challenge ✅
8. **Phase 6a** — Adaptive difficulty + light analytics ✅
9. **Phase 6b** — Entitlements foundation + share + anti-cheat ✅
10. **Phase 7a** — Share deep links + paywall UX ✅
11. **Phase 7b** — IAP foundation (verify + buy path) ✅
12. **Phase 7c** — HTTPS share landing foundation ✅
13. **Phase 8a** — App Links / Universal Links foundation ✅
14. **Phase 8b** — Store verification adapters (Apple/Google) ✅
15. **Phase 8c** — Production app identity (`com.speedquiz.app`) ✅
16. **Phase 8d** — Android release readiness + deployment docs ✅
17. **Phase 9** — Design system + landing/sign-out + full UI pass ✅
18. **Phase 10** — Screen split, profile customisation, audio, random topic ✅
19. **Phase 11** — Production subscriptions: monthly/annual, store webhooks, grace + refund handling, premium cosmetics ✅
20. **Phase 12** — Game feel: living UI, mode cull + survival rework, setup layout ✅
21. **Phase 13** — Player-authored quizzes: studio, share codes, per-quiz boards ✅
22. **Next** — Play Console upload (keystore + AAB) → internal test → production

See [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) and [docs/RELEASE.md](docs/RELEASE.md).

## Game modes

Three modes, each with a distinct reason to replay. Every rule below is
server-authoritative; the client mirrors a few numbers for the HUD only.

| Mode | Shape | Rules module |
|---|---|---|
| **Casual** | Endless. Play for the streak. | shared scoring |
| **Speedrun** | The clock is the game — right answers buy time, mistakes burn it. | `app/services/speedrun.py` |
| **Survival** | Three lives, and it keeps getting faster. | `app/services/survival.py` |

**Survival** is built around four interlocking mechanics: the per-question
limit tightens with depth (so a run always ends), lives come back on a streak
that gets longer each time (comebacks that can't be farmed), the final life
pays a **1.5× last-stand multiplier** (the brink is the best place to be), and
every tenth correct answer pays a checkpoint bonus that grows with depth.

**Negative** and **Sudden Death** were retired — negative was casual with the
sign flipped, and sudden death ended most runs on question three. Their enum
labels remain in the database because `quiz_sessions.mode` and `scores.mode`
reference them on historical rows; they are simply no longer selectable.

## Player-authored quizzes

Players write their own questions, then play them solo or put them in front of
a friend. Reachable from Home → **Make your own quiz**.

### How it is built

A custom quiz owns **one hidden `topics` row** and writes ordinary `questions`
under it. That single decision is why the feature is mostly bookkeeping rather
than a second game engine: sessions, all three game modes, multiplayer boards,
scoring, anti-cheat, results and sharing already speak `topic_id`, so none of
them needed to learn what a custom quiz is.

Two things they *do* need to know, and both travel as flags rather than as a
branch in every reader:

| Flag | Means |
|---|---|
| `topics.is_user_generated` | a **finite deck** — dealt once, run ends at the bottom, no AI top-up, no global ladder |
| `quiz_sessions.config.finite_deck` | the same fact, stamped on the run so the dealer needs no join |

Draft-ness is a question's own `QuestionStatus`: PENDING while the quiz is a
draft (the dealer only ever selects ACTIVE), ACTIVE once published. One copy of
the text, so an authoring table and a published table can never drift.

Solo runs deal the deck **in the order the author arranged it** — options are
still shuffled per run, so nothing is memorizable by screen position. A
challenge draws a shared random subset instead, which is what makes a rematch
worth playing.

### Sharing and access

| Visibility | Who can open it |
|---|---|
| `private` | the author |
| `friends` | the author and their accepted friends |
| `link` | anyone holding the six-character share code |

Redeeming a code writes a `custom_quiz_access` row, so the code is needed
**exactly once** — and that table doubles as "quizzes shared with me". Being
invited to a match on a quiz grants the same access, so an opponent who
answered its questions can replay it and see its board.

Codes use the room-code alphabet (no vowels, no `0/O` or `1/I`). They travel as
`speedquiz://quiz/{CODE}` and as `https://<host>/q/{CODE}`, which renders a
public landing page for anyone who does not have the app yet — title, author
and size only, never the questions.

### Why a custom run is not worth what a real run is worth

The author knows the answers, so:

- never recorded on the weekly or daily leaderboard,
- never moves Elo, the adaptive skill rating, or topic mastery,
- pays XP normally on **someone else's** quiz; on your own, once per cooldown
  window (`CUSTOM_QUIZ_OWN_XP_COOLDOWN_HOURS`).

Each quiz gets **its own leaderboard** instead — every player's best run, ranked
in the database by a window function over `ix_scores_topic_score`. That is the
part players actually want, and it is the reason a quiz gets played twice.

### Limits and moderation

| Setting | Default | Meaning |
|---|---|---|
| `CUSTOM_QUIZ_FREE_LIMIT` | 3 | published quizzes a free account may hold |
| `CUSTOM_QUIZ_FREE_MAX_QUESTIONS` | 20 | questions per quiz, free |
| `CUSTOM_QUIZ_MAX_QUESTIONS` | 50 | hard ceiling, everyone |
| `CUSTOM_QUIZ_MIN_QUESTIONS` | 3 | publish floor — also the match floor, so a published quiz is always challengeable |
| `CUSTOM_QUIZ_AI_DRAFT_DAILY_LIMIT_FREE` | 3 | AI drafting runs per UTC day, free |
| `CUSTOM_QUIZ_REPORT_HIDE_THRESHOLD` | 3 | distinct reporters that auto-hide a quiz |

**AI drafting** ("Draft with AI") fills the editor with starter questions the
author then edits — the blank page is where quiz creators lose people. Nothing
it produces is saved until the author says so. Quota is counted off
`generation_jobs`, not analytics events, because the analytics provider is
configurable and can legitimately be a no-op.

**Deleting** is only offered while nobody has played a quiz: the topic cascades
to every session and score posted on it, so a played quiz is *archived* instead.
Deleting a question that has already been dealt retires it rather than removing
the row, for the same reason.

Reports are unique per (quiz, player), so the auto-hide threshold counts
distinct people rather than distinct taps.

## Progression & engagement

- Calendar **daily streak** updates on quiz finish; Home 🔥 shows it
- Achievements evaluate on finish (`GET /api/v1/achievements`)
- XP level curve: need `level * 500` XP to advance
- **Daily challenge:** `GET/POST /api/v1/daily-challenge` (fixed questions, one clear/day)
- **Leaderboards:** `GET /api/v1/leaderboards?scope=weekly|daily` (Redis + Postgres)
- **Adaptive:** create session with `adaptive=true`; Elo-lite `skill_ratings` per topic
- **Analytics:** `analytics_events` table (`ANALYTICS_PROVIDER=postgres`)
- **Entitlements:** `GET /api/v1/entitlements/me` returns feature flags *and* live subscription state (plan, expiry, grace, manage URL); caps off by default
- **Auth:** landing screen with **Play as Guest** + **Continue with Google** (`POST /auth/google`); Profile links a guest to Google and offers **Sign out** — see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#5-google-sign-in)
- **Onboarding:** a first run picks a language and a name *before* signing in; the answers are held on the device and written to the profile (`display_name`, `app_language`, `quiz_language`, `onboarding_completed`) the moment a session exists, retrying on the next launch if that write fails
- **Subscriptions:** monthly + annual auto-renewing, verified against Play `subscriptionsv2` and the App Store Server API, with store webhooks driving renewals, cancellations and refunds — see [Subscriptions](#subscriptions)
- **Custom quizzes:** `GET/POST /api/v1/custom-quizzes`, `POST /{id}/publish`, `/{id}/start`, `/{id}/challenge`, `/{id}/leaderboard` — see [Player-authored quizzes](#player-authored-quizzes)
- **Share:** public `GET /api/v1/share/results/{id}`; landing `GET /r/{id}`; `speedquiz://` + optional `SHARE_PUBLIC_BASE_URL`
- **App Links:** `GET /.well-known/assetlinks.json` + `apple-app-site-association`; package `com.speedquiz.app`; set fingerprints + `APP_LINK_IOS_APP_ID` and point DNS at the API when ready


## Question bank (endless unique)

Gameplay never waits on an LLM. Questions are served from Postgres.

- Target unique bank size per topic: **1000** (then reshuffle-reuse is OK)
- When a topic falls below a **low watermark**, the worker generates the next **chunk** (~20) in the background
- Sessions prefer questions the player has not seen yet
- Free play is **unlimited** today (caps ready behind `ENTITLEMENTS_ENFORCE_QUESTION_CAPS`)

## Subscriptions

Premium is two auto-renewing plans, sold through Play and the App Store in
both India and the US.

| Plan | Product ID | Period |
|---|---|---|
| Monthly | `speedquiz_premium_monthly` | P1M |
| Annual (anchor) | `speedquiz_premium_annual` | P1Y |

Premium unlocks unlimited unique questions per topic, unlimited custom AI
topics, and cosmetics (six premium avatars, a gold profile ring, a leaderboard
badge). The retired one-time `speedquiz_premium` unlock is still honoured on
restore but is never sold again.

**Prices live in the store consoles, never in code.** The client renders the
localised `ProductDetails.price`, so ₹ and $ are both correct without the
backend knowing either number, and the paywall's "Save X%" is computed from
real store prices rather than a hardcoded claim.

### How entitlement is decided

The store is always the source of truth. `user.is_premium` is a cache over the
`subscriptions` table, refreshed on every write and lazily on read.

```text
client buys ──► POST /entitlements/purchases/verify ──► ask the store ──► subscriptions
store event ──► POST /billing/webhooks/{apple,google} ──► re-ask the store ──► subscriptions
```

Webhooks never trust their own payload for state — they use it to learn *which*
subscription changed, then re-fetch the authoritative record. A forged
notification can at worst trigger a redundant lookup.

Notifications get dropped (Pub/Sub outages, Apple giving up after its retries,
a deploy mid-flight), so the worker sweeps hourly for subscriptions whose paid
period and grace have both elapsed and demotes them. Without that backstop a
missed "expired" event would leave a lapsed subscriber on premium forever.

Entitled states are `active`, `grace` and `cancelled` (a cancelled subscription
runs to the end of the period already paid for). `on_hold`, `paused`,
`pending`, `expired` and `revoked` are not. Refunds revoke immediately.

### India and US specifics

- **UPI / net banking settle asynchronously.** A purchase can sit `pending` for
  minutes to days; the app says "waiting for your payment to clear" and the
  entitlement lands via the store notification.
- **Card e-mandates fail on renewal far more often in India.** Grace period and
  account hold are routine, so the app surfaces a "fix payment method" prompt
  deep-linking to the store rather than silently downgrading.
- **Apple and Google are the merchant of record** in both markets and remit GST
  / sales tax themselves.
- A guest who buys and later signs in keeps the subscription; a purchase
  already attached to a *signed-in* account will not transfer to another one.

### Security

- Apple notifications are verified by full `x5c` chain validation against a
  pinned Apple Root CA G3 — production refuses to boot without it.
- Play notifications require a shared secret and/or a verified Pub/Sub OIDC
  token; the endpoint fails closed in production if neither is configured.
- Notifications are deduplicated on the store's own event id in
  `billing_events`, which doubles as the audit trail for payment disputes.
- Sandbox purchases can never unlock premium in a production deployment.

Setup for both consoles — products, price ladders, RTDN and ASSN wiring — is in
[docs/RELEASE.md](docs/RELEASE.md).

### Free tier

- Soft-gate free users after **30 unique questions / topic**
- Free custom topics are capped per day (`CUSTOM_TOPIC_DAILY_LIMIT_FREE`)
- Both are wired but inert until `ENTITLEMENTS_ENFORCE_QUESTION_CAPS=true` —
  until you flip it, premium sells unlimited access to something already
  unlimited

## License

Proprietary — all rights reserved.
