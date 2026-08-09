"""OpenAI-backed LLM provider for generation, validation, classification, and Teach Me."""

from __future__ import annotations

import json
import re
from typing import Any, Optional

import httpx

from app.ai.providers import GeneratedQuestionDraft, LLMProvider, ValidationResult
from app.core.config import get_settings
from app.core.logging import get_logger

logger = get_logger(__name__)
settings = get_settings()


def _extract_json(text: str) -> Any:
    text = text.strip()
    if text.startswith("```"):
        text = re.sub(r"^```(?:json)?\s*", "", text)
        text = re.sub(r"\s*```$", "", text)
    return json.loads(text)


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
    ) -> list[GeneratedQuestionDraft]:
        system = (
            "You are a quiz writer for a premium mobile game. "
            "Return JSON only with key `questions` (array). "
            "Each item: question, options (exactly 4 distinct strings), "
            "correct_option (0-3), explanation, difficulty (0-1 float), subcategory."
        )
        user = (
            f"Create {count} multiple-choice questions about: {topic}.\n"
            f"Difficulty label: {difficulty}.\n"
            f"Style: {style or 'engaging trivia'}.\n"
            f"Subcategory hint: {subcategory or 'general'}.\n"
            "Make distractors plausible. Explanations must teach, not just restate."
        )
        raw = await self._chat(
            model=settings.llm_model_generate,
            system=system,
            user=user,
            temperature=0.7,
        )
        payload = _extract_json(raw)
        items = payload.get("questions") if isinstance(payload, dict) else payload
        drafts: list[GeneratedQuestionDraft] = []
        for item in items or []:
            options = list(item.get("options") or [])
            if len(options) != 4:
                continue
            drafts.append(
                GeneratedQuestionDraft(
                    question=str(item.get("question") or "").strip(),
                    options=[str(o).strip() for o in options],
                    correct_option=_parse_correct_option(item.get("correct_option", 0), options),
                    explanation=str(item.get("explanation") or "").strip(),
                    subcategory=item.get("subcategory") or subcategory,
                    difficulty=float(item.get("difficulty", 0.5)),
                    source="openai",
                    meta={"style": style},
                )
            )
        return drafts

    async def validate_questions(
        self,
        drafts: list[GeneratedQuestionDraft],
    ) -> list[ValidationResult]:
        if not drafts:
            return []
        system = (
            "You are a strict quiz quality reviewer. Return JSON with key `results` "
            "(array aligned to input order). Each item: approved (bool), quality_score "
            "(0-100), reasons (string array), difficulty (0-1)."
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

    async def classify_topic(self, prompt: str) -> dict[str, Any]:
        system = (
            "Classify a custom quiz request. Return JSON: subject (short title), "
            "category, confidence (0-1)."
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
                return payload
        except Exception as exc:  # noqa: BLE001
            logger.exception("openai_classify_failed", error=str(exc))
        return {
            "subject": prompt.strip()[:80] or "General Knowledge",
            "category": "custom",
            "confidence": 0.4,
        }

    async def teach(
        self,
        *,
        question: str,
        correct_option: str,
        user_option: str,
        explanation: str,
    ) -> dict[str, str]:
        system = (
            "You are a friendly tutor for a quiz game. Return JSON with keys: "
            "why_correct, why_wrong, key_concept, memorable_fact. Keep each under 2 sentences."
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
