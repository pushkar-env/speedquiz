"""Exam profiles: the section layout and marking rules of each exam.

This is the declarative half of the design. Supporting a new exam should be a
new entry here plus a filename pattern in naming.py -- never a code change in
the pipeline or the scoring service.

A profile answers three questions the PDF itself does not:

* which question numbers belong to which subject and section
* whether a section is multiple-choice or numerical (which disambiguates the
  answer key -- see answerkey.py)
* what a right and a wrong answer are worth
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional


@dataclass(frozen=True)
class SectionSpec:
    name: str
    subject: str
    #: Inclusive 1-based question numbers, as printed on the paper.
    first: int
    last: int
    #: "single" (one correct option), "multi" (one or more), "numeric".
    answer_type: str
    marks_correct: float
    marks_incorrect: float
    marks_unattempted: float = 0.0
    #: JEE Main Section B: candidates attempt any 5 of 10 and only the best 5
    #: count. None means every question in the section is scored.
    count_best_n: Optional[int] = None
    #: Numerical answers are compared with a tolerance, never for equality.
    tolerance: float = 0.01
    tolerance_mode: str = "absolute"

    @property
    def count(self) -> int:
        return self.last - self.first + 1

    def contains(self, number: int) -> bool:
        return self.first <= number <= self.last

    def marking(self) -> dict:
        return {
            "correct": self.marks_correct,
            "incorrect": self.marks_incorrect,
            "unattempted": self.marks_unattempted,
        }

    def rules(self) -> dict:
        rules: dict = {}
        if self.count_best_n is not None:
            rules["count_best_n"] = self.count_best_n
        return rules


@dataclass(frozen=True)
class ExamProfile:
    slug: str
    name: str
    duration_minutes: int
    sections: list[SectionSpec]
    #: Languages the paper is actually set in. Drives the `language` column.
    languages: list[str] = field(default_factory=lambda: ["en"])

    @property
    def total_questions(self) -> int:
        return sum(s.count for s in self.sections)

    @property
    def total_marks(self) -> float:
        total = 0.0
        for section in self.sections:
            scored = section.count_best_n or section.count
            total += scored * section.marks_correct
        return total

    def section_for(self, number: int) -> Optional[SectionSpec]:
        for section in self.sections:
            if section.contains(number):
                return section
        return None


def _jee_main_2021_onwards() -> ExamProfile:
    """75 questions: three subjects, each 20 MCQ + 10 numerical (best 5 count).

    From 2021 the paper prints only 5 of the numerical questions in some
    sources and all 10 in others; `count_best_n` is what makes both score the
    same way, and the section ranges below are corrected against the actual
    question count at load time (see `fit_to_paper`).
    """
    sections: list[SectionSpec] = []
    for index, subject in enumerate(("Mathematics", "Physics", "Chemistry")):
        base = index * 25
        sections.append(SectionSpec(
            name=f"{subject} - Section A", subject=subject,
            first=base + 1, last=base + 20,
            answer_type="single", marks_correct=4, marks_incorrect=-1,
        ))
        sections.append(SectionSpec(
            name=f"{subject} - Section B", subject=subject,
            first=base + 21, last=base + 25,
            answer_type="numeric", marks_correct=4, marks_incorrect=-1,
            count_best_n=5, tolerance=0.01,
        ))
    return ExamProfile(
        slug="jee-main", name="JEE Main", duration_minutes=180,
        sections=sections, languages=["en", "hi"],
    )


def _neet() -> ExamProfile:
    sections = []
    for index, subject in enumerate(("Physics", "Chemistry", "Botany", "Zoology")):
        base = index * 50
        sections.append(SectionSpec(
            name=subject, subject=subject,
            first=base + 1, last=base + 50,
            answer_type="single", marks_correct=4, marks_incorrect=-1,
        ))
    return ExamProfile(
        slug="neet-ug", name="NEET UG", duration_minutes=200,
        sections=sections, languages=["en", "hi"],
    )


def _gate() -> ExamProfile:
    """GATE: 10 GA questions then 55 subject questions, mixed 1 and 2 mark.

    GATE mixes MCQ, MSQ and NAT within one section and does not print the split
    positionally, so the per-question answer type comes from the extraction
    pass and the marks come from the printed per-question mark value. The
    ranges here are the coarse fallback.
    """
    return ExamProfile(
        slug="gate", name="GATE", duration_minutes=180,
        sections=[
            SectionSpec(
                name="General Aptitude", subject="General Aptitude",
                first=1, last=10, answer_type="single",
                marks_correct=1, marks_incorrect=-1 / 3,
            ),
            SectionSpec(
                name="Technical", subject="Technical",
                first=11, last=65, answer_type="single",
                marks_correct=2, marks_incorrect=-2 / 3,
            ),
        ],
    )


PROFILES: dict[str, ExamProfile] = {
    "jee-main": _jee_main_2021_onwards(),
    "neet-ug": _neet(),
    "gate": _gate(),
}


def get_profile(exam_slug: str, question_count: int) -> Optional[ExamProfile]:
    profile = PROFILES.get(exam_slug)
    if profile is None:
        return None
    return fit_to_paper(profile, question_count)


def fit_to_paper(profile: ExamProfile, question_count: int) -> ExamProfile:
    """Scale a profile to the paper actually in hand.

    Section ranges are a template. A paper that prints 90 questions instead of
    75 has a different split, and silently mis-assigning the last fifteen to
    the wrong subject would corrupt every subject-wise statistic downstream.
    Rather than guess, refuse to stretch a profile that does not fit and let
    the caller fall back to a single generic section.
    """
    if profile.total_questions == question_count:
        return profile

    # Even split across the same subjects is the one stretch worth doing: it is
    # how JEE Main's own 90-question variant (with 10-question Section Bs)
    # differs from the 75-question one.
    subjects: list[str] = []
    for section in profile.sections:
        if section.subject not in subjects:
            subjects.append(section.subject)
    per_subject, remainder = divmod(question_count, len(subjects))
    if remainder or per_subject < 4:
        return profile

    mcq_share = profile.sections[0].count / (profile.total_questions / len(subjects))
    mcq_count = max(1, round(per_subject * mcq_share))
    numeric_count = per_subject - mcq_count

    template_a, template_b = profile.sections[0], profile.sections[1]
    sections: list[SectionSpec] = []
    for index, subject in enumerate(subjects):
        base = index * per_subject
        sections.append(SectionSpec(
            name=f"{subject} - Section A", subject=subject,
            first=base + 1, last=base + mcq_count,
            answer_type=template_a.answer_type,
            marks_correct=template_a.marks_correct,
            marks_incorrect=template_a.marks_incorrect,
        ))
        if numeric_count:
            sections.append(SectionSpec(
                name=f"{subject} - Section B", subject=subject,
                first=base + mcq_count + 1, last=base + per_subject,
                answer_type=template_b.answer_type,
                marks_correct=template_b.marks_correct,
                marks_incorrect=template_b.marks_incorrect,
                count_best_n=min(template_b.count_best_n or numeric_count, numeric_count),
                tolerance=template_b.tolerance,
            ))
    return ExamProfile(
        slug=profile.slug, name=profile.name,
        duration_minutes=profile.duration_minutes,
        sections=sections, languages=list(profile.languages),
    )


def generic_profile(question_count: int) -> ExamProfile:
    """Last resort for an exam we have no profile for.

    One section, no negative marking. Deliberately conservative: inventing a
    penalty the real exam does not have would make every score wrong.
    """
    return ExamProfile(
        slug="unknown", name="Unknown Exam", duration_minutes=180,
        sections=[SectionSpec(
            name="Section 1", subject="General",
            first=1, last=max(1, question_count),
            answer_type="single", marks_correct=1, marks_incorrect=0,
        )],
    )
