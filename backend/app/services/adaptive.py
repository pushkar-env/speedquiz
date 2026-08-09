"""Adaptive difficulty — Elo-lite skill ratings (no LLM)."""

from __future__ import annotations

from typing import Any, Optional

from app.models import DifficultyLabel

DEFAULT_RATING = 1000.0
MIN_RATING = 600.0
MAX_RATING = 1800.0
K_FACTOR = 32.0

LABEL_ORDER: list[DifficultyLabel] = [
    DifficultyLabel.EASY,
    DifficultyLabel.MEDIUM,
    DifficultyLabel.HARD,
    DifficultyLabel.EXPERT,
]


def rating_to_label(rating: float) -> DifficultyLabel:
    if rating < 850:
        return DifficultyLabel.EASY
    if rating < 1100:
        return DifficultyLabel.MEDIUM
    if rating < 1350:
        return DifficultyLabel.HARD
    return DifficultyLabel.EXPERT


def label_to_expected_score(label: DifficultyLabel) -> float:
    """Expected accuracy (0-1) if playing at this label band."""
    return {
        DifficultyLabel.EASY: 0.75,
        DifficultyLabel.MEDIUM: 0.55,
        DifficultyLabel.HARD: 0.40,
        DifficultyLabel.EXPERT: 0.28,
    }.get(label, 0.55)


def suggested_label_from_ratings(
    skill_ratings: dict[str, Any] | None,
    topic_id: str,
) -> DifficultyLabel:
    entry = (skill_ratings or {}).get(str(topic_id)) or {}
    if isinstance(entry, dict):
        suggested = entry.get("suggested")
        if suggested in {d.value for d in DifficultyLabel}:
            return DifficultyLabel(suggested)
        rating = float(entry.get("rating", DEFAULT_RATING))
        return rating_to_label(rating)
    return DifficultyLabel.MEDIUM


def update_topic_rating(
    skill_ratings: dict[str, Any] | None,
    *,
    topic_id: str,
    accuracy_percent: float,
    session_label: DifficultyLabel,
) -> dict[str, Any]:
    """
    Elo-lite update from a finished run.
    Actual score = accuracy/100; expected from the band they played.
    """
    ratings = dict(skill_ratings or {})
    key = str(topic_id)
    prev = ratings.get(key) if isinstance(ratings.get(key), dict) else {}
    rating = float(prev.get("rating", DEFAULT_RATING))
    games = int(prev.get("games", 0))

    actual = max(0.0, min(1.0, accuracy_percent / 100.0))
    expected = label_to_expected_score(session_label)
    new_rating = rating + K_FACTOR * (actual - expected)
    new_rating = max(MIN_RATING, min(MAX_RATING, new_rating))
    label = rating_to_label(new_rating)

    ratings[key] = {
        "rating": round(new_rating, 1),
        "games": games + 1,
        "suggested": label.value,
    }
    return ratings


def nudge_label(
    current: DifficultyLabel,
    *,
    recent_correct: int,
    recent_total: int,
) -> DifficultyLabel:
    """Mid-run nudge from last answers. ≥80% harder, ≤40% easier."""
    if recent_total <= 0:
        return current
    ratio = recent_correct / recent_total
    idx = LABEL_ORDER.index(current) if current in LABEL_ORDER else 1
    if ratio >= 0.80 and idx < len(LABEL_ORDER) - 1:
        return LABEL_ORDER[idx + 1]
    if ratio <= 0.40 and idx > 0:
        return LABEL_ORDER[idx - 1]
    return current


def parse_difficulty_label(raw: Optional[str], default: DifficultyLabel = DifficultyLabel.MEDIUM) -> DifficultyLabel:
    if not raw:
        return default
    try:
        return DifficultyLabel(raw)
    except ValueError:
        return default
