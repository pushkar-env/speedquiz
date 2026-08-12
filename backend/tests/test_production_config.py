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


APPLE_CREDS = {
    "billing_verify_mode": "apple_google",
    "apple_iap_issuer_id": "issuer",
    "apple_iap_key_id": "key",
    "apple_iap_private_key": "-----BEGIN PRIVATE KEY-----\nX\n-----END PRIVATE KEY-----",
    "apple_root_ca_path": "certs/DOES_NOT_EXIST.cer",
    "apple_root_ca_pem": "",
}

FAKE_ROOT_PEM = "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----"


class TestBillingGuards:
    def test_apple_iap_without_a_pinned_root_ca_is_rejected(self):
        # App Store notifications arrive on a public endpoint and are
        # authenticated only by their signature. With no pinned root there is
        # no way to tell a real subscription event from a forged one.
        with pytest.raises(ValueError, match="Apple Root CA"):
            _settings(**APPLE_CREDS)

    def test_apple_iap_boots_once_the_root_is_supplied(self):
        settings = _settings(**{**APPLE_CREDS, "apple_root_ca_pem": FAKE_ROOT_PEM})
        assert settings.store_verification_enabled
        assert settings.apple_root_ca_material

    def test_the_guard_does_not_block_an_android_only_deployment(self):
        # Shipping Android first is normal; the guard must be scoped to
        # whether Apple IAP is actually configured.
        settings = _settings(
            billing_verify_mode="apple_google",
            google_play_service_account_json='{"client_email":"a@b.c"}',
            apple_root_ca_path="certs/DOES_NOT_EXIST.cer",
        )
        assert settings.apple_iap_configured is False
        assert settings.google_play_configured is True

    def test_stub_mode_does_not_require_store_credentials(self):
        settings = _settings()
        assert settings.store_verification_enabled is False


class TestStubPurchaseGate:
    """Controls whether the paywall may offer a simulated purchase.

    It must track exactly what `purchases/verify` would accept — offering a
    test purchase the server then refuses is a dead end, and offering one on a
    real deployment would be free premium.
    """

    def test_development_allows_a_simulated_purchase(self):
        assert Settings(app_env="development").stub_purchase_allowed is True

    def test_production_refuses_by_default(self):
        assert _settings().stub_purchase_allowed is False

    def test_production_allows_it_only_when_explicitly_enabled(self):
        settings = _settings(billing_allow_stub_in_production=True)
        assert settings.stub_purchase_allowed is True

    def test_real_store_verification_always_wins(self):
        # Once the store adapters are on, a simulated purchase must never be
        # offered — even on a dev box, since verify would reject it anyway.
        for env in ("development", "production"):
            settings = Settings(
                app_env=env,
                debug=False,
                jwt_secret=STRONG_SECRET,
                billing_verify_mode="apple_google",
                billing_allow_stub_in_production=True,
            )
            assert settings.stub_purchase_allowed is False, env


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
