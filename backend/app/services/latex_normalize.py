"""Canonicalise the maths in ingested question content.

Extraction records what the model wrote, faithfully. This normalises it on the
way into the database, which is the one choke point every question passes
through — so there is a single implementation rather than one in the pipeline,
one in the importer and a third in the client.

Three problems show up in practice, all seen on the first real paper:

1. **The other inline delimiters.** The model is asked for ``$...$`` and
   sometimes writes ``\\(...\\)``, ``\\[...\\]`` or ``$$...$$`` anyway. The
   client splits on ``$``, so the rest render as literal source — the reported
   ``, \\( \\text{CH}_3 - \\text{CHO} \\)``.

2. **Bare LaTeX with no delimiters at all.** An option whose entire text is
   ``\\frac{2}{3}``. Nothing marks it as maths, so it renders as source too.

3. **Unbalanced delimiters**, usually a dropped closing ``$``. Left alone the
   client swallows the rest of the sentence into a maths span.

The rule throughout: never change what the maths *says*, only how it is marked.
A transformation that cannot be made safely is left alone and reported, because
a question that renders slightly wrong is recoverable and one that has been
silently rewritten is not.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

#: Commands that mean "this is maths" strongly enough to wrap an undelimited
#: run. Deliberately conservative: a stray ``\n`` in prose must not trigger it.
MATH_COMMAND = re.compile(
    r"\\(?:frac|dfrac|tfrac|sqrt|text|mathrm|mathbb|mathcal|times|div|cdot|pm|mp"
    r"|leq|geq|neq|approx|equiv|propto|infty|partial|nabla|sum|prod|int|oint"
    r"|lim|log|ln|sin|cos|tan|cot|sec|csc|sinh|cosh|tanh|exp|deg|circ"
    r"|alpha|beta|gamma|delta|epsilon|varepsilon|zeta|eta|theta|vartheta|iota"
    r"|kappa|lambda|mu|nu|xi|pi|rho|sigma|tau|upsilon|phi|varphi|chi|psi|omega"
    r"|Gamma|Delta|Theta|Lambda|Xi|Pi|Sigma|Upsilon|Phi|Psi|Omega"
    r"|rightarrow|leftarrow|Rightarrow|Leftarrow|leftrightarrow|to|mapsto"
    r"|vec|hat|bar|dot|ddot|overline|underline|begin|end|left|right"
    r"|in|notin|subset|supset|cup|cap|forall|exists|angle|perp|parallel)\b"
)

#: A single unescaped dollar.
DOLLAR = re.compile(r"(?<!\\)\$")

#: Characters that can sit inside a maths run without ending it.
_MATH_FILLER = set(" \t0123456789+-*/=<>^_(),.;:|[]{}'\\")


@dataclass
class NormalizeReport:
    delimiters_converted: int = 0
    runs_wrapped: int = 0
    unbalanced_left_alone: int = 0
    notes: list[str] = field(default_factory=list)

    @property
    def changed(self) -> bool:
        return bool(self.delimiters_converted or self.runs_wrapped)

    def merge(self, other: "NormalizeReport") -> None:
        self.delimiters_converted += other.delimiters_converted
        self.runs_wrapped += other.runs_wrapped
        self.unbalanced_left_alone += other.unbalanced_left_alone
        self.notes.extend(other.notes)


def _convert_delimiters(text: str, report: NormalizeReport) -> str:
    """``\\(..\\)``, ``\\[..\\]`` and ``$$..$$`` all become ``$..$``.

    Display maths is folded to inline on purpose: a question stem is a running
    sentence, and a centred display block inside it reads as a layout bug on a
    360dp screen.
    """
    def _tighten(match: re.Match) -> str:
        # The padding inside `\( x \)` is the delimiter's, not the maths';
        # carrying it into `$ x $` leaves a visible gap either side of every
        # formula.
        body = match.group(1)
        return f"${body.strip()}$" if body.strip() else ""

    def _paired(pattern: str) -> None:
        nonlocal text
        while True:
            replaced, count = re.subn(pattern, _tighten, text, count=1, flags=re.S)
            if not count:
                return
            text = replaced
            report.delimiters_converted += 1

    _paired(r"\\\((.*?)\\\)")
    _paired(r"\\\[(.*?)\\\]")

    # $$...$$ -> $...$. Done after the others so a converted \[..\] cannot be
    # re-matched here.
    while True:
        replaced, count = re.subn(r"\$\$(.+?)\$\$", _tighten, text, count=1, flags=re.S)
        if not count:
            break
        text = replaced
        report.delimiters_converted += 1

    return text


def _outside_math_spans(text: str) -> list[tuple[int, int]]:
    """Index ranges that sit *outside* any ``$...$`` span.

    An unpaired trailing ``$`` leaves the tail unmatched, which is the correct
    reading: everything after it is already inside a (broken) span and must not
    be wrapped again.
    """
    positions = [m.start() for m in DOLLAR.finditer(text)]
    spans: list[tuple[int, int]] = []
    cursor = 0
    for index in range(0, len(positions) - 1, 2):
        spans.append((cursor, positions[index]))
        cursor = positions[index + 1] + 1
    if len(positions) % 2 == 0:
        spans.append((cursor, len(text)))
    return [(a, b) for a, b in spans if b > a]


def _wrap_runs(text: str, report: NormalizeReport) -> str:
    """Wrap undelimited maths runs in ``$...$``.

    A run starts at a maths command and extends over the tokens that plausibly
    belong to the same expression — braces, digits, operators, sub/superscripts
    — stopping at the first word of ordinary prose. That keeps
    ``1 \\times 10^6 \\text{ m/s}`` whole while leaving the sentence around it
    untouched.
    """
    out: list[str] = []
    cursor = 0

    for start, end in _outside_math_spans(text):
        out.append(text[cursor:start])
        segment = text[start:end]
        out.append(_wrap_segment(segment, report))
        cursor = end
    out.append(text[cursor:])
    return "".join(out)


#: Three or more ordinary words in a row — the signal that a fragment is a
#: sentence rather than an expression.
_PROSE_RUN = re.compile(r"\b[A-Za-z]{2,}\s+[A-Za-z]{2,}\s+[A-Za-z]{2,}\b")


def _has_prose(text: str) -> bool:
    """Whether this fragment reads as a sentence.

    Commands and brace groups are removed first, so ``\\text{ m/s }`` and
    ``\\mathrm{Fe(en)_3}`` cannot be mistaken for English.
    """
    stripped = re.sub(r"\\[A-Za-z]+", " ", text)
    stripped = re.sub(r"\{[^{}]*\}", " ", stripped)
    return bool(_PROSE_RUN.search(stripped))


def _wrap_segment(segment: str, report: NormalizeReport) -> str:
    match = MATH_COMMAND.search(segment)
    if not match:
        return segment

    # An expression with no sentence in it is maths end to end, so wrap the
    # whole fragment. Trying to find where the maths "starts" inside something
    # like `[\mathrm{Fe(en)_3}]\mathrm{Cl_3}` or `(ii) < (i) \equiv (iii)` puts
    # the delimiters in the wrong place and produces `[$\mathrm{...}]...$` —
    # worse than the undelimited source it replaced.
    body = segment.strip()
    if body and not _has_prose(segment) and _balanced_braces(body):
        lead = segment[: len(segment) - len(segment.lstrip())]
        trail = segment[len(segment.rstrip()) :]
        report.runs_wrapped += 1
        return f"{lead}${body}${trail}"

    pieces: list[str] = []
    cursor = 0
    while match:
        run_start = match.start()
        # Pull in a leading numeric/operator prefix: in "1 \times 10^6" the
        # coefficient belongs to the expression, not to the prose.
        while run_start > cursor and segment[run_start - 1] in " \t":
            probe = run_start - 1
            while probe > cursor and segment[probe - 1] in " \t":
                probe -= 1
            token_end = probe
            while probe > cursor and segment[probe - 1] in "0123456789.^_{}()+-*/=":
                probe -= 1
            if probe == token_end:
                break
            run_start = probe

        run_end = _run_end(segment, match.end())
        pieces.append(segment[cursor:run_start])
        raw = segment[run_start:run_end]
        body = raw.strip()
        if body and _balanced_braces(body):
            # Whitespace the run swallowed at either end belongs to the
            # sentence, not the span. Dropping it welds the formula to the next
            # word: "$3 \times 10^8$metres".
            lead = raw[: len(raw) - len(raw.lstrip())]
            trail = raw[len(raw.rstrip()) :]
            pieces.append(f"{lead}${body}${trail}")
            report.runs_wrapped += 1
        else:
            # Unbalanced braces would produce a span the renderer rejects;
            # leaving it as prose at least shows the student the source.
            pieces.append(segment[run_start:run_end])
            report.unbalanced_left_alone += 1
            report.notes.append(f"unbalanced braces, left as text: {body[:60]!r}")
        cursor = run_end
        match = MATH_COMMAND.search(segment, cursor)

    pieces.append(segment[cursor:])
    return "".join(pieces)


def _run_end(segment: str, index: int) -> int:
    """Where a maths run stops.

    Walks forward over filler and balanced braces, and stops at the first run
    of alphabetic characters that is not part of a command or a brace group —
    that is where the expression ends and the sentence resumes.
    """
    depth = 0
    while index < len(segment):
        char = segment[index]
        if char == "\\" and index + 1 < len(segment):
            # A command: consume the backslash and its name.
            index += 1
            while index < len(segment) and segment[index].isalpha():
                index += 1
            continue
        if char == "{":
            depth += 1
            index += 1
            continue
        if char == "}":
            if depth == 0:
                return index
            depth -= 1
            index += 1
            continue
        if depth > 0:
            index += 1
            continue
        if char.isalpha():
            # A single letter is a variable; a word is prose.
            word_end = index
            while word_end < len(segment) and segment[word_end].isalpha():
                word_end += 1
            if word_end - index > 1:
                return index
            index = word_end
            continue
        if char in _MATH_FILLER:
            index += 1
            continue
        return index
    return index


def _balanced_braces(text: str) -> bool:
    depth = 0
    index = 0
    while index < len(text):
        if text[index] == "\\" and index + 1 < len(text):
            index += 2
            continue
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth < 0:
                return False
        index += 1
    return depth == 0


def normalize_text(text: str) -> tuple[str, NormalizeReport]:
    """Canonicalise one string of question text."""
    report = NormalizeReport()
    if not text:
        return text, report

    result = _convert_delimiters(text, report)
    result = _wrap_runs(result, report)

    if len(DOLLAR.findall(result)) % 2 != 0:
        # An odd count means a dropped delimiter somewhere. Dropping the stray
        # one is better than shipping a span that eats the rest of the
        # sentence, and the client falls back to prose either way.
        report.unbalanced_left_alone += 1
        report.notes.append(f"odd number of $ after normalising: {result[:80]!r}")

    return result, report


def normalize_blocks(blocks: list[dict]) -> tuple[list[dict], NormalizeReport]:
    """Canonicalise a content block list, leaving figure blocks untouched."""
    report = NormalizeReport()
    out: list[dict] = []
    for block in blocks or []:
        if not isinstance(block, dict):
            continue
        if block.get("t") != "text":
            out.append(block)
            continue
        text, sub = normalize_text(str(block.get("v", "")))
        report.merge(sub)
        out.append({**block, "v": text})
    return out, report
