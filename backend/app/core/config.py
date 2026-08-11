from functools import lru_cache

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

    # Monetization roadmap — keep free unlimited until explicitly enabled
    entitlements_enforce_question_caps: bool = False
    free_unique_questions_per_topic: int = 30
    entitlements_dev_toggle: bool = False

    # IAP — stub verify by default; apple_google uses store adapters
    iap_premium_product_id: str = "speedquiz_premium"
    iap_android_package: str = "com.speedquiz.app"
    billing_verify_mode: str = "stub"  # stub | apple_google
    billing_allow_stub_in_production: bool = False

    # Google Play Developer API (empty JSON = not configured → 503 in apple_google)
    google_play_service_account_json: str = ""

    # Apple App Store Server API (empty key fields = not configured → 503)
    apple_iap_issuer_id: str = ""
    apple_iap_key_id: str = ""
    apple_iap_private_key: str = ""  # PEM body; use \n for newlines in .env
    apple_iap_bundle_id: str = "com.speedquiz.app"
    apple_iap_environment: str = "Sandbox"  # Sandbox | Production

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
                "themselves Premium. Set it to false."
            )

        if self.debug:
            problems.append("DEBUG must be false when APP_ENV=production")

        if problems:
            raise ValueError(
                "Unsafe production configuration:\n  - " + "\n  - ".join(problems)
            )
        return self


@lru_cache
def get_settings() -> Settings:
    return Settings()
