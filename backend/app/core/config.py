from functools import lru_cache
from pathlib import Path

from pydantic import Field, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

# Shipped placeholder. Booting production with this would let anyone forge
# tokens, so it is rejected explicitly below.
DEFAULT_JWT_SECRET = "change-me-to-a-long-random-secret-in-production"
MIN_PRODUCTION_JWT_SECRET_LENGTH = 32


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    app_name: str = "SpeedQuiz"
    app_env: str = "development"
    debug: bool = True
    api_prefix: str = "/api/v1"
    cors_origins: str = "*"

    database_url: str = (
        "postgresql+asyncpg://speedquiz:speedquiz_dev_password@localhost:5432/speedquiz"
    )
    database_url_sync: str = (
        "postgresql+psycopg://speedquiz:speedquiz_dev_password@localhost:5432/speedquiz"
    )
    redis_url: str = "redis://localhost:6379/0"

    # --- Database connection pool (per process) ---
    # Real connection use is roughly (concurrent requests x average DB time),
    # which for this workload is single digits — async handlers only hold a
    # connection while a query is in flight. Keep these small: total server
    # connections are (pool_size + max_overflow) x uvicorn workers x replicas,
    # and Postgres defaults to max_connections=100.
    db_pool_size: int = 5
    db_max_overflow: int = 10
    db_pool_timeout_seconds: int = 30
    # Recycle below any proxy/pooler idle timeout so we never hand out a
    # connection the server has already dropped.
    db_pool_recycle_seconds: int = 1800
    # Required behind a transaction-mode pooler (PgBouncer, Supavisor, the
    # Neon `-pooler` endpoint): connections are multiplexed between
    # transactions, so server-side prepared statements are not safe.
    db_disable_prepared_statements: bool = False

    # --- Redis client ---
    # Redis sits in the answer-submission path (rate limiting), so a hung
    # socket must fail fast rather than stall request handlers.
    redis_socket_timeout_seconds: float = 3.0
    redis_connect_timeout_seconds: float = 3.0
    redis_max_connections: int = 50

    # Serve /docs, /redoc and /openapi.json. Off in production unless opted in.
    enable_docs_in_production: bool = False

    jwt_secret: str = DEFAULT_JWT_SECRET
    jwt_algorithm: str = "HS256"
    jwt_access_token_expire_minutes: int = 60
    jwt_refresh_token_expire_days: int = 30

    llm_provider: str = "openai"
    llm_api_key: str = ""
    llm_model_generate: str = "gpt-4o-mini"
    llm_model_validate: str = "gpt-4o-mini"
    llm_model_classify: str = "gpt-4o-mini"

    google_client_id: str = ""
    apple_client_id: str = ""

    sentry_dsn: str = ""
    log_level: str = "INFO"

    score_base_points: int = 100
    score_speed_bonus_max: int = 50
    streak_multiplier_tiers: str = "0:1.0,5:1.1,10:1.25,20:1.5"

    custom_topic_daily_limit_free: int = 3
    question_quality_threshold: int = 70
    generation_batch_size: int = 10

    # Question bank growth (gameplay never waits on LLM)
    topic_bank_target_unique: int = 1000
    topic_bank_low_watermark: int = 40
    topic_bank_chunk_size: int = 20
    topic_bank_session_batch: int = 20

    # Monetization — keep free unlimited until explicitly enabled
    entitlements_enforce_question_caps: bool = False
    free_unique_questions_per_topic: int = 30
    entitlements_dev_toggle: bool = False

    # --- Subscription products (create these ids in both consoles) ---
    # Auto-renewing. On Apple both must live in ONE subscription group so a
    # plan switch is an upgrade/downgrade, not a second active subscription.
    iap_product_monthly: str = "speedquiz_premium_monthly"
    iap_product_annual: str = "speedquiz_premium_annual"
    # Retired non-consumable. Still honoured on verify/restore so anyone who
    # bought it before the subscription launch keeps premium; never sold again.
    iap_premium_product_id: str = "speedquiz_premium"

    iap_android_package: str = "com.speedquiz.app"
    billing_verify_mode: str = "stub"  # stub | apple_google
    billing_allow_stub_in_production: bool = False

    # How long past expiry we keep serving premium when the store says the
    # subscription is in billing retry but has not yet granted a grace period.
    # India's card e-mandates fail on renewal far more often than US cards, and
    # yanking premium mid-quiz over a retryable decline is a refund request
    # waiting to happen.
    billing_grace_period_days: int = 3
    # Re-verify an active subscription against the store if the cached state is
    # older than this. Webhooks are the primary path; this is the safety net
    # for dropped notifications.
    billing_resync_stale_hours: int = 24

    # Google Play Developer API (empty JSON = not configured → 503 in apple_google)
    google_play_service_account_json: str = ""
    # Real-time developer notifications (Pub/Sub push). Authenticate with a
    # shared secret in the push URL, an OIDC service-account token, or both.
    google_rtdn_shared_secret: str = ""
    google_rtdn_oidc_audience: str = ""
    google_rtdn_oidc_service_account: str = ""

    # Apple App Store Server API (empty key fields = not configured → 503)
    apple_iap_issuer_id: str = ""
    apple_iap_key_id: str = ""
    apple_iap_private_key: str = ""  # PEM body; use \n for newlines in .env
    apple_iap_bundle_id: str = "com.speedquiz.app"
    apple_iap_environment: str = "Sandbox"  # Sandbox | Production
    # App Store Server Notifications V2 arrive on a public endpoint, so the
    # JWS x5c chain must be verified against Apple's root. Supply the root as
    # a PEM/base64-DER blob or a file path:
    #   curl -o backend/certs/AppleRootCA-G3.cer \
    #     https://www.apple.com/certificateauthority/AppleRootCA-G3.cer
    apple_root_ca_pem: str = ""
    apple_root_ca_path: str = "certs/AppleRootCA-G3.cer"

    # --- Usernames --------------------------------------------------------
    # Extra blocked substrings, comma separated, matched against the folded
    # skeleton. Deployment-specific additions go here rather than in code.
    username_blocked_terms: str = ""

    # --- Multiplayer ------------------------------------------------------
    multiplayer_enabled: bool = True
    match_default_question_count: int = 7
    match_min_question_count: int = 3
    match_max_question_count: int = 20
    match_question_time_limit_ms: int = 15000
    #: Pause between rounds, so the verdict is readable before the next prompt.
    match_round_reveal_ms: int = 3000
    match_max_players: int = 8
    #: How long a live lobby waits for everyone before the host can start
    #: anyway. Also how long an unanswered ranked pairing survives.
    match_lobby_timeout_seconds: int = 120
    #: A challenged friend who never connects turns the match async after this,
    #: rather than leaving the challenger staring at a spinner.
    match_live_join_grace_seconds: int = 45
    #: How long an async challenge waits for its opponent before expiring.
    match_async_expiry_hours: int = 48
    #: Slack added to the round deadline before an answer is refused, covering
    #: the round trip on a slow mobile connection. Mirrors the single-player
    #: grace in quiz_service.
    match_answer_grace_ms: int = 2500

    # --- Realtime channel -------------------------------------------------
    #: Events retained per match. A client resuming after a drop replays from
    #: its last id; anything older than this is recovered by refetching state.
    realtime_stream_maxlen: int = 500
    realtime_stream_ttl_seconds: int = 7200
    #: Single-use ticket exchanged for a WebSocket. Short because it travels in
    #: a query string, which proxies and access logs routinely record.
    realtime_ticket_ttl_seconds: int = 60
    realtime_heartbeat_seconds: int = 20
    #: Connections one player may hold at once, across devices.
    realtime_max_connections_per_user: int = 3

    # --- Ranked ladder ----------------------------------------------------
    ranked_starting_rating: int = 1000
    ranked_k_factor: int = 24
    #: Placement matches move rating faster so a new player reaches their real
    #: bracket in five games rather than fifty.
    ranked_placement_k_factor: int = 48
    ranked_placement_matches: int = 5
    #: Carry-over into a new season: pull toward the mean, keep the ordering.
    ranked_season_carryover: float = 0.6
    matchmaking_initial_band: int = 100
    matchmaking_band_growth_per_second: int = 25
    matchmaking_max_band: int = 800
    #: After this, the queue offers a bot-free fallback: play solo on the same
    #: question set and bank the result as an async challenge.
    matchmaking_timeout_seconds: int = 60

    # --- Push notifications (FCM HTTP v1) ---------------------------------
    # Empty service account = push disabled; the notification service falls
    # back to the in-app inbox alone and logs nothing as an error.
    fcm_service_account_json: str = ""
    #: Overrides the project id inside the service account when they differ.
    fcm_project_id: str = ""
    push_enabled: bool = True
    #: Local-time window where only the player's own turn may interrupt them.
    #: Applied per device using the UTC offset the client reports, because a
    #: server-side "22:00" is the wrong 22:00 for most of the world.
    push_quiet_hours_enabled: bool = True
    push_quiet_hours_start: int = 22
    push_quiet_hours_end: int = 8

    # Public share landing (empty = omit web_url from share text)
    share_public_base_url: str = ""

    # HTTPS App Links / Universal Links association (empty = 503 on well-known)
    app_link_android_package: str = "com.speedquiz.app"
    app_link_android_sha256_cert_fingerprints: str = ""
    app_link_ios_app_id: str = ""  # TEAMID.com.speedquiz.app

    # Analytics: postgres | null
    analytics_provider: str = "postgres"

    @property
    def cors_origin_list(self) -> list[str]:
        if self.cors_origins.strip() == "*":
            return ["*"]
        return [o.strip() for o in self.cors_origins.split(",") if o.strip()]

    @property
    def is_production(self) -> bool:
        return self.app_env.lower() == "production"

    @property
    def apple_iap_configured(self) -> bool:
        return bool(
            self.apple_iap_issuer_id.strip()
            and self.apple_iap_key_id.strip()
            and self.apple_iap_private_key.strip()
        )

    @property
    def google_play_configured(self) -> bool:
        return bool(self.google_play_service_account_json.strip())

    @property
    def fcm_configured(self) -> bool:
        return bool(self.fcm_service_account_json.strip())

    @property
    def push_delivery_enabled(self) -> bool:
        """Can a notification actually leave the server?

        False is a supported state, not a misconfiguration: the in-app inbox
        works without FCM, so a deployment with no Firebase project still has a
        functioning multiplayer feature — just a quieter one.
        """
        return self.push_enabled and self.fcm_configured

    @property
    def store_verification_enabled(self) -> bool:
        return self.billing_verify_mode.strip().lower() in {"apple_google", "store"}

    @property
    def stub_purchase_allowed(self) -> bool:
        """Can a client complete a purchase without a real store transaction?

        True only where stub verification would actually succeed, so the
        paywall can offer a simulated purchase on a test deployment that has no
        store products yet. This grants nothing the `purchases/verify` endpoint
        would not already accept — it just stops the UI pretending buying is
        impossible when the server is perfectly willing.
        """
        if self.store_verification_enabled:
            return False
        return (not self.is_production) or self.billing_allow_stub_in_production

    @property
    def apple_root_ca_material(self) -> str:
        """Apple Root CA G3 as PEM/base64-DER text, or "" when unavailable.

        Inline config wins over the file so a container can inject it as a
        secret without a mounted volume.
        """
        inline = self.apple_root_ca_pem.strip()
        if inline:
            return inline

        path = self.apple_root_ca_path.strip()
        if not path:
            return ""
        candidate = Path(path)
        if not candidate.is_absolute():
            # Resolve relative to the backend/ package root so the default
            # works the same from a container WORKDIR and a local `pytest`.
            candidate = Path(__file__).resolve().parents[2] / path
        try:
            return candidate.read_text(encoding="utf-8", errors="ignore")
        except (OSError, ValueError):
            return ""

    @property
    def docs_enabled(self) -> bool:
        return (not self.is_production) or self.enable_docs_in_production

    @model_validator(mode="after")
    def _reject_unsafe_production_config(self) -> "Settings":
        """Refuse to boot production with settings that are actively unsafe.

        Failing at startup is deliberately louder than shipping a deployment
        that looks healthy while handing out forgeable tokens or free premium.
        """
        if not self.is_production:
            return self

        problems: list[str] = []

        if self.jwt_secret == DEFAULT_JWT_SECRET:
            problems.append(
                "JWT_SECRET is still the shipped placeholder - anyone could "
                "forge tokens. Generate one with: openssl rand -hex 32"
            )
        elif len(self.jwt_secret) < MIN_PRODUCTION_JWT_SECRET_LENGTH:
            problems.append(
                f"JWT_SECRET must be at least "
                f"{MIN_PRODUCTION_JWT_SECRET_LENGTH} characters in production"
            )

        if self.entitlements_dev_toggle:
            problems.append(
                "ENTITLEMENTS_DEV_TOGGLE=true exposes POST "
                "/entitlements/dev/premium, which would let any user grant "
                "themselves Premium. Set it to false. To exercise the paywall "
                "on a test deployment, set BILLING_ALLOW_STUB_IN_PRODUCTION="
                "true instead — that routes through real purchase "
                "verification rather than an endpoint that hands out Premium."
            )

        if self.debug:
            problems.append("DEBUG must be false when APP_ENV=production")

        if (
            self.store_verification_enabled
            and self.apple_iap_configured
            and not self.apple_root_ca_material
        ):
            problems.append(
                "Apple IAP is configured but the Apple Root CA G3 is missing, "
                "so App Store notifications could not be authenticated and "
                "anyone could POST a forged subscription event. Fetch it with: "
                "curl -o backend/certs/AppleRootCA-G3.cer "
                "https://www.apple.com/certificateauthority/AppleRootCA-G3.cer "
                "(or set APPLE_ROOT_CA_PEM)"
            )

        if problems:
            raise ValueError(
                "Unsafe production configuration:\n  - " + "\n  - ".join(problems)
            )
        return self


@lru_cache
def get_settings() -> Settings:
    return Settings()
