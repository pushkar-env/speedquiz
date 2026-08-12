"""Localized catalog copy: topic and category names in the player's language.

Only *curated* strings live here. Anything a player or an LLM authored — custom
topic names, question text — is already written in one language and is never
translated on the way out.

Resolution is always: requested language → English source column. A missing
translation shows the English name rather than a blank or a key, because a
half-translated catalog is still usable and an empty chip is not.
"""

from __future__ import annotations

from typing import Optional

from app.core.languages import DEFAULT_LANGUAGE, ContentLanguage, normalize_language


def _pick(
    translations: Optional[dict],
    language: ContentLanguage,
    fallback: str,
) -> str:
    """Value for `language` from a `*_i18n` JSONB blob, else `fallback`."""
    if language is DEFAULT_LANGUAGE or not translations:
        return fallback
    if not isinstance(translations, dict):
        return fallback
    value = translations.get(language.value)
    if isinstance(value, str) and value.strip():
        return value.strip()
    return fallback


def localized_topic_name(topic, language: object = DEFAULT_LANGUAGE) -> str:
    return _pick(getattr(topic, "name_i18n", None), normalize_language(language), topic.name)


def localized_topic_description(topic, language: object = DEFAULT_LANGUAGE) -> Optional[str]:
    description = getattr(topic, "description", None)
    localized = _pick(
        getattr(topic, "description_i18n", None),
        normalize_language(language),
        description or "",
    )
    return localized or None


def localized_category_name(category, language: object = DEFAULT_LANGUAGE) -> str:
    return _pick(
        getattr(category, "name_i18n", None),
        normalize_language(language),
        category.name,
    )
