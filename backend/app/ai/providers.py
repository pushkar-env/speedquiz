"""LLM provider abstraction — never call LLMs from gameplay request paths."""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Optional

from app.core.config import get_settings
from app.core.freshness import (
    DEFAULT_VOLATILITY,
    Temporality,
    Volatility,
    temporal_hint,
)
from app.core.languages import DEFAULT_LANGUAGE, ContentLanguage, normalize_language


@dataclass
class GeneratedQuestionDraft:
    question: str
    options: list[str]
    correct_option: int
    explanation: str
    subcategory: Optional[str] = None
    difficulty: float = 0.5
    source: Optional[str] = None
    #: How fast this particular fact goes stale. Per question, not per batch:
    #: a news-sourced batch legitimately mixes "who was appointed yesterday"
    #: with "in which year was the office created".
    volatility: Volatility = DEFAULT_VOLATILITY
    #: When the fact was last known true — the publish date of the source it
    #: came from. ``None`` anchors the TTL to generation time instead.
    valid_as_of: Optional[datetime] = None
    #: Indices into the grounding context the model was given, as it claimed
    #: them. Empty for ungrounded generation; validated in the pipeline, where
    #: an unsupported claim is what separates "cited" from "made up".
    source_ids: list[str] = field(default_factory=list)
    #: Language the draft was *asked* for. The pipeline stamps it onto the
    #: stored question, so a mislabelled draft would poison a whole bank —
    #: providers must never infer it from the text they got back.
    language: ContentLanguage = DEFAULT_LANGUAGE
    meta: dict[str, Any] = field(default_factory=dict)


@dataclass
class ValidationResult:
    approved: bool
    quality_score: int
    reasons: list[str] = field(default_factory=list)
    difficulty: float = 0.5


@dataclass
class ContextSnippet:
    """One retrieved fact the model may build a question from."""

    #: Label the model cites — "S1", "S2". Short on purpose: the model repeats
    #: these back for every question, and a UUID would cost more output tokens
    #: than the citation is worth.
    id: str
    title: str
    summary: str
    url: str
    source: str
    published_at: Optional[datetime] = None

    def render(self) -> str:
        stamp = self.published_at.strftime("%Y-%m-%d") if self.published_at else "undated"
        body = self.summary.strip() or self.title.strip()
        return f"[{self.id}] ({stamp}, {self.source}) {self.title.strip()} — {body}"


@dataclass
class RetrievedContext:
    """Grounding handed to a generation call.

    Carries the snippets *and* the newest publish date among them, because the
    pipeline anchors question TTLs to when the facts were true rather than to
    when generation happened.
    """

    snippets: list[ContextSnippet] = field(default_factory=list)
    query: str = ""

    def __bool__(self) -> bool:
        return bool(self.snippets)

    @property
    def valid_ids(self) -> set[str]:
        return {s.id for s in self.snippets}

    @property
    def newest_published_at(self) -> Optional[datetime]:
        stamps = [s.published_at for s in self.snippets if s.published_at]
        return max(stamps) if stamps else None

    def render(self) -> str:
        return "\n".join(s.render() for s in self.snippets)


class LLMProvider(ABC):
    @abstractmethod
    async def generate_questions(
        self,
        *,
        topic: str,
        difficulty: str,
        count: int,
        style: Optional[str] = None,
        subcategory: Optional[str] = None,
        language: ContentLanguage = DEFAULT_LANGUAGE,
        context: Optional[RetrievedContext] = None,
    ) -> list[GeneratedQuestionDraft]:
        raise NotImplementedError

    @abstractmethod
    async def validate_questions(
        self,
        drafts: list[GeneratedQuestionDraft],
        *,
        language: ContentLanguage = DEFAULT_LANGUAGE,
    ) -> list[ValidationResult]:
        raise NotImplementedError

    @abstractmethod
    async def classify_topic(
        self,
        prompt: str,
        *,
        language: ContentLanguage = DEFAULT_LANGUAGE,
    ) -> dict[str, Any]:
        raise NotImplementedError

    @abstractmethod
    async def teach(
        self,
        *,
        question: str,
        correct_option: str,
        user_option: str,
        explanation: str,
        language: ContentLanguage = DEFAULT_LANGUAGE,
    ) -> dict[str, str]:
        raise NotImplementedError


#: Mock copy per language. Kept in-script (no transliteration) so that a Hindi
#: dev bank exercises the same Devanagari code paths as production — Unicode
#: fingerprinting, font fallback on the client, option-length layout.
_MOCK_COPY: dict[ContentLanguage, dict[str, str]] = {
    ContentLanguage.ENGLISH: {
        "question": "[{topic}] Sample question #{n} ({difficulty}{style}) [{salt}]?",
        "option": "Option {letter} for {topic} #{n}",
        "letters": "ABCD",
        "explanation": (
            "Option B is correct for {topic} question {n}. "
            "It best matches the core concept being tested."
        ),
    },
    ContentLanguage.HINDI: {
        "question": "[{topic}] नमूना प्रश्न #{n} ({difficulty}{style}) [{salt}]?",
        "option": "{topic} #{n} के लिए विकल्प {letter}",
        "letters": "कखगघ",
        "explanation": (
            "{topic} प्रश्न {n} के लिए विकल्प ख सही है। "
            "यह परखी जा रही मूल अवधारणा से सबसे अच्छा मेल खाता है।"
        ),
    },
}


class MockLLMProvider(LLMProvider):
    """Deterministic offline provider for local/dev and tests."""

    def __init__(self, *, batch_salt: Optional[str] = None) -> None:
        # Salt keeps regenerated banks unique under global content_hash.
        from uuid import uuid4

        self._batch_salt = batch_salt or uuid4().hex[:8]

    async def generate_questions(
        self,
        *,
        topic: str,
        difficulty: str,
        count: int,
        style: Optional[str] = None,
        subcategory: Optional[str] = None,
        language: ContentLanguage = DEFAULT_LANGUAGE,
        context: Optional[RetrievedContext] = None,
    ) -> list[GeneratedQuestionDraft]:
        language = normalize_language(language)
        copy = _MOCK_COPY[language]
        drafts: list[GeneratedQuestionDraft] = []
        style_bit = f" · {style}" if style else ""
        # Cite the grounding round-robin when there is any, so the pipeline's
        # citation gate is exercised by the offline provider too — a gate only
        # ever run against the real API is a gate nobody tests.
        snippet_ids = [s.id for s in context.snippets] if context else []
        for i in range(count):
            drafts.append(
                GeneratedQuestionDraft(
                    question=copy["question"].format(
                        topic=topic,
                        n=i + 1,
                        difficulty=difficulty,
                        style=style_bit,
                        salt=self._batch_salt,
                    ),
                    options=[
                        copy["option"].format(letter=letter, topic=topic, n=i + 1)
                        for letter in copy["letters"]
                    ],
                    correct_option=1,
                    explanation=copy["explanation"].format(topic=topic, n=i + 1),
                    subcategory=subcategory,
                    difficulty={"easy": 0.3, "medium": 0.5, "hard": 0.75, "expert": 0.9}.get(
                        difficulty, 0.5
                    ),
                    source="mock",
                    language=language,
                    source_ids=[snippet_ids[i % len(snippet_ids)]] if snippet_ids else [],
                    valid_as_of=context.newest_published_at if context else None,
                    meta={"style": style, "batch_salt": self._batch_salt},
                )
            )
        return drafts

    async def validate_questions(
        self,
        drafts: list[GeneratedQuestionDraft],
        *,
        language: ContentLanguage = DEFAULT_LANGUAGE,
    ) -> list[ValidationResult]:
        results: list[ValidationResult] = []
        for draft in drafts:
            reasons: list[str] = []
            approved = True
            if len(draft.options) != 4:
                approved = False
                reasons.append("must_have_four_options")
            if len(set(o.strip().lower() for o in draft.options)) < 4:
                approved = False
                reasons.append("duplicate_options")
            if draft.correct_option < 0 or draft.correct_option > 3:
                approved = False
                reasons.append("invalid_correct_option")
            if not draft.question.strip() or not draft.explanation.strip():
                approved = False
                reasons.append("malformed")
            score = 85 if approved else 20
            results.append(
                ValidationResult(
                    approved=approved,
                    quality_score=score,
                    reasons=reasons,
                    difficulty=draft.difficulty,
                )
            )
        return results

    async def classify_topic(
        self,
        prompt: str,
        *,
        language: ContentLanguage = DEFAULT_LANGUAGE,
    ) -> dict[str, Any]:
        import re

        cleaned = re.sub(
            r"(?i)^(ask me|quiz me on|quiz me about|create a quiz about|questions? about)\s+",
            "",
            prompt.strip(),
        )
        cleaned = re.sub(r"(?i)\b(difficult|hard|easy|expert)\s+questions?\s+(about\s+)?", "", cleaned)
        # Hindi has no letter case, and `.upper()` on Devanagari is a no-op, so
        # the title-casing below is harmless in both languages.
        subject = (cleaned.strip(" ।.") or prompt.strip())[:80] or "General Knowledge"
        # The mock has no judgement of its own, so it reuses the deterministic
        # hint the real path uses as a floor. That keeps dev and test runs on
        # the same temporality logic production uses, rather than pretending
        # every offline topic is settled.
        hinted = temporal_hint(prompt)
        temporality = hinted or Temporality.STATIC
        return {
            "subject": subject[:1].upper() + subject[1:] if subject else "General Knowledge",
            "category": "custom",
            "confidence": 0.7,
            "temporality": temporality.value,
            "recency_window_days": 1 if temporality is Temporality.CURRENT else None,
            "search_queries": [subject] if temporality is not Temporality.STATIC else [],
        }

    async def teach(
        self,
        *,
        question: str,
        correct_option: str,
        user_option: str,
        explanation: str,
        language: ContentLanguage = DEFAULT_LANGUAGE,
    ) -> dict[str, str]:
        if normalize_language(language) is ContentLanguage.HINDI:
            return {
                "why_correct": explanation,
                "why_wrong": f'इस प्रश्न के लिए "{user_option}" सही नहीं है।',
                "key_concept": "मूल अवधारणा दोहराएँ और मिलता-जुलता प्रश्न आज़माएँ।",
                "memorable_fact": f"याद रखें: {correct_option}।",
            }
        return {
            "why_correct": explanation,
            "why_wrong": f'"{user_option}" is incorrect for this question.',
            "key_concept": "Review the core idea and try a similar question.",
            "memorable_fact": f"Remember: {correct_option}.",
        }


def get_llm_provider() -> LLMProvider:
    settings = get_settings()
    # Gameplay never depends on this path — only generation / teach / classify.
    provider = (settings.llm_provider or "mock").strip().lower()
    api_key = (settings.llm_api_key or "").strip()

    if provider == "openai" and api_key:
        from app.ai.openai_provider import OpenAILLMProvider

        return OpenAILLMProvider(api_key=api_key)

    if provider not in {"mock", ""} and not api_key:
        # Misconfigured real provider — stay safe with mock rather than crashing.
        return MockLLMProvider()

    return MockLLMProvider()
