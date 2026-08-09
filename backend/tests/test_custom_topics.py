"""Custom topic helpers (quota / cache key)."""

from app.models import DifficultyLabel
from app.services.custom_topics import cache_key_for


def test_cache_key_stable_and_case_insensitive():
    a = cache_key_for("Elden Ring lore", DifficultyLabel.MEDIUM, None)
    b = cache_key_for("elden ring lore", DifficultyLabel.MEDIUM, "  ")
    c = cache_key_for("elden ring lore", DifficultyLabel.HARD, None)
    assert a == b
    assert a != c


def test_cache_key_includes_style():
    a = cache_key_for("Space", DifficultyLabel.MEDIUM, "trivia")
    b = cache_key_for("Space", DifficultyLabel.MEDIUM, "lore")
    assert a != b
