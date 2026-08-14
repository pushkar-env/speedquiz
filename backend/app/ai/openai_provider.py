"""OpenAI-backed LLM provider for generation, validation, classification, and Teach Me."""

from __future__ import annotations

import json
import re
from datetime import datetime, timezone
from typing import Any, Optional

import httpx

from app.ai.providers import (
    GeneratedQuestionDraft,
    LLMProvider,
    RetrievedContext,
    ValidationResult,
)
from app.core.config import get_settings
from app.core.freshness import (
    DEFAULT_VOLATILITY,
    Volatility,
    as_of_date,
    normalize_volatility,
)
from app.core.languages import (
    DEFAULT_LANGUAGE,
    ContentLanguage,
    generation_directive,
    normalize_language,
    profile_for,
)
from app.core.logging import get_logger

logger = get_logger(__name__)
settings = get_settings()


def _extract_json(text: str) -> Any:
    text = text.strip()
    if text.startswith("```"):
        text = re.sub(r"^```(?:json)?\s*", "", text)
        text = re.sub(r"\s*```$", "", text)
    return json.loads(text)


def _string_list(raw: object, *, limit: int = 3) -> list[str]:
    """Coerce whatever the model returned into a short list of strings."""
    if isinstance(raw, str):
        raw = [raw]
    if not isinstance(raw, (list, tuple)):
        return []
    out: list[str] = []
    for item in raw:
        text = str(item).strip()
        if text and text not in out:
            out.append(text)
        if len(out) >= limit:
            break
    return out


def _positive_int(raw: object) -> Optional[int]:
    """A positive int, or None. Models answer this field with "30 days", 30.0,
    and "about a month" in roughly equal measure."""
    if isinstance(raw, bool) or raw is None:
        return None
    if isinstance(raw, (int, float)):
        value = int(raw)
        return value if value > 0 else None
    match = re.search(r"\d+", str(raw))
    if not match:
        return None
    value = int(match.group(0))
    return value if value > 0 else None


def _parse_correct_option(raw: object, options: list[str]) -> int:
    """Accept 0-3 int, numeric string, letter A-D, or exact option text."""
    if isinstance(raw, bool):
        return 0
    if isinstance(raw, int):
        return raw if 0 <= raw <= 3 else 0
    if isinstance(raw, float):
        value = int(raw)
        return value if 0 <= value <= 3 else 0
    if isinstance(raw, str):
        text = raw.strip()
        if text.isdigit():
            value = int(text)
            return value if 0 <= value <= 3 else 0
        if len(text) == 1 and text.upper() in "ABCD":
            return "ABCD".index(text.upper())
        lowered = text.lower()
        for i, opt in enumerate(options):
            if opt.strip().lower() == lowered:
                return i
    return 0


class OpenAILLMProvider(LLMProvider):
    def __init__(self, *, api_key: Optional[str] = None) -> None:
        self._api_key = (api_key or settings.llm_api_key or "").strip()
        if not self._api_key:
            raise ValueError("LLM_API_KEY is required for OpenAI provider")
        self._base_url = "https://api.openai.com/v1/chat/completions"

    async def _chat(
        self,
        *,
        model: str,
        system: str,
        user: str,
        temperature: float = 0.4,
    ) -> str:
        headers = {
            "Authorization": f"Bearer {self._api_key}",
            "Content-Type": "application/json",
        }
        body = {
            "model": model,
            "temperature": temperature,
            "response_format": {"type": "json_object"},
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
        }
        async with httpx.AsyncClient(timeout=90.0) as client:
            response = await client.post(self._base_url, headers=headers, json=body)
            if response.status_code >= 400:
                logger.error(
                    "openai_error",
                    status=response.status_code,
                    body=response.text[:500],
                )
                response.raise_for_status()
            data = response.json()
            return data["choices"][0]["message"]["content"]

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
        lang = profile_for(language)
        grounded = bool(context)

        fields = (
            "Each item: question, options (exactly 4 distinct strings), "
            "correct_option (0-3), explanation, difficulty (0-1 float), subcategory"
        )
        if grounded:
            fields += (
                ", source_ids (array of the [S#] labels this question is built "
                "from), volatility, as_of_date (YYYY-MM-DD)"
            )

        system = (
            "You are a quiz writer for a premium mobile game. "
            "Return JSON only with key `questions` (array). "
            f"{fields}.\n"
            # Language sits in the system prompt, not just the user turn: models
            # drift back to English partway through a long batch when the
            # instruction is buried in the request.
            f"LANGUAGE ({lang.english_name}): {lang.generation_directive}"
        )
        if grounded:
            system += (
                "\n\nGROUNDING RULES — these override everything else:\n"
                "1. Every question must be answerable from the SOURCES block "
                "alone. Do not use anything you remember from training, even if "
                "you are confident it is true — your training data is older "
                "than these sources and may contradict them.\n"
                "2. Cite in `source_ids` the exact [S#] labels the answer comes "
                "from. Never invent a label that is not in the block.\n"
                "3. If the sources do not support enough good questions, return "
                "fewer. A short array is correct; a padded one is not.\n"
                "4. `volatility`: 'fast' if the answer changes within weeks "
                "(office holders, standings, prices, ongoing events), 'slow' if "
                "within years, 'static' if it is a fixed historical fact — a "
                "date, a founding, a record that has already been set.\n"
                "5. `as_of_date`: the publish date of the newest source used.\n"
                "6. Never write a question whose answer depends on when it is "
                "read. Not 'who is the current champion' but 'who won the "
                "title on 12 August 2026'. A question anchored to a date stays "
                "true; one anchored to 'now' rots the moment it is stored."
            )

        user = (
            f"Create {count} multiple-choice questions about: {topic}.\n"
            f"Difficulty label: {difficulty}.\n"
            f"Style: {style or 'engaging trivia'}.\n"
            f"Subcategory hint: {subcategory or 'general'}.\n"
            "Make distractors plausible. Explanations must teach, not just restate.\n"
            f"Write everything in {lang.english_name} ({lang.native_name}). "
            "The `subcategory` field may stay in English; every player-visible "
            "string must not."
        )
        if grounded:
            source_note = ""
            if language is not ContentLanguage.ENGLISH:
                # The Hindi corpus is a third the size of the English one, so a
                # Hindi run is routinely grounded on English headlines. Saying
                # so explicitly stops the model treating the language mismatch
                # as a reason to fall back on memory.
                source_note = (
                    "\nSome sources may be in English. Translate the facts into "
                    f"{lang.native_name} — do not skip a source over language, "
                    "and do not quote it untranslated."
                )
            user += (
                f"\n\nSOURCES (today is {datetime.now(timezone.utc):%Y-%m-%d}):\n"
                f"{context.render()}{source_note}"
            )

        raw = await self._chat(
            model=settings.llm_model_generate,
            system=system,
            user=user,
            # Grounded batches run cooler. Invention is the failure mode that
            # matters here, and the sources already supply the variety that
            # temperature would otherwise have to.
            temperature=0.4 if grounded else 0.7,
        )
        payload = _extract_json(raw)
        items = payload.get("questions") if isinstance(payload, dict) else payload
        drafts: list[GeneratedQuestionDraft] = []
        for item in items or []:
            options = list(item.get("options") or [])
            if len(options) != 4:
                continue
            # Only trust freshness fields on a grounded call. An ungrounded
            # model volunteering `volatility: fast` is guessing, and acting on
            # it would expire a perfectly permanent question about the Mughals.
            volatility = (
                normalize_volatility(
                    item.get("volatility"),
                    default=DEFAULT_VOLATILITY if not grounded else Volatility.FAST,
                )
                if grounded
                else DEFAULT_VOLATILITY
            )
            drafts.append(
                GeneratedQuestionDraft(
                    question=str(item.get("question") or "").strip(),
                    options=[str(o).strip() for o in options],
                    correct_option=_parse_correct_option(item.get("correct_option", 0), options),
                    explanation=str(item.get("explanation") or "").strip(),
                    subcategory=item.get("subcategory") or subcategory,
                    difficulty=float(item.get("difficulty", 0.5)),
                    source="openai",
                    language=language,
                    volatility=volatility,
                    valid_as_of=as_of_date(item.get("as_of_date")) if grounded else None,
                    source_ids=_string_list(item.get("source_ids"), limit=6) if grounded else [],
                    meta={"style": style, "language": language.value},
                )
            )
        return drafts

    async def validate_questions(
        self,
        drafts: list[GeneratedQuestionDraft],
        *,
        language: ContentLanguage = DEFAULT_LANGUAGE,
    ) -> list[ValidationResult]:
        if not drafts:
            return []
        # Drafts carry the language they were generated for; the keyword is the
        # fallback for callers that hand over a bare list.
        language = normalize_language(drafts[0].language or language)
        lang = profile_for(language)
        system = (
            "You are a strict quiz quality reviewer. Return JSON with key `results` "
            "(array aligned to input order). Each item: approved (bool), quality_score "
            "(0-100), reasons (string array), difficulty (0-1).\n"
            f"The questions are written in {lang.english_name} "
            f"({lang.native_name}). Judge them as a native reader would: reject "
            "anything machine-translated, in the wrong script, or mixing "
            "languages mid-sentence, with reason `wrong_language`."
        )
        serialized = [
            {
                "question": d.question,
                "options": d.options,
                "correct_option": d.correct_option,
                "explanation": d.explanation,
            }
            for d in drafts
        ]
        user = (
            "Reject if: wrong answer marked correct, duplicate options, ambiguous stem, "
            "unsafe content, or weak explanation.\n"
            f"Questions:\n{json.dumps(serialized)}"
        )
        try:
            raw = await self._chat(
                model=settings.llm_model_validate,
                system=system,
                user=user,
                temperature=0.1,
            )
            payload = _extract_json(raw)
            items = payload.get("results") if isinstance(payload, dict) else payload
        except Exception as exc:  # noqa: BLE001
            logger.exception("openai_validate_failed", error=str(exc))
            return [
                ValidationResult(approved=False, quality_score=0, reasons=["ai_validation_error"])
                for _ in drafts
            ]

        results: list[ValidationResult] = []
        for i, draft in enumerate(drafts):
            item = items[i] if isinstance(items, list) and i < len(items) else {}
            results.append(
                ValidationResult(
                    approved=bool(item.get("approved", False)),
                    quality_score=int(item.get("quality_score", 0)),
                    reasons=[str(r) for r in (item.get("reasons") or [])],
                    difficulty=float(item.get("difficulty", draft.difficulty)),
                )
            )
        return results

    async def classify_topic(
        self,
        prompt: str,
        *,
        language: ContentLanguage = DEFAULT_LANGUAGE,
    ) -> dict[str, Any]:
        lang = profile_for(language)
        system = (
            "Classify a custom quiz request. Return JSON: subject (short title), "
            "category, confidence (0-1), temporality, recency_window_days, "
            "search_queries. "
            # The subject becomes the topic's display name in the app, so it has
            # to match the language the player will actually see.
            f"Write `subject` in {lang.english_name} ({lang.native_name}); "
            "`category` stays a lowercase English slug.\n"
            # Folded into the call that already runs on every custom request
            # rather than a second round trip: the marginal cost is a few dozen
            # output tokens, and a separate call would double the latency of a
            # path the player is waiting on.
            "`temporality` is one of:\n"
            "  static — settled subject; the answer would have been the same "
            "five years ago (history, science, classic film, grammar).\n"
            "  evolving — drifts over months or years (a sports league, an "
            "ongoing franchise, a country's records).\n"
            "  current — needs this week's facts to be correct at all (news, "
            "office holders, prices, live standings, latest releases).\n"
            "`recency_window_days`: how old a fact may be and still be right "
            "for this topic. Use 1 for breaking news, 7-30 for a running "
            "season, 365+ for anything slow. Integer.\n"
            "`search_queries`: 1-3 short web search strings that would find the "
            "facts needed. Empty array when temporality is static."
        )
        user = f"User request: {prompt}"
        try:
            raw = await self._chat(
                model=settings.llm_model_classify,
                system=system,
                user=user,
                temperature=0.2,
            )
            payload = _extract_json(raw)
            if isinstance(payload, dict) and payload.get("subject"):
                payload["search_queries"] = _string_list(payload.get("search_queries"))
                payload["recency_window_days"] = _positive_int(
                    payload.get("recency_window_days")
                )
                return payload
        except Exception as exc:  # noqa: BLE001
            logger.exception("openai_classify_failed", error=str(exc))
        # The fallback deliberately omits `temporality`. Claiming "static" here
        # would let a failed classification silently mark a news topic settled;
        # leaving it absent means the caller's own regex hint is the only
        # signal, and that errs toward fresh.
        return {
            "subject": prompt.strip()[:80] or "General Knowledge",
            "category": "custom",
            "confidence": 0.4,
            "search_queries": [],
            "recency_window_days": None,
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
        system = (
            "You are a friendly tutor for a quiz game. Return JSON with keys: "
            "why_correct, why_wrong, key_concept, memorable_fact. Keep each under 2 sentences. "
            f"{generation_directive(language)}"
        )
        user = (
            f"Question: {question}\n"
            f"Correct answer: {correct_option}\n"
            f"Player answered: {user_option}\n"
            f"Base explanation: {explanation}"
        )
        raw = await self._chat(
            model=settings.llm_model_classify,
            system=system,
            user=user,
            temperature=0.4,
        )
        payload = _extract_json(raw)
        return {
            "why_correct": str(payload.get("why_correct") or explanation),
            "why_wrong": str(payload.get("why_wrong") or f'"{user_option}" is not correct.'),
            "key_concept": str(payload.get("key_concept") or "Review the core idea."),
            "memorable_fact": str(payload.get("memorable_fact") or f"Remember: {correct_option}."),
        }
