from app.models import DifficultyLabel
from app.services.adaptive import (
    DEFAULT_RATING,
    nudge_label,
    rating_to_label,
    suggested_label_from_ratings,
    update_topic_rating,
)


def test_rating_to_label_bands():
    assert rating_to_label(800) == DifficultyLabel.EASY
    assert rating_to_label(1000) == DifficultyLabel.MEDIUM
    assert rating_to_label(1200) == DifficultyLabel.HARD
    assert rating_to_label(1500) == DifficultyLabel.EXPERT


def test_suggested_label_default_medium():
    assert suggested_label_from_ratings({}, "topic-1") == DifficultyLabel.MEDIUM


def test_suggested_label_from_stored():
    ratings = {"t1": {"rating": 1400, "games": 2, "suggested": "hard"}}
    assert suggested_label_from_ratings(ratings, "t1") == DifficultyLabel.HARD


def test_update_topic_rating_increases_on_strong_run():
    ratings = update_topic_rating(
        {},
        topic_id="t1",
        accuracy_percent=100.0,
        session_label=DifficultyLabel.MEDIUM,
    )
    entry = ratings["t1"]
    assert entry["games"] == 1
    assert entry["rating"] > DEFAULT_RATING
    assert entry["suggested"] in {"easy", "medium", "hard", "expert"}


def test_update_topic_rating_decreases_on_weak_run():
    ratings = update_topic_rating(
        {"t1": {"rating": 1000, "games": 1, "suggested": "medium"}},
        topic_id="t1",
        accuracy_percent=0.0,
        session_label=DifficultyLabel.MEDIUM,
    )
    assert ratings["t1"]["rating"] < 1000
    assert ratings["t1"]["games"] == 2


def test_nudge_harder_on_high_accuracy():
    assert (
        nudge_label(DifficultyLabel.MEDIUM, recent_correct=5, recent_total=5)
        == DifficultyLabel.HARD
    )


def test_nudge_easier_on_low_accuracy():
    assert (
        nudge_label(DifficultyLabel.MEDIUM, recent_correct=1, recent_total=5)
        == DifficultyLabel.EASY
    )


def test_nudge_holds_in_middle():
    assert (
        nudge_label(DifficultyLabel.MEDIUM, recent_correct=3, recent_total=5)
        == DifficultyLabel.MEDIUM
    )


def test_nudge_clamps_at_ends():
    assert nudge_label(DifficultyLabel.EASY, recent_correct=0, recent_total=5) == DifficultyLabel.EASY
    assert (
        nudge_label(DifficultyLabel.EXPERT, recent_correct=5, recent_total=5)
        == DifficultyLabel.EXPERT
    )
