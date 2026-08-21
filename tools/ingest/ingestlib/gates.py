"""Validation gates. A question that trips a blocking gate cannot be published.

Two severities, and the distinction matters:

* **block** -- the question is broken. It would render wrong, score wrong, or be
  unanswerable. It is held back from the paper entirely.
* **flag** -- the question is probably fine but a human should look. It still
  publishes; it just carries a review marker.

The gate that matters most is `figure_missing`. A question whose text says "as
shown in the figure" with no figure attached is unanswerable, and it is exactly
the failure sitting in the hand-written JSON this pipeline replaces: 14 of 75
questions there declared `diagram_required` and carried no image.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Optional

from .profiles import SectionSpec
from .solutions import Solution
from .vision import ExtractedQuestion

#: Phrases that mean the question cannot be answered without a picture.
FIGURE_REFERENCE = re.compile(
    r"\b(as shown|shown in (?:the )?figure|in the figure|following figure|"
    r"given figure|figure below|the diagram|shown below|following circuits?|"
    r"following graphs?|following curves?|following structures?)\b",
    re.I,
)
#: Page furniture that should never have survived into a question.
FURNITURE_LEAK = re.compile(
    r"(downloaded from|www\.|https?://|previous year paper|@\w+\.com|click here|"
    r"telegram|watch (?:the )?video)",
    re.I,
)
#: A LaTeX command we know the client renderer cannot handle. Anything here is
#: pre-rendered to SVG at publish time rather than shipped as live LaTeX.
UNSUPPORTED_LATEX = re.compile(r"\\(ce|chemfig|begin\{(?:tikzpicture|circuitikz)\})")

MIN_STEM_CHARS = 12


@dataclass
class Issue:
    code: str
    severity: str  # "block" | "flag"
    detail: str = ""

    def __str__(self) -> str:
        return f"[{self.severity}] {self.code}: {self.detail}" if self.detail else f"[{self.severity}] {self.code}"


@dataclass
class Verdict:
    number: int
    issues: list[Issue] = field(default_factory=list)

    @property
    def blocked(self) -> bool:
        return any(i.severity == "block" for i in self.issues)

    @property
    def flagged(self) -> bool:
        return bool(self.issues)

    def add(self, code: str, severity: str, detail: str = "") -> None:
        self.issues.append(Issue(code, severity, detail))


def _text_blocks(question: ExtractedQuestion) -> list[str]:
    """Every text block on its own.

    Checks that look at maths delimiters must run per block, never on the
    concatenation: joining `$e^{8/5}$` and `$e^{6/5}$` produces `$ $` in the
    middle, which reads as empty maths and is nothing of the sort.
    """
    parts = [b.get("v", "") for b in question.stem if b.get("t") == "text"]
    for option in question.options:
        parts.extend(b.get("v", "") for b in option.blocks if b.get("t") == "text")
    return [p for p in parts if p]


def _all_text(question: ExtractedQuestion) -> str:
    return " ".join(_text_blocks(question))


def _balanced_dollars(text: str) -> bool:
    # Escaped \$ is a literal dollar and must not count toward the pairing.
    return len(re.findall(r"(?<!\\)\$", text)) % 2 == 0


def check(
    question: ExtractedQuestion,
    *,
    section: Optional[SectionSpec],
    figure_count: int,
    key_answer: Optional[str],
    key_raw: Optional[str],
    solution: Optional[Solution],
) -> Verdict:
    verdict = Verdict(number=question.number)
    text = _all_text(question)
    stem_text = " ".join(b.get("v", "") for b in question.stem if b.get("t") == "text")

    # --- structure -------------------------------------------------------
    if len(stem_text.strip()) < MIN_STEM_CHARS:
        verdict.add("stem_too_short", "block", f"{len(stem_text.strip())} chars")

    if question.answer_type in {"single", "multi"}:
        if len(question.options) < 2:
            verdict.add("too_few_options", "block", f"{len(question.options)} options")
        elif len(question.options) != 4:
            verdict.add("unusual_option_count", "flag", f"{len(question.options)} options")

        flattened = []
        for option in question.options:
            flat = " ".join(
                b.get("v", "") if b.get("t") == "text" else f"<{b.get('ref')}>"
                for b in option.blocks
            ).strip().lower()
            flattened.append(flat)
        if any(not f for f in flattened):
            verdict.add("empty_option", "block")
        elif len(set(flattened)) < len(flattened):
            verdict.add("duplicate_options", "block")
    elif question.options:
        verdict.add("numeric_with_options", "flag", f"{len(question.options)} options present")

    # --- the answer key --------------------------------------------------
    if key_answer is None:
        verdict.add("no_answer_key", "block", "no key entry for this number")
    elif question.answer_type in {"single", "multi"}:
        labels = {o.label.lower() for o in question.options}
        numeric_labels = {str(i) for i in range(1, len(question.options) + 1)}
        if key_answer not in labels and key_answer not in numeric_labels:
            verdict.add("key_out_of_range", "block", f"key={key_raw!r}")

    # --- figures ---------------------------------------------------------
    placed = set(question.placed_refs)
    if FIGURE_REFERENCE.search(text) and not placed:
        verdict.add(
            "figure_missing", "block",
            "text refers to a figure but none is attached",
        )
    if figure_count and not placed:
        verdict.add("figure_unplaced", "flag", f"{figure_count} extracted, 0 placed")
    elif figure_count > len(placed):
        verdict.add(
            "figure_partially_placed", "flag",
            f"{figure_count} extracted, {len(placed)} placed",
        )

    # --- LaTeX -----------------------------------------------------------
    for block_text in _text_blocks(question):
        if not _balanced_dollars(block_text):
            verdict.add("unbalanced_math_delimiters", "block", block_text[:80])
            break
    for block_text in _text_blocks(question):
        if re.search(r"(?<!\\)\$\s*(?<!\\)\$", block_text):
            verdict.add("empty_math", "flag", block_text[:80])
            break
    if UNSUPPORTED_LATEX.search(text):
        verdict.add("unsupported_latex", "flag", "needs server-side SVG fallback")

    # --- leakage ---------------------------------------------------------
    leak = FURNITURE_LEAK.search(text)
    if leak:
        verdict.add("furniture_leak", "flag", leak.group(0))

    # --- solution and cross-check ----------------------------------------
    if solution is None:
        verdict.add("no_solution", "flag", "solve stage did not run or failed")
    else:
        if not solution.solution or len(solution.solution) < 20:
            verdict.add("solution_too_short", "flag")
        if solution.agrees_with_key is False:
            verdict.add(
                "key_disagreement", "flag",
                f"model said {solution.blind_answer!r}, key says {key_answer!r}",
            )
        if solution.reconciliation:
            # The working did not reach the official answer, so it was
            # withheld (see solutions.solve_question). The question still
            # publishes -- a correct question with no solution is useful; a
            # question with a confidently wrong solution is not.
            verdict.add(
                "solution_unreconciled", "flag",
                solution.reconciliation[:160],
            )
        if not _balanced_dollars(solution.solution):
            verdict.add("solution_unbalanced_math", "flag")

    if question.transcription_notes:
        verdict.add("transcription_note", "flag", question.transcription_notes[:160])

    return verdict


def summarize(verdicts: dict[int, Verdict]) -> dict:
    blocked = sorted(n for n, v in verdicts.items() if v.blocked)
    flagged = sorted(n for n, v in verdicts.items() if v.flagged and not v.blocked)
    counts: dict[str, int] = {}
    for verdict in verdicts.values():
        for issue in verdict.issues:
            counts[f"{issue.severity}:{issue.code}"] = counts.get(f"{issue.severity}:{issue.code}", 0) + 1
    return {
        "total": len(verdicts),
        "blocked": blocked,
        "flagged": flagged,
        "clean": len(verdicts) - len(blocked) - len(flagged),
        "by_code": dict(sorted(counts.items(), key=lambda kv: -kv[1])),
    }
