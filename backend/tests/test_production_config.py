"""Guards on configuration that is unsafe to ship.

These exist because every failure they describe is silent: the app boots,
serves traffic, and looks healthy while being insecure.
"""

import pytest
from sqlalchemy.engine import make_url

from app.core.config import DEFAULT_JWT_SECRET, Settings
from app.core.database import _engine_kwargs, _engine_url

STRONG_SECRET = "a" * 64


def _settings(**overrides) -> Settings:
    base = {
        "app_env": "production",
        "debug": False,
        "jwt_secret": STRONG_SECRET,
        "entitlements_dev_toggle": False,
    }
    base.update(overrides)
    return Settings(**base)


class TestProductionGuards:
    def test_valid_production_config_boots(self):
        settings = _settings()
        assert settings.is_production

    def test_placeholder_jwt_secret_is_rejected(self):
        with pytest.raises(ValueError, match="placeholder"):
            _settings(jwt_secret=DEFAULT_JWT_SECRET)

    def test_short_jwt_secret_is_rejected(self):
        with pytest.raises(ValueError, match="at least"):
            _settings(jwt_secret="too-short")

    def test_dev_premium_toggle_is_rejected(self):
        # This endpoint would let any user grant themselves Premium.
        with pytest.raises(ValueError, match="ENTITLEMENTS_DEV_TOGGLE"):
            _settings(entitlements_dev_toggle=True)

    def test_debug_is_rejected(self):
        with pytest.raises(ValueError, match="DEBUG"):
            _settings(debug=True)

    def test_development_is_left_alone(self):
        # Dev keeps working with the shipped defaults and no ceremony.
        settings = Settings(app_env="development", jwt_secret=DEFAULT_JWT_SECRET)
        assert not settings.is_production

    def test_docs_are_hidden_in_production_by_default(self):
        assert _settings().docs_enabled is False
        assert _settings(enable_docs_in_production=True).docs_enabled is True
        assert Settings(app_env="development").docs_enabled is True


class TestConnectionPool:
    def test_pool_settings_come_from_env(self):
        settings = Settings(db_pool_size=3, db_max_overflow=7)
        kwargs = _engine_kwargs(settings)
        assert kwargs["pool_size"] == 3
        assert kwargs["max_overflow"] == 7
        assert kwargs["pool_pre_ping"] is True
        # Stale connections behind a proxy are the classic 3am outage.
        assert kwargs["pool_recycle"] == settings.db_pool_recycle_seconds

    def test_defaults_stay_within_a_100_connection_server(self):
        settings = Settings()
        per_process = settings.db_pool_size + settings.db_max_overflow
        # 2 workers x 3 replicas plus the worker service must still fit.
        assert per_process * 2 * 3 < 100

    def test_prepared_statements_left_on_by_default(self):
        settings = Settings()
        assert "connect_args" not in _engine_kwargs(settings)
        assert "prepared_statement_cache_size" not in str(_engine_url(settings))

    def test_pooler_mode_disables_both_statement_caches(self):
        # Transaction-mode poolers multiplex connections between
        # transactions, so server-side prepared statements break under load.
        settings = Settings(db_disable_prepared_statements=True)
        assert _engine_kwargs(settings)["connect_args"] == {"statement_cache_size": 0}
        url = _engine_url(settings)
        assert url.query["prepared_statement_cache_size"] == "0"

    def test_pooler_mode_is_a_noop_for_non_asyncpg_urls(self):
        settings = Settings(
            db_disable_prepared_statements=True,
            database_url="postgresql+psycopg://u:p@localhost:5432/db",
        )
        assert "prepared_statement_cache_size" not in str(_engine_url(settings))


class TestCorsPolicy:
    def test_wildcard_and_credentials_are_mutually_exclusive(self):
        # Browsers reject `Access-Control-Allow-Origin: *` on credentialed
        # requests; main.py derives allow_credentials from this list.
        assert Settings(cors_origins="*").cors_origin_list == ["*"]

    def test_explicit_origins_are_split(self):
        origins = Settings(
            cors_origins="https://a.example, https://b.example"
        ).cors_origin_list
        assert origins == ["https://a.example", "https://b.example"]


def test_engine_url_preserves_credentials_and_database():
    settings = Settings(
        db_disable_prepared_statements=True,
        database_url="postgresql+asyncpg://user:secret@db.host:5432/speedquiz",
    )
    url = _engine_url(settings)
    original = make_url(settings.database_url)
    assert url.username == original.username
    assert url.password == original.password
    assert url.host == original.host
    assert url.database == original.database
