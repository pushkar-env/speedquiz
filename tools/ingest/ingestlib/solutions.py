"""Solve each question independently, then write the worked solution.

Two jobs in one stage, in a deliberate order.

**First, solve blind.** The model is given the question and the options but not
the official answer, and told to work it out. Comparing that answer against the
printed key is the single highest-signal error detector in the pipeline: a
disagreement means either the transcription is wrong, the key is misaligned, or
the question is genuinely hard -- and all three are worth a human's attention.
Revealing the key first would destroy the signal, because a model shown an
answer will reliably justify it.

**Then, write the solution.** The key is authoritative, so when the blind solve
agrees, its working is kept. When it disagrees, a second call is made *with* the
correct answer supplied, asking for a solution that reaches it. That second
solution is still marked for review -- it is the model reasoning toward a
conclusion it did not reach on its own, which is exactly when it confabulates.

Chapter tagging rides along in the same call. It is nearly free here and
retro-tagging thousands of questions later is not.
"""

from __future__ import annotations

import asyncio
import json
import re
from dataclasses import dataclass, field
from typing import Optional

import httpx

from .llm import LLMClient
from .profiles import SectionSpec
from .vision import ExtractedQuestion

SOLVE_SYSTEM = """You are a subject expert writing solutions for an exam-prep app
used by students preparing for Indian competitive exams.

Work the problem out properly before answering. Do not guess, and do not pattern
match against a remembered answer -- derive it.

Write the solution for a student who got the question wrong: state the idea or
formula it tests, then the steps, then the result.

Keep it under 120 words. Show the steps that carry the reasoning and skip the
arithmetic a student can do in their head. Do not restate the question, do not
narrate what you are about to do ("To solve this problem, we need to..."), and
do not add encouragement. Start with the substance.

All mathematics in LaTeX between single dollar signs, inline with the prose.
Chemistry formulae too: $\\mathrm{H_2SO_4}$. Output JSON only."""

SOLVE_USER = """{subject_line}

QUESTION {number}:
{question_text}
{options_text}
{figure_note}

Solve it. Then return:

{{
  "answer": {answer_shape},
  "confidence": "high" | "medium" | "low",
  "solution": "the worked solution, LaTeX inline",
  "key_concept": "the one idea this question tests, under 8 words",
  "chapter": "the syllabus chapter, e.g. 'Rotational Motion', 'Coordination Compounds'",
  "difficulty": 0.0 to 1.0
}}"""

REPAIR_SYSTEM = """You are a subject expert writing solutions for an exam-prep app.

You will be given a question and its OFFICIAL correct answer. The official answer
is authoritative and correct. Your job is to write the working that leads to it.

If you genuinely cannot derive the official answer, say so honestly in
"reconciliation" rather than inventing a step that does not follow. A flagged
question is fixable; a plausible wrong solution shipped to students is not.
Solutions that fail to reconcile are discarded, so there is no cost to
admitting it and a real cost to bluffing.

Keep the solution under 120 words, and start with the substance rather than
narrating your approach.

All mathematics in LaTeX between single dollar signs. Output JSON only."""

REPAIR_USER = """{subject_line}

QUESTION {number}:
{question_text}
{options_text}
{figure_note}

OFFICIAL CORRECT ANSWER: {official}

Return:

{{
  "solution": "working that reaches the official answer, LaTeX inline",
  "key_concept": "the one idea this question tests, under 8 words",
  "chapter": "the syllabus chapter",
  "difficulty": 0.0 to 1.0,
  "reconciliation": "if you could not derive the official answer, explain what does not follow; else null"
}}"""


@dataclass
class Solution:
    number: int
    #: What the model got on its own, before seeing the key.
    blind_answer: Optional[str] = None
    blind_confidence: str = "low"
    agrees_with_key: Optional[bool] = None
    solution: str = ""
    key_concept: str = ""
    chapter: str = ""
    difficulty: float = 0.5
    #: Set when the solution came from the repair pass.
    repaired: bool = False
    reconciliation: Optional[str] = None
    notes: list[str] = field(default_factory=list)

    @property
    def status(self) -> str:
        """How much this solution can be trusted, and therefore who sees it.

        * ``verified``  -- the blind solve reached the official answer on its
          own. The working and the answer corroborate each other.
        * ``needs_review`` -- the blind solve was wrong and the working was
          written afterwards, knowing the answer. Observed failure mode: an
          invalid intermediate step that still asserts the right result (one
          question in this very paper computes 0.004 x 0.0821 x 273 and calls
          it 45, which it is not). Plausible and wrong is worse than absent, so
          these are held back from students until a human signs them off.
        * ``withheld`` -- the model could not reach the official answer and
          said so. Nothing to show.

        The question itself is unaffected in every case: the answer comes from
        the official key, not from the model.
        """
        if not self.solution:
            return "withheld"
        if self.repaired or self.agrees_with_key is not True:
            return "needs_review"
        return "verified"


def _options_text(question: ExtractedQuestion) -> str:
    if not question.options:
        return "\n(This is a numeric-entry question: there are no options.)"
    lines = ["\nOPTIONS:"]
    for option in question.options:
        flat = " ".join(
            block.get("v", "") if block.get("t") == "text" else "[see figure]"
            for block in option.blocks
        ).strip()
        lines.append(f"  ({option.label}) {flat or '[figure only]'}")
    return "\n".join(lines)


def _question_text(question: ExtractedQuestion) -> str:
    parts = []
    for block in question.stem:
        if block.get("t") == "text":
            parts.append(block.get("v", ""))
        elif block.get("t") == "figure":
            parts.append(f"[FIGURE {block.get('ref')} appears here]")
    return "\n".join(p for p in parts if p.strip())


def _answer_shape(question: ExtractedQuestion) -> str:
    if question.answer_type == "numeric":
        return '"the numeric value only, as a plain number in a string"'
    if question.answer_type == "multi":
        return '"the correct option labels, comma separated, e.g. \\"1,3\\""'
    return '"the single correct option label, e.g. \\"3\\""'


def _figure_note(has_images: bool, question: ExtractedQuestion) -> str:
    refs = [b["ref"] for b in question.stem if b.get("t") == "figure"]
    for option in question.options:
        refs.extend(b["ref"] for b in option.blocks if b.get("t") == "figure")
    if not refs:
        return ""
    if has_images:
        return (
            f"\nThe attached image shows this question as printed, including "
            f"figure(s) {', '.join(refs)}. Read the figures from the image."
        )
    return (
        f"\nThis question depends on figure(s) {', '.join(refs)} which are not "
        "shown to you. If you cannot solve it without them, set confidence to "
        '"low" and say so.'
    )


def normalize_answer(raw: object, answer_type: str) -> Optional[str]:
    """Reduce an answer to a comparable token.

    Models answer "option 3", "(3)", "3", "13MR^2/32" and "13/32 MR^2" for the
    same thing, so a bare string comparison would report disagreement on most
    correct answers.
    """
    if raw is None:
        return None
    text = str(raw).strip()
    if not text:
        return None

    if answer_type == "numeric":
        match = re.search(r"-?\d+(?:\.\d+)?", text.replace(",", ""))
        return match.group(0) if match else None

    labels = re.findall(r"[1-4]|[A-Da-d]", text)
    if not labels:
        return None
    mapped = []
    for label in labels:
        if label.isalpha():
            mapped.append(str("abcd".index(label.lower()) + 1))
        else:
            mapped.append(label)
    unique = sorted(set(mapped))
    if answer_type == "multi":
        return ",".join(unique)
    return unique[0] if len(unique) == 1 else mapped[0]


def answers_match(model_answer: Optional[str], key_answer: Optional[str], answer_type: str,
                  tolerance: float = 0.01) -> bool:
    if model_answer is None or key_answer is None:
        return False
    if answer_type != "numeric":
        return model_answer == key_answer
    try:
        return abs(float(model_answer) - float(key_answer)) <= max(tolerance, 1e-9)
    except ValueError:
        return False


async def solve_question(
    http: httpx.AsyncClient,
    llm: LLMClient,
    *,
    model: str,
    question: ExtractedQuestion,
    section: Optional[SectionSpec],
    key_answer: Optional[str],
    crop_png: Optional[bytes],
) -> Solution:
    subject = section.subject if section else "General"
    has_figures = any(b.get("t") == "figure" for b in question.stem) or any(
        b.get("t") == "figure" for o in question.options for b in o.blocks
    )
    images = [crop_png] if (crop_png and has_figures) else None

    solution = Solution(number=question.number)

    payload = await llm.complete_json(
        http,
        model=model,
        system=SOLVE_SYSTEM,
        user=SOLVE_USER.format(
            subject_line=f"Subject: {subject}. Exam: Indian competitive entrance exam.",
            number=question.number,
            question_text=_question_text(question),
            options_text=_options_text(question),
            figure_note=_figure_note(bool(images), question),
            answer_shape=_answer_shape(question),
        ),
        images=images,
    )

    solution.blind_answer = normalize_answer(payload.get("answer"), question.answer_type)
    solution.blind_confidence = str(payload.get("confidence") or "low").lower()
    solution.solution = str(payload.get("solution") or "").strip()
    solution.key_concept = str(payload.get("key_concept") or "").strip()
    solution.chapter = str(payload.get("chapter") or "").strip()
    try:
        solution.difficulty = min(1.0, max(0.0, float(payload.get("difficulty", 0.5))))
    except (TypeError, ValueError):
        solution.difficulty = 0.5

    tolerance = section.tolerance if section else 0.01
    solution.agrees_with_key = answers_match(
        solution.blind_answer, key_answer, question.answer_type, tolerance
    )

    if solution.agrees_with_key or key_answer is None:
        return solution

    # Disagreement: the key wins, so ask again with it supplied.
    solution.notes.append(
        f"blind solve said {solution.blind_answer!r}, key says {key_answer!r}"
    )
    repair = await llm.complete_json(
        http,
        model=model,
        system=REPAIR_SYSTEM,
        user=REPAIR_USER.format(
            subject_line=f"Subject: {subject}. Exam: Indian competitive entrance exam.",
            number=question.number,
            question_text=_question_text(question),
            options_text=_options_text(question),
            figure_note=_figure_note(bool(images), question),
            official=key_answer,
        ),
        images=images,
    )
    solution.repaired = True
    solution.key_concept = str(repair.get("key_concept") or solution.key_concept).strip()
    solution.chapter = str(repair.get("chapter") or solution.chapter).strip()
    reconciliation = repair.get("reconciliation")
    solution.reconciliation = str(reconciliation).strip() if reconciliation else None

    if solution.reconciliation:
        # The model could not derive the official answer and said so. Whatever
        # working it produced ends somewhere other than the right answer, so
        # publishing it would teach the wrong method with the right label on
        # it. Withhold the solution and let the review queue route a human to
        # write one. The question itself is fine -- the key is authoritative.
        solution.solution = ""
        solution.notes.append("solution withheld: working did not reach the official answer")
    else:
        solution.solution = str(repair.get("solution") or "").strip()
    try:
        solution.difficulty = min(1.0, max(0.0, float(repair.get("difficulty", solution.difficulty))))
    except (TypeError, ValueError):
        pass
    return solution


async def solve_all(
    llm: LLMClient,
    *,
    model: str,
    questions: dict[int, ExtractedQuestion],
    sections,
    key_answers: dict[int, Optional[str]],
    crops: dict[int, "object"],
    concurrency: int = 4,
    on_done=None,
) -> dict[int, Solution]:
    semaphore = asyncio.Semaphore(concurrency)
    results: dict[int, Solution] = {}
    errors: dict[int, str] = {}

    async with httpx.AsyncClient() as http:
        async def run(number: int, question: ExtractedQuestion) -> None:
            async with semaphore:
                try:
                    crop_path = crops.get(number)
                    crop = crop_path.read_bytes() if crop_path else None
                    results[number] = await solve_question(
                        http, llm,
                        model=model,
                        question=question,
                        section=sections(number),
                        key_answer=key_answers.get(number),
                        crop_png=crop,
                    )
                except Exception as error:
                    errors[number] = f"{type(error).__name__}: {error}"
                if on_done:
                    on_done(number, number in results)

        await asyncio.gather(*(run(n, q) for n, q in sorted(questions.items())))

    if errors:
        for number, message in sorted(errors.items()):
            print(f"    ! Q{number} solve failed: {message}")
    return results
