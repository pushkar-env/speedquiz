"""Maths canonicalisation.

The cases below are taken from the first real paper (JEE Main 2025, 22 Jan
Shift 1), where each one rendered as literal LaTeX source on a device.
"""

from app.services.latex_normalize import normalize_blocks, normalize_text


def norm(text: str) -> str:
    return normalize_text(text)[0]


class TestDelimiterConversion:
    def test_paren_delimiters_become_dollars(self):
        # The reported bug: Q63's options rendered as visible source.
        assert norm(r", \( \text{CH}_3 - \text{CHO} \)") == r", $\text{CH}_3 - \text{CHO}$"

    def test_bracket_delimiters_become_dollars(self):
        assert norm(r"\[ x^2 + y^2 = r^2 \]") == r"$x^2 + y^2 = r^2$"

    def test_double_dollar_becomes_single(self):
        assert norm(r"$$E = mc^2$$") == r"$E = mc^2$"

    def test_several_spans_in_one_string(self):
        out = norm(r"If \(a=1\) and \(b=2\) then \(a+b=3\)")
        assert out == r"If $a=1$ and $b=2$ then $a+b=3$"

    def test_already_correct_text_is_untouched(self):
        original = r"The value of $\frac{13}{32}MR^2$ is required."
        assert norm(original) == original

    def test_plain_prose_is_untouched(self):
        original = "Two balls are selected at random without replacement."
        assert norm(original) == original


class TestBareLatexWrapping:
    def test_whole_option_that_is_one_fraction(self):
        # Q15's options were literally "\frac{2}{3}" with no delimiters.
        assert norm(r"\frac{2}{3}") == r"$\frac{2}{3}$"

    def test_coefficient_is_pulled_into_the_run(self):
        # Q26: the leading "1" belongs to the expression, not to the prose.
        assert norm(r"1 \times 10^6 \text{ m/s}") == r"$1 \times 10^6 \text{ m/s}$"

    def test_maths_embedded_in_a_sentence_wraps_only_the_maths(self):
        out = norm(r"The speed is 3 \times 10^8 metres per second.")
        assert out.startswith("The speed is $")
        assert "metres per second." in out
        assert "$metres" not in out

    def test_greek_letters_are_wrapped(self):
        assert norm(r"\alpha + \beta") == r"$\alpha + \beta$"

    def test_a_backslash_that_is_not_a_maths_command_is_left_alone(self):
        original = r"Use the \emph markup sparingly."
        assert norm(original) == original

    def test_text_already_inside_dollars_is_not_double_wrapped(self):
        original = r"Given $\frac{1}{2}$ only."
        assert norm(original) == original
        assert original.count("$") == 2


class TestSafety:
    def test_unbalanced_braces_are_left_as_prose(self):
        # Wrapping this would hand the renderer a span it rejects outright.
        out, report = normalize_text(r"\frac{2}{3")
        assert out == r"\frac{2}{3"
        assert report.unbalanced_left_alone == 1

    def test_odd_dollar_count_is_reported_not_silently_fixed(self):
        _out, report = normalize_text(r"cost is $5 and rising")
        assert report.unbalanced_left_alone >= 1

    def test_escaped_dollar_is_not_a_delimiter(self):
        original = r"A price of \$40 per unit."
        assert norm(original) == original

    def test_empty_and_none_safe(self):
        assert norm("") == ""

    def test_cases_environment_survives_untouched(self):
        # Q24. Already correctly delimited; must not be re-wrapped or mangled.
        original = (
            r"Let $f(x) = \begin{cases} -3ax^2 - 2, & x < 1 \\ "
            r"a^2 + bx, & x \geq 1 \end{cases}$ be differentiable."
        )
        assert norm(original) == original


class TestBlocks:
    def test_figure_blocks_pass_through(self):
        blocks = [
            {"t": "text", "v": r"\frac{1}{2}"},
            {"t": "figure", "ref": "fig1"},
        ]
        out, report = normalize_blocks(blocks)
        assert out[0]["v"] == r"$\frac{1}{2}$"
        assert out[1] == {"t": "figure", "ref": "fig1"}
        assert report.runs_wrapped == 1

    def test_report_counts_across_blocks(self):
        blocks = [
            {"t": "text", "v": r"\( a = 1 \)"},
            {"t": "text", "v": r"\( b = 2 \)"},
        ]
        _out, report = normalize_blocks(blocks)
        assert report.delimiters_converted == 2
        assert report.changed

    def test_unchanged_content_reports_no_change(self):
        blocks = [{"t": "text", "v": "Plain prose."}]
        _out, report = normalize_blocks(blocks)
        assert not report.changed

    def test_non_dict_entries_are_dropped(self):
        out, _ = normalize_blocks([{"t": "text", "v": "ok"}, "junk", None])
        assert len(out) == 1


class TestWholeFragmentWrapping:
    """Fragments that are maths end to end get one span, not several.

    Locating where the maths "starts" inside an expression is guesswork, and
    guessing wrong puts the delimiters mid-formula — which renders worse than
    the undelimited source it replaced. Both cases below regressed exactly that
    way before the fragment rule existed.
    """

    def test_coordination_complex_keeps_its_brackets_inside(self):
        # Q68. A leading "[" belongs to the formula.
        assert normalize_text(r"[\mathrm{Fe(en)_3}]\mathrm{Cl_3}")[0] == (
            r"$[\mathrm{Fe(en)_3}]\mathrm{Cl_3}$"
        )

    def test_ordering_comparison_is_not_split_mid_token(self):
        # Q69. Previously became "(ii) < (i$) \equiv ($iii) < (iv)".
        assert normalize_text(r"(ii) < (i) \equiv (iii) < (iv)")[0] == (
            r"$(ii) < (i) \equiv (iii) < (iv)$"
        )

    def test_units_in_text_do_not_read_as_prose(self):
        assert normalize_text(r"16 \times 10^6 \text{ m/s}")[0] == (
            r"$16 \times 10^6 \text{ m/s}$"
        )

    def test_a_real_sentence_still_wraps_only_its_maths(self):
        out = normalize_text(r"The speed of light is 3 \times 10^8 metres per second.")[0]
        assert out.startswith("The speed of light is $")
        assert out.endswith("metres per second.")
