"""Unit tests for AI generation pipeline helpers (no DB)."""

import pytest

from app.ai.pipeline import (
    content_hash,
    difficulty_label_for,
    fingerprint,
    sanitize_topic_prompt,
    schema_validate,
    slugify,
)
from app.ai.providers import GeneratedQuestionDraft, MockLLMProvider
from app.models import DifficultyLabel


def test_sanitize_and_slugify():
    assert sanitize_topic_prompt("  Elden <Ring> lore  ") == "Elden Ring lore"
    assert slugify("Elden Ring Lore!") == "elden-ring-lore"


def test_schema_validate_rejects_bad_drafts():
    bad = GeneratedQuestionDraft(
        question="Hi",
        options=["A", "A", "B", ""],
        correct_option=9,
        explanation="",
        difficulty=2.0,
    )
    reasons = schema_validate(bad)
    assert "malformed_question" in reasons
    assert "duplicate_options" in reasons
    assert "empty_option" in reasons
    assert "invalid_correct_option" in reasons
    assert "malformed_explanation" in reasons
    assert "invalid_difficulty" in reasons


def test_schema_validate_accepts_good_draft():
    good = GeneratedQuestionDraft(
        question="What is the capital of France?",
        options=["Berlin", "Paris", "Rome", "Madrid"],
        correct_option=1,
        explanation="Paris is the capital of France.",
        difficulty=0.4,
    )
    assert schema_validate(good) == []


def test_difficulty_label_buckets():
    assert difficulty_label_for(0.2) == DifficultyLabel.EASY
    assert difficulty_label_for(0.5) == DifficultyLabel.MEDIUM
    assert difficulty_label_for(0.7) == DifficultyLabel.HARD
    assert difficulty_label_for(0.9) == DifficultyLabel.EXPERT


def test_content_hash_and_fingerprint_stable():
    a = content_hash("Q?", ["A", "B", "C", "D"])
    b = content_hash("q?", ["a", "b", "c", "d"])
    assert a == b
    assert fingerprint("Black hole event horizon") == fingerprint("event horizon black hole")


@pytest.mark.asyncio
async def test_mock_pipeline_ready_drafts_validate():
    provider = MockLLMProvider(batch_salt="test")
    drafts = await provider.generate_questions(topic="Astronomy", difficulty="hard", count=5)
    assert len(drafts) == 5
    assert all(schema_validate(d) == [] for d in drafts)
    results = await provider.validate_questions(drafts)
    assert all(r.approved and r.quality_score >= 70 for r in results)


@pytest.mark.asyncio
async def test_mock_teach_and_classify():
    provider = MockLLMProvider(batch_salt="teach")
    classified = await provider.classify_topic("Ask me about black holes")
    assert "subject" in classified
    taught = await provider.teach(
        question="Q?",
        correct_option="Right",
        user_option="Wrong",
        explanation="Because physics.",
    )
    assert taught["why_correct"]
    assert taught["key_concept"]
