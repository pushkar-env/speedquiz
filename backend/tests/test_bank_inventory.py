"""Tests for bank inventory helpers (no DB)."""

from app.core.config import get_settings
from app.payments.entitlements import unique_question_allowance


def test_bank_targets_are_sensible():
    settings = get_settings()
    assert settings.topic_bank_target_unique >= 100
    assert settings.topic_bank_chunk_size >= 5
    assert settings.topic_bank_low_watermark < settings.topic_bank_target_unique


def test_free_allowance_unlimited_by_default():
    assert get_settings().entitlements_enforce_question_caps is False
    assert unique_question_allowance(None) is None
