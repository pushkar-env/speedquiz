/**
 * SpeedQuiz load test — realistic gameplay journey.
 *
 * Models what a player actually does rather than hammering one endpoint:
 * guest sign-in, fetch topics, create a session, answer N questions with
 * human-like think time, then finish and read the result.
 *
 * Install k6: https://k6.io/docs/get-started/installation/
 *
 * Smoke (5 users, 30s):
 *   k6 run -e BASE_URL=https://your-api.up.railway.app scripts/loadtest.js
 *
 * Target 1,000 concurrent players:
 *   k6 run -e BASE_URL=https://your-api.up.railway.app -e PROFILE=peak scripts/loadtest.js
 *
 * Find the breaking point:
 *   k6 run -e BASE_URL=... -e PROFILE=breakpoint scripts/loadtest.js
 *
 * Notes
 * - Every VU creates a guest account, so this writes real rows. Point it at
 *   a staging database, or be ready to clean up.
 * - The server rate-limits answers per user; THINK_TIME_MS below stays above
 *   that threshold on purpose. Lowering it measures your 429 handling, not
 *   your throughput.
 */

import http from 'k6/http';
import { check, sleep, fail } from 'k6';
import { Trend, Rate, Counter } from 'k6/metrics';
import { randomIntBetween } from 'https://jslib.k6.io/k6-utils/1.4.0/index.js';

const BASE_URL = (__ENV.BASE_URL || 'http://localhost:8000').replace(/\/$/, '');
const API = `${BASE_URL}/api/v1`;
const PROFILE = __ENV.PROFILE || 'smoke';

/** Questions answered per session before finishing. */
const QUESTIONS_PER_RUN = Number(__ENV.QUESTIONS_PER_RUN || 10);
/** Seconds a player spends reading a question and its feedback. */
const THINK_TIME_MIN = Number(__ENV.THINK_TIME_MIN || 4);
const THINK_TIME_MAX = Number(__ENV.THINK_TIME_MAX || 9);

// --- Custom metrics -------------------------------------------------------

const answerLatency = new Trend('sq_answer_latency', true);
const sessionCreateLatency = new Trend('sq_session_create_latency', true);
const guestAuthLatency = new Trend('sq_guest_auth_latency', true);
const journeyFailures = new Rate('sq_journey_failed');
const rateLimited = new Counter('sq_rate_limited');
const runsCompleted = new Counter('sq_runs_completed');

// --- Load profiles --------------------------------------------------------
//
// A quiz player answers roughly every 6-13s, so ~1,000 concurrent VUs here
// generates ~100-150 req/s — which is what 1,000 real concurrent users looks
// like. Do not read VUs as RPS.

const PROFILES = {
  smoke: {
    stages: [
      { duration: '30s', target: 5 },
      { duration: '30s', target: 5 },
      { duration: '10s', target: 0 },
    ],
  },
  load: {
    stages: [
      { duration: '1m', target: 100 },
      { duration: '3m', target: 300 },
      { duration: '2m', target: 300 },
      { duration: '1m', target: 0 },
    ],
  },
  peak: {
    stages: [
      { duration: '2m', target: 250 },
      { duration: '3m', target: 1000 },
      { duration: '5m', target: 1000 },
      { duration: '2m', target: 0 },
    ],
  },
  breakpoint: {
    stages: [
      { duration: '2m', target: 500 },
      { duration: '2m', target: 1000 },
      { duration: '2m', target: 2000 },
      { duration: '2m', target: 4000 },
      { duration: '1m', target: 0 },
    ],
  },
};

if (!PROFILES[PROFILE]) {
  fail(`Unknown PROFILE "${PROFILE}". Use: ${Object.keys(PROFILES).join(', ')}`);
}

export const options = {
  stages: PROFILES[PROFILE].stages,
  thresholds: {
    // Answering must feel instant — it is the only latency players notice.
    sq_answer_latency: ['p(95)<400', 'p(99)<1000'],
    sq_session_create_latency: ['p(95)<1500'],
    sq_guest_auth_latency: ['p(95)<1500'],
    sq_journey_failed: ['rate<0.01'],
    http_req_failed: ['rate<0.01'],
  },
  // breakpoint runs are meant to fail; don't abort on thresholds there.
  thresholdsAbortOnFail: PROFILE !== 'breakpoint',
  discardResponseBodies: false,
};

// --- Helpers --------------------------------------------------------------

function authHeaders(token) {
  return {
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${token}`,
    },
  };
}

function jsonPost(url, body, params) {
  return http.post(url, JSON.stringify(body), params);
}

/** Cached across iterations so we don't refetch the catalog every run. */
let cachedTopics = null;

function playableTopics(token) {
  if (cachedTopics) return cachedTopics;

  const res = http.get(`${API}/topics?limit=100`, authHeaders(token));
  if (res.status !== 200) return [];

  const items = (res.json('items') || []).filter((t) => t.question_count > 0);
  cachedTopics = items;
  return items;
}

// --- Setup ----------------------------------------------------------------

export function setup() {
  const health = http.get(`${BASE_URL}/health`);
  if (health.status !== 200) {
    fail(`API not reachable at ${BASE_URL}/health (status ${health.status})`);
  }

  const ready = http.get(`${BASE_URL}/ready`);
  if (ready.status !== 200) {
    fail(
      `API is not ready (status ${ready.status}): ${ready.body}. ` +
        'Check the database and Redis before load testing.',
    );
  }

  console.log(`Target: ${BASE_URL}  profile: ${PROFILE}`);
  return { baseUrl: BASE_URL };
}

// --- The journey ----------------------------------------------------------

export default function () {
  let ok = true;

  // 1. Guest sign-in.
  const auth = jsonPost(
    `${API}/auth/guest`,
    { device_info: `k6-${__VU}` },
    { headers: { 'Content-Type': 'application/json' } },
  );
  guestAuthLatency.add(auth.timings.duration);

  if (!check(auth, { 'guest auth 201': (r) => r.status === 201 })) {
    journeyFailures.add(1);
    sleep(1);
    return;
  }
  const token = auth.json('access_token');

  // 2. Pick a topic that actually has questions banked.
  const topics = playableTopics(token);
  if (topics.length === 0) {
    console.warn('No playable topics — is the question bank seeded?');
    journeyFailures.add(1);
    sleep(1);
    return;
  }
  const topic = topics[randomIntBetween(0, topics.length - 1)];

  // 3. Create the session.
  const created = jsonPost(
    `${API}/quiz/sessions`,
    { topic_id: topic.id, mode: 'casual', difficulty: 'medium' },
    authHeaders(token),
  );
  sessionCreateLatency.add(created.timings.duration);

  if (!check(created, { 'session created 201': (r) => r.status === 201 })) {
    journeyFailures.add(1);
    sleep(1);
    return;
  }

  const sessionId = created.json('id');
  let question = created.json('current_question');

  // 4. Play the run.
  for (let i = 0; i < QUESTIONS_PER_RUN && question; i++) {
    // Reading the question and the options.
    sleep(randomIntBetween(THINK_TIME_MIN, THINK_TIME_MAX));

    const answer = jsonPost(
      `${API}/quiz/sessions/${sessionId}/answer`,
      {
        quiz_question_id: question.quiz_question_id,
        selected_option_index: randomIntBetween(0, 3),
        client_elapsed_ms: randomIntBetween(1500, 9000),
        timed_out: false,
      },
      authHeaders(token),
    );
    answerLatency.add(answer.timings.duration);

    if (answer.status === 429) {
      // Anti-cheat rate limit. Expected only if think time is tuned down.
      rateLimited.add(1);
      break;
    }
    if (!check(answer, { 'answer accepted': (r) => r.status === 200 })) {
      ok = false;
      break;
    }

    if (answer.json('run_ended')) break;
    question = answer.json('next_question');
  }

  // 5. Finish and read the result, like the results screen does.
  const finished = jsonPost(
    `${API}/quiz/sessions/${sessionId}/finish`,
    {},
    authHeaders(token),
  );
  if (!check(finished, { 'run finished 200': (r) => r.status === 200 })) {
    ok = false;
  } else {
    runsCompleted.add(1);
  }

  // 6. Leaderboard check, which players do after a run.
  const board = http.get(`${API}/leaderboards?scope=weekly`, authHeaders(token));
  check(board, { 'leaderboard 200': (r) => r.status === 200 });

  journeyFailures.add(ok ? 0 : 1);
  sleep(randomIntBetween(2, 5));
}

export function teardown(data) {
  console.log(`Finished load test against ${data.baseUrl}`);
}
