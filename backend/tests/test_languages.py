"""The content-language axis: parsing, dedupe, generation and localized copy."""

import pytest

from app.ai.pipeline import content_hash, fingerprint, slugify
from app.ai.providers import MockLLMProvider
from app.core.languages import (
    DEFAULT_LANGUAGE,
    ContentLanguage,
    generation_directive,
    is_supported,
    normalize_language,
    profile_for,
    supported_languages,
)
from app.models import DifficultyLabel
from app.services.custom_topics import cache_key_for
from app.services.localization import (
    localized_category_name,
    localized_topic_description,
    localized_topic_name,
)
from app.services.quiz_service import _empty_bank_error
from app.services.seed import CATEGORIES, TOPIC_NAMES_HI, TOPICS
from app.services.share import build_share_payload


# --- parsing ---------------------------------------------------------------


@pytest.mark.parametrize(
    "raw,expected",
    [
        ("hi", ContentLanguage.HINDI),
        ("HI", ContentLanguage.HINDI),
        ("hi-IN", ContentLanguage.HINDI),
        ("hi_IN", ContentLanguage.HINDI),
        (" Hi-in ", ContentLanguage.HINDI),
        ("en", ContentLanguage.ENGLISH),
        ("en-GB", ContentLanguage.ENGLISH),
        (ContentLanguage.HINDI, ContentLanguage.HINDI),
    ],
)
def test_normalize_language_accepts_locale_tags(raw, expected):
    assert normalize_language(raw) is expected


@pytest.mark.parametrize("raw", [None, "", "   ", "xx", "klingon", 42, {"a": 1}])
def test_unknown_language_falls_back_rather_than_raising(raw):
    """A stale client sending an unsupported tag gets a playable run, not a 422."""
    assert normalize_language(raw) is DEFAULT_LANGUAGE


def test_normalize_language_honours_explicit_default():
    assert normalize_language(None, default=ContentLanguage.HINDI) is ContentLanguage.HINDI


def test_is_supported_is_stricter_than_normalize():
    assert is_supported("hi-IN")
    assert not is_supported("fr")
    assert not is_supported(None)


def test_every_supported_language_has_a_complete_profile():
    profiles = supported_languages()
    assert profiles[0].language is DEFAULT_LANGUAGE
    assert {p.language for p in profiles} == set(ContentLanguage)
    for profile in profiles:
        assert profile.native_name.strip()
        assert profile.english_name.strip()
        assert profile.script.strip()
        assert len(profile.generation_directive) > 40


def test_hindi_directive_forbids_romanisation():
    """Vague "in Hindi" prompts come back as Hinglish — the directive is explicit."""
    directive = generation_directive(ContentLanguage.HINDI)
    assert "Devanagari" in directive
    assert "Hinglish" in directive


# --- dedupe ----------------------------------------------------------------


def test_fingerprint_separates_devanagari_prompts():
    """Regression: an ASCII-only token class hashed every Hindi prompt alike.

    With `[a-z0-9]+` no token matched Devanagari, so every Hindi question
    fingerprinted the empty string and the second one ever generated for a
    topic was rejected as a near-duplicate of the first.
    """
    first = fingerprint("भारत की राजधानी कौन सी है?")
    second = fingerprint("विश्व का सबसे बड़ा महासागर कौन सा है?")
    assert first != second
    assert first != fingerprint("")


def test_fingerprint_still_ignores_word_order():
    assert fingerprint("who wrote 1984") == fingerprint("1984 wrote who")
    assert fingerprint("गंगा नदी") == fingerprint("नदी गंगा")


def test_content_hash_is_language_scoped():
    """Some strings are identical in both languages; both banks must hold one."""
    options = ["NATO", "SAARC", "ASEAN", "OPEC"]
    english = content_hash("NATO?", options, ContentLanguage.ENGLISH)
    hindi = content_hash("NATO?", options, ContentLanguage.HINDI)
    assert english != hindi


def test_content_hash_defaults_to_english():
    options = ["a", "b", "c", "d"]
    assert content_hash("Q?", options) == content_hash("Q?", options, ContentLanguage.ENGLISH)


def test_slugify_degrades_to_a_stable_digest_for_non_latin():
    """Hindi strips to nothing under an ASCII slug rule — it must not collide."""
    one = slugify("भारतीय इतिहास")
    two = slugify("भारतीय भूगोल")
    assert one != two
    assert one == slugify("भारतीय इतिहास")
    assert one.isascii() and one.strip("-")


# --- generation ------------------------------------------------------------


@pytest.mark.asyncio
async def test_mock_provider_writes_hindi_in_devanagari():
    provider = MockLLMProvider(batch_salt="test")
    drafts = await provider.generate_questions(
        topic="भारतीय इतिहास",
        difficulty="medium",
        count=2,
        language=ContentLanguage.HINDI,
    )
    assert len(drafts) == 2
    for draft in drafts:
        assert draft.language is ContentLanguage.HINDI
        assert "प्रश्न" in draft.question
        assert all(any("ऀ" <= ch <= "ॿ" for ch in o) for o in draft.options)


@pytest.mark.asyncio
async def test_mock_provider_defaults_to_english():
    provider = MockLLMProvider(batch_salt="test")
    drafts = await provider.generate_questions(topic="Astronomy", difficulty="easy", count=1)
    assert drafts[0].language is DEFAULT_LANGUAGE
    assert "Sample question" in drafts[0].question


@pytest.mark.asyncio
async def test_generated_languages_do_not_collide_on_content_hash():
    provider = MockLLMProvider(batch_salt="fixed")
    english = await provider.generate_questions(topic="Cricket", difficulty="easy", count=1)
    hindi = await provider.generate_questions(
        topic="Cricket", difficulty="easy", count=1, language=ContentLanguage.HINDI
    )
    assert content_hash(
        english[0].question, english[0].options, ContentLanguage.ENGLISH
    ) != content_hash(hindi[0].question, hindi[0].options, ContentLanguage.HINDI)


@pytest.mark.asyncio
async def test_mock_teach_answers_in_the_question_language():
    provider = MockLLMProvider()
    taught = await provider.teach(
        question="भारत की राजधानी?",
        correct_option="नई दिल्ली",
        user_option="मुंबई",
        explanation="नई दिल्ली भारत की राजधानी है।",
        language=ContentLanguage.HINDI,
    )
    assert "याद रखें" in taught["memorable_fact"]


# --- custom topics ---------------------------------------------------------


def test_custom_topic_cache_key_is_language_scoped():
    """The same prompt in two languages must not reuse one bank."""
    english = cache_key_for("Mughal empire", DifficultyLabel.MEDIUM, None, ContentLanguage.ENGLISH)
    hindi = cache_key_for("Mughal empire", DifficultyLabel.MEDIUM, None, ContentLanguage.HINDI)
    assert english != hindi


def test_custom_topic_cache_key_defaults_to_english():
    assert cache_key_for("Space", DifficultyLabel.MEDIUM, None) == cache_key_for(
        "Space", DifficultyLabel.MEDIUM, None, ContentLanguage.ENGLISH
    )


# --- localized catalog copy ------------------------------------------------


class _FakeTopic:
    def __init__(self, name, name_i18n=None, description=None, description_i18n=None):
        self.name = name
        self.name_i18n = name_i18n or {}
        self.description = description
        self.description_i18n = description_i18n or {}


def test_localized_name_prefers_translation_then_falls_back():
    topic = _FakeTopic("Astronomy", {"hi": "खगोल विज्ञान"})
    assert localized_topic_name(topic, ContentLanguage.HINDI) == "खगोल विज्ञान"
    assert localized_topic_name(topic, ContentLanguage.ENGLISH) == "Astronomy"
    assert localized_topic_name(_FakeTopic("Esports"), ContentLanguage.HINDI) == "Esports"


@pytest.mark.parametrize("blank", [{}, {"hi": ""}, {"hi": "   "}, {"hi": 5}, None, "not a dict"])
def test_blank_translations_fall_back_to_english(blank):
    topic = _FakeTopic("Gadgets", blank)
    assert localized_topic_name(topic, ContentLanguage.HINDI) == "Gadgets"


def test_localized_description_returns_none_when_absent():
    assert localized_topic_description(_FakeTopic("X"), ContentLanguage.HINDI) is None


def test_localized_category_name():
    category = _FakeTopic("Science", {"hi": "विज्ञान"})
    assert localized_category_name(category, "hi-IN") == "विज्ञान"


def test_seeded_catalog_is_fully_translated():
    """Every curated topic and category ships with a Hindi name.

    A half-translated picker is the most visible way this feature can look
    unfinished, so parity is asserted rather than hoped for.
    """
    missing_topics = {slug for slug, *_ in TOPICS} - set(TOPIC_NAMES_HI)
    assert not missing_topics, f"topics without a Hindi name: {sorted(missing_topics)}"

    from app.services.seed import CATEGORY_NAMES_HI

    missing_categories = {slug for slug, *_ in CATEGORIES} - set(CATEGORY_NAMES_HI)
    assert not missing_categories


# --- share + errors --------------------------------------------------------


def test_share_text_is_unchanged_for_english():
    """This string already lives in people's chat history — do not churn it."""
    payload = build_share_payload(
        session_id=__import__("uuid").uuid4(),
        topic_name="Astronomy",
        difficulty="hard",
        mode="speedrun",
        score=1234,
        accuracy=88.0,
        best_streak=9,
        questions_answered=20,
    )
    assert "Score: 1,234" in payload["text"]
    assert "Accuracy: 88%" in payload["text"]
    assert "Can you beat me?" in payload["text"]
    assert "HARD · speedrun" in payload["text"]
    assert payload["language"] == "en"


def test_share_text_follows_the_run_language():
    payload = build_share_payload(
        session_id=__import__("uuid").uuid4(),
        topic_name="भारतीय इतिहास",
        difficulty="medium",
        mode="survival",
        score=900,
        accuracy=75.0,
        best_streak=6,
        questions_answered=12,
        language=ContentLanguage.HINDI,
    )
    assert "स्कोर: 900" in payload["text"]
    assert "सर्वाइवल" in payload["text"]
    assert "मध्यम" in payload["text"]
    assert payload["language"] == "hi"
    # Stats stay machine-readable in English for the landing page and analytics.
    assert payload["stats"]["mode"] == "survival"


def test_empty_bank_error_is_structured_and_names_the_language():
    error = _empty_bank_error(ContentLanguage.HINDI)
    assert error.status_code == 409
    assert error.detail["code"] == "content_language_unavailable"
    assert error.detail["language"] == "hi"
    assert profile_for("hi").english_name in error.detail["message"]
