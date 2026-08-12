"""The two language axes of the app, and everything needed to resolve them.

SpeedQuiz has two independent languages:

``app language``
    Chrome the player reads — buttons, headers, toasts. Lives entirely in the
    Flutter client; the server only stores it so a reinstall or a second device
    starts in the right language (``user_profiles.app_language``).

``content language``
    The language questions, options and explanations are *written in*. Chosen
    per run, stored on the session, and — critically — baked into every row of
    the question bank. A Hindi run must never be served an English question, so
    this is a filter on selection, not a translation applied at read time.

Only content language is authoritative here. Translating a banked question at
serve time would mean an LLM call on the play path, which this codebase
deliberately never does.

Why a plain ``String(8)`` column and not a Postgres ENUM
--------------------------------------------------------
Adding the fifth language should be a data change, not an ``ALTER TYPE`` on a
table with millions of rows. The codes are BCP-47 primary subtags, validated at
the API boundary by :func:`normalize_language`, so the database stays as strict
as an enum without the migration cost.
"""

from __future__ import annotations

import enum
from dataclasses import dataclass
from typing import Optional


class ContentLanguage(str, enum.Enum):
    """A language the question bank can be written in."""

    ENGLISH = "en"
    HINDI = "hi"


#: What everything falls back to: unparseable input, legacy rows, the daily
#: challenge, and any client too old to send a language at all.
DEFAULT_LANGUAGE = ContentLanguage.ENGLISH

#: Column width for every ``language`` column. Room for ``pt-BR``-style tags if
#: a future language needs regional distinction.
LANGUAGE_CODE_MAX_LENGTH = 8


@dataclass(frozen=True)
class LanguageProfile:
    """Everything the rest of the app needs to know about one language."""

    language: ContentLanguage
    #: English name, for logs, admin tooling and analytics.
    english_name: str
    #: Endonym — what the language calls itself. This is what a picker shows.
    native_name: str
    #: ISO 15924 script code. Drives font-fallback decisions on the client.
    script: str
    #: Appended to every generation prompt. Vague instructions ("in Hindi") get
    #: transliterated Hinglish back from most models, so this is explicit about
    #: script and about the loanwords that should stay in English.
    generation_directive: str

    @property
    def code(self) -> str:
        return self.language.value


LANGUAGE_PROFILES: dict[ContentLanguage, LanguageProfile] = {
    ContentLanguage.ENGLISH: LanguageProfile(
        language=ContentLanguage.ENGLISH,
        english_name="English",
        native_name="English",
        script="Latn",
        generation_directive=(
            "Write every question, option and explanation in natural, modern "
            "English."
        ),
    ),
    ContentLanguage.HINDI: LanguageProfile(
        language=ContentLanguage.HINDI,
        english_name="Hindi",
        native_name="हिन्दी",
        script="Deva",
        generation_directive=(
            "Write every question, option and explanation in Hindi using the "
            "Devanagari script. Do not romanise Hindi and do not write "
            "Hinglish. Use natural conversational Hindi that a general "
            "audience reads comfortably, not literary or Sanskritised Hindi. "
            "Proper nouns, scientific names, units and established technical "
            "terms with no common Hindi equivalent may stay in their original "
            "script, with the Devanagari form alongside where it helps. "
            "Numerals must be written in Western Arabic digits (0-9)."
        ),
    ),
}


def normalize_language(raw: object, *, default: Optional[ContentLanguage] = None) -> ContentLanguage:
    """Best-effort parse of anything a client, column or job payload offers.

    Accepts the enum itself, a bare code (``"hi"``), a full BCP-47 tag
    (``"hi-IN"``, ``"hi_IN"``) or a stored column value, in any case. Anything
    unrecognised — including ``None`` and empty strings — resolves to
    ``default`` (or :data:`DEFAULT_LANGUAGE`) rather than raising, because a
    stale client sending ``"en-GB"`` should get a playable run, not a 422.
    """
    fallback = default or DEFAULT_LANGUAGE
    if isinstance(raw, ContentLanguage):
        return raw
    if raw is None:
        return fallback

    text = str(raw).strip().lower()
    if not text:
        return fallback

    # Primary subtag only: "hi-in" / "hi_in" / "hi" all mean Hindi to us.
    primary = text.replace("_", "-").split("-", 1)[0]
    try:
        return ContentLanguage(primary)
    except ValueError:
        return fallback


def language_code(raw: object) -> str:
    """Normalized code, ready to be written to a ``language`` column."""
    return normalize_language(raw).value


def profile_for(language: object) -> LanguageProfile:
    return LANGUAGE_PROFILES[normalize_language(language)]


def generation_directive(language: object) -> str:
    """The instruction appended to LLM generation and validation prompts."""
    return profile_for(language).generation_directive


def supported_languages() -> list[LanguageProfile]:
    """Every language the bank can hold, default first."""
    ordered = [DEFAULT_LANGUAGE] + [
        lang for lang in ContentLanguage if lang is not DEFAULT_LANGUAGE
    ]
    return [LANGUAGE_PROFILES[lang] for lang in ordered]


def is_supported(raw: object) -> bool:
    """True when ``raw`` names a language we actually stock, exactly."""
    if isinstance(raw, ContentLanguage):
        return True
    if raw is None:
        return False
    text = str(raw).strip().lower().replace("_", "-").split("-", 1)[0]
    return text in {lang.value for lang in ContentLanguage}
