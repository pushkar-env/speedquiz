"""LLM provider abstraction — never call LLMs from gameplay request paths."""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Any, Optional

from app.core.config import get_settings
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
    ) -> list[GeneratedQuestionDraft]:
        language = normalize_language(language)
        copy = _MOCK_COPY[language]
        drafts: list[GeneratedQuestionDraft] = []
        style_bit = f" · {style}" if style else ""
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
        return {
            "subject": subject[:1].upper() + subject[1:] if subject else "General Knowledge",
            "category": "custom",
            "confidence": 0.7,
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
