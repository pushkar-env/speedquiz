"""Score a mock-test attempt.

Pure functions over plain data -- no session, no I/O -- so the rules can be
tested directly and re-run months later when a board revises a key.

Every rule is read from the section's `marking` and `rules` JSON rather than
written in code here, which is what lets a new exam be a row in the database
instead of a release. The three shapes in use today:

    JEE Main   +4 / -1,  Section B scores only the best 5 attempted
    GATE       +1 / -1/3 and +2 / -2/3 for choice; NAT and MSQ carry no penalty
    NEET       +4 / -1

Numeric answers are compared with a tolerance, never for equality. A candidate
who computes 19.72 and types 20 has the question right, and a float equality
check would mark them wrong.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterable, Optional

#: Absolute tolerance used when a question does not carry its own.
DEFAULT_TOLERANCE = 0.01


@dataclass(frozen=True)
class ScoredQuestion:
    exam_question_id: str
    section_id: Optional[str]
    #: None means unattempted -- distinct from wrong, and usually worth 0
    #: rather than the negative.
    is_correct: Optional[bool]
    marks: float
    counted: bool = True


@dataclass
class SectionResult:
    section_id: Optional[str]
    name: str
    score: float = 0.0
    max_score: float = 0.0
    correct: int = 0
    incorrect: int = 0
    unattempted: int = 0
    #: Set when a `count_best_n` rule dropped some attempted questions.
    excluded: int = 0

    def as_dict(self) -> dict:
        return {
            "name": self.name,
            "score": round(self.score, 3),
            "max_score": round(self.max_score, 3),
            "correct": self.correct,
            "incorrect": self.incorrect,
            "unattempted": self.unattempted,
            "excluded": self.excluded,
        }


@dataclass
class AttemptResult:
    score: float = 0.0
    max_score: float = 0.0
    correct: int = 0
    incorrect: int = 0
    unattempted: int = 0
    per_question: list[ScoredQuestion] = field(default_factory=list)
    per_section: dict[str, SectionResult] = field(default_factory=dict)


def numeric_matches(
    given: Optional[float], spec: dict, *, tolerance: Optional[float] = None
) -> bool:
    """Compare a typed numeric answer against the key.

    A board that publishes an accepted range (GATE does) wins over a point
    value: the range is the board's own statement of what counts.
    """
    if given is None:
        return False

    low, high = spec.get("low"), spec.get("high")
    if low is not None and high is not None:
        return float(low) <= given <= float(high)

    expected = spec.get("value")
    if expected is None:
        return False
    expected = float(expected)

    window = tolerance if tolerance is not None else spec.get("tolerance", DEFAULT_TOLERANCE)
    window = float(window if window is not None else DEFAULT_TOLERANCE)
    if spec.get("mode") == "relative":
        window = abs(expected) * window
    return abs(given - expected) <= max(window, 1e-9)


def options_match(selected: Iterable[int], spec: dict, answer_type: str) -> bool:
    """Compare chosen options against the key.

    Multi-select is all-or-nothing here. Partial credit exists in some exams
    but the rule differs per board, so it belongs in `rules` rather than as a
    silent default that would be wrong for most of them.
    """
    chosen = sorted({int(i) for i in selected})
    if not chosen:
        return False

    if answer_type == "multi":
        expected = sorted({int(i) for i in (spec.get("mask") or [])})
        return bool(expected) and chosen == expected

    expected_option = spec.get("option")
    if expected_option is None:
        return False
    return len(chosen) == 1 and chosen[0] == int(expected_option)


def is_attempted(response: dict, answer_type: str) -> bool:
    """Whether the candidate actually answered.

    Marking a question for review without answering is not an attempt, which is
    why this looks at the answer rather than at the palette state.
    """
    if answer_type == "numeric":
        return response.get("numeric_value") is not None
    return bool(response.get("selected"))


def grade_question(
    *,
    response: Optional[dict],
    answer_type: str,
    answer_spec: dict,
    accepted_answers: Optional[list] = None,
    is_dropped: bool = False,
) -> Optional[bool]:
    """True / False / None (unattempted) for one question.

    A dropped question is awarded to everyone who attempted it -- that is what
    boards mean when they drop one. Someone who left it blank still gets
    nothing, which matches how the real result is computed.
    """
    if response is None or not is_attempted(response, answer_type):
        return None
    if is_dropped:
        return True

    candidates = [answer_spec] + list(accepted_answers or [])
    for spec in candidates:
        if not isinstance(spec, dict):
            continue
        if answer_type == "numeric":
            if numeric_matches(response.get("numeric_value"), spec):
                return True
        elif options_match(response.get("selected") or [], spec, answer_type):
            return True
    return False


def marks_for(verdict: Optional[bool], marking: dict, marks: float, negative: float) -> float:
    """Marks for one graded question.

    `marking` from the section wins when present; the per-question `marks` and
    `negative_marks` are the fallback, which is what GATE needs because its
    1-mark and 2-mark questions sit in the same section.
    """
    if verdict is None:
        return float(marking.get("unattempted", 0) or 0)
    if verdict:
        return float(marking.get("correct", marks) if "correct" in marking else marks)
    return float(marking.get("incorrect", negative) if "incorrect" in marking else negative)


def _apply_best_n(
    scored: list[ScoredQuestion], best_n: int
) -> list[ScoredQuestion]:
    """Keep only the best `best_n` *attempted* questions in a section.

    JEE Main's Section B prints ten questions and scores five. The real rule is
    "the first N attempted", but boards and every serious mock platform score
    the best N, because that is what a candidate expects and it never
    disadvantages them. Unattempted questions are always kept -- they score
    zero and dropping them would change the section's maximum.
    """
    attempted = [s for s in scored if s.is_correct is not None]
    if len(attempted) <= best_n:
        return scored

    ranked = sorted(attempted, key=lambda s: s.marks, reverse=True)
    keep = {id(s) for s in ranked[:best_n]}
    out: list[ScoredQuestion] = []
    for item in scored:
        if item.is_correct is None or id(item) in keep:
            out.append(item)
        else:
            out.append(
                ScoredQuestion(
                    exam_question_id=item.exam_question_id,
                    section_id=item.section_id,
                    is_correct=item.is_correct,
                    marks=0.0,
                    counted=False,
                )
            )
    return out


def score_attempt(
    *,
    questions: list[dict],
    responses: dict[str, dict],
    sections: dict[str, dict],
) -> AttemptResult:
    """Score a whole attempt.

    `questions` carries one dict per question in the paper with keys:
    id, section_id, answer_type, answer_spec, accepted_answers, is_dropped,
    marks, negative_marks. `responses` is keyed by exam_question_id.
    `sections` is keyed by section id and carries name / marking / rules.
    """
    result = AttemptResult()

    by_section: dict[Optional[str], list[ScoredQuestion]] = {}
    for question in questions:
        section_id = question.get("section_id")
        section = sections.get(section_id) or {}
        marking = section.get("marking") or {}

        verdict = grade_question(
            response=responses.get(question["id"]),
            answer_type=question.get("answer_type") or "single",
            answer_spec=question.get("answer_spec") or {},
            accepted_answers=question.get("accepted_answers"),
            is_dropped=bool(question.get("is_dropped")),
        )
        marks = marks_for(
            verdict,
            marking,
            float(question.get("marks") or 0),
            float(question.get("negative_marks") or 0),
        )
        by_section.setdefault(section_id, []).append(
            ScoredQuestion(
                exam_question_id=question["id"],
                section_id=section_id,
                is_correct=verdict,
                marks=marks,
            )
        )

    for section_id, scored in by_section.items():
        section = sections.get(section_id) or {}
        rules = section.get("rules") or {}
        best_n = rules.get("count_best_n")
        if isinstance(best_n, int) and best_n > 0:
            scored = _apply_best_n(scored, best_n)

        marking = section.get("marking") or {}
        per_correct = float(marking.get("correct") or 0)
        summary = SectionResult(
            section_id=section_id,
            name=section.get("name") or "Section",
        )
        counted_slots = best_n if isinstance(best_n, int) and best_n > 0 else len(scored)
        summary.max_score = counted_slots * (
            per_correct if per_correct else max((s.marks for s in scored), default=0)
        )

        for item in scored:
            result.per_question.append(item)
            if item.is_correct is None:
                summary.unattempted += 1
            elif not item.counted:
                summary.excluded += 1
            elif item.is_correct:
                summary.correct += 1
            else:
                summary.incorrect += 1
            summary.score += item.marks

        result.per_section[str(section_id)] = summary
        result.score += summary.score
        result.max_score += summary.max_score
        result.correct += summary.correct
        result.incorrect += summary.incorrect
        result.unattempted += summary.unattempted

    result.score = round(result.score, 3)
    result.max_score = round(result.max_score, 3)
    return result
