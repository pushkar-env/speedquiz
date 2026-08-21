"""Scoring rules for mock tests.

These run without a database on purpose: the rules are pure functions, and a
board revising a key months from now should be able to re-run them in
isolation.
"""

from app.services.exam_scoring import (
    grade_question,
    is_attempted,
    numeric_matches,
    options_match,
    score_attempt,
)

JEE_A = {
    "name": "Mathematics - Section A",
    "marking": {"correct": 4, "incorrect": -1, "unattempted": 0},
    "rules": {},
}
JEE_B = {
    "name": "Mathematics - Section B",
    "marking": {"correct": 4, "incorrect": -1, "unattempted": 0},
    "rules": {"count_best_n": 5},
}


def _mcq(qid: str, section: str = "A", answer: int = 0) -> dict:
    return {
        "id": qid,
        "section_id": section,
        "answer_type": "single",
        "answer_spec": {"option": answer},
        "marks": 4,
        "negative_marks": -1,
    }


def _numeric(qid: str, value: float, section: str = "B") -> dict:
    return {
        "id": qid,
        "section_id": section,
        "answer_type": "numeric",
        "answer_spec": {"value": value, "tolerance": 0.01, "mode": "absolute"},
        "marks": 4,
        "negative_marks": -1,
    }


class TestNumericMatching:
    def test_exact_value_matches(self):
        assert numeric_matches(20.0, {"value": 20})

    def test_within_tolerance_matches(self):
        assert numeric_matches(20.005, {"value": 20, "tolerance": 0.01})

    def test_outside_tolerance_does_not(self):
        assert not numeric_matches(20.5, {"value": 20, "tolerance": 0.01})

    def test_accepted_range_wins_over_point_value(self):
        # GATE publishes ranges; the board's own range is the answer.
        spec = {"value": 1.5, "low": 1.4, "high": 1.6, "tolerance": 0.001}
        assert numeric_matches(1.42, spec)
        assert not numeric_matches(1.7, spec)

    def test_relative_tolerance_scales_with_magnitude(self):
        spec = {"value": 2000, "tolerance": 0.01, "mode": "relative"}
        assert numeric_matches(2015, spec)
        assert not numeric_matches(2400, spec)

    def test_no_answer_is_not_a_match(self):
        assert not numeric_matches(None, {"value": 20})


class TestOptionMatching:
    def test_single_correct(self):
        assert options_match([2], {"option": 2}, "single")

    def test_single_wrong(self):
        assert not options_match([1], {"option": 2}, "single")

    def test_single_rejects_multiple_selections(self):
        assert not options_match([1, 2], {"option": 2}, "single")

    def test_multi_needs_the_exact_set(self):
        assert options_match([0, 2], {"mask": [0, 2]}, "multi")
        assert options_match([2, 0], {"mask": [0, 2]}, "multi")

    def test_multi_rejects_a_subset(self):
        # All-or-nothing: partial credit differs per board and belongs in rules.
        assert not options_match([0], {"mask": [0, 2]}, "multi")

    def test_multi_rejects_a_superset(self):
        assert not options_match([0, 1, 2], {"mask": [0, 2]}, "multi")


class TestAttemptDetection:
    def test_marked_for_review_without_an_answer_is_not_an_attempt(self):
        assert not is_attempted({"selected": [], "numeric_value": None}, "single")

    def test_numeric_zero_counts_as_an_attempt(self):
        # 0 is a legitimate answer; a falsy check here would silently discard it.
        assert is_attempted({"numeric_value": 0.0}, "numeric")

    def test_option_zero_counts_as_an_attempt(self):
        assert is_attempted({"selected": [0]}, "single")


class TestGrading:
    def test_unattempted_grades_as_none(self):
        assert grade_question(
            response=None, answer_type="single", answer_spec={"option": 1}
        ) is None

    def test_dropped_question_is_awarded_to_anyone_who_attempted(self):
        verdict = grade_question(
            response={"selected": [3]},
            answer_type="single",
            answer_spec={"option": 1},
            is_dropped=True,
        )
        assert verdict is True

    def test_dropped_question_gives_nothing_to_a_blank(self):
        verdict = grade_question(
            response={"selected": []},
            answer_type="single",
            answer_spec={"option": 1},
            is_dropped=True,
        )
        assert verdict is None

    def test_revised_key_accepts_the_added_answer(self):
        verdict = grade_question(
            response={"selected": [2]},
            answer_type="single",
            answer_spec={"option": 1},
            accepted_answers=[{"option": 2}],
        )
        assert verdict is True


class TestScoreAttempt:
    def test_jee_marking(self):
        questions = [_mcq("q1", answer=0), _mcq("q2", answer=1), _mcq("q3", answer=2)]
        responses = {
            "q1": {"selected": [0]},          # correct   +4
            "q2": {"selected": [3]},          # wrong     -1
            # q3 unattempted                              0
        }
        result = score_attempt(
            questions=questions, responses=responses, sections={"A": JEE_A}
        )
        assert result.score == 3
        assert (result.correct, result.incorrect, result.unattempted) == (1, 1, 1)

    def test_section_b_counts_only_the_best_five(self):
        # Ten numerical questions, all ten attempted, seven right.
        questions = [_numeric(f"n{i}", i) for i in range(10)]
        responses = {f"n{i}": {"numeric_value": float(i)} for i in range(7)}
        responses.update({f"n{i}": {"numeric_value": 999.0} for i in range(7, 10)})

        result = score_attempt(
            questions=questions, responses=responses, sections={"B": JEE_B}
        )
        # Best five are five correct answers: 5 x 4 = 20. The other five
        # attempted questions are excluded rather than penalised.
        assert result.score == 20
        section = result.per_section["B"]
        assert section.correct == 5
        assert section.excluded == 5
        assert section.max_score == 20

    def test_section_b_penalises_when_fewer_than_five_are_right(self):
        questions = [_numeric(f"n{i}", i) for i in range(10)]
        # Two right, three wrong, five untouched.
        responses = {"n0": {"numeric_value": 0.0}, "n1": {"numeric_value": 1.0}}
        responses.update({f"n{i}": {"numeric_value": 999.0} for i in (2, 3, 4)})

        result = score_attempt(
            questions=questions, responses=responses, sections={"B": JEE_B}
        )
        # 2 x 4 - 3 x 1 = 5. All five attempts count because there are only five.
        assert result.score == 5
        assert result.per_section["B"].excluded == 0

    def test_gate_partial_negative_marking(self):
        section = {
            "name": "Technical",
            "marking": {"correct": 2, "incorrect": -2 / 3, "unattempted": 0},
            "rules": {},
        }
        questions = [
            {"id": "g1", "section_id": "T", "answer_type": "single",
             "answer_spec": {"option": 0}, "marks": 2, "negative_marks": -2 / 3},
            {"id": "g2", "section_id": "T", "answer_type": "single",
             "answer_spec": {"option": 0}, "marks": 2, "negative_marks": -2 / 3},
        ]
        responses = {"g1": {"selected": [0]}, "g2": {"selected": [1]}}
        result = score_attempt(
            questions=questions, responses=responses, sections={"T": section}
        )
        assert round(result.score, 3) == round(2 - 2 / 3, 3)

    def test_nat_has_no_penalty_for_a_wrong_answer(self):
        section = {
            "name": "NAT",
            "marking": {"correct": 1, "incorrect": 0, "unattempted": 0},
            "rules": {},
        }
        questions = [{
            "id": "n1", "section_id": "N", "answer_type": "numeric",
            "answer_spec": {"value": 4.2, "tolerance": 0.1},
            "marks": 1, "negative_marks": 0,
        }]
        result = score_attempt(
            questions=questions,
            responses={"n1": {"numeric_value": 9.9}},
            sections={"N": section},
        )
        assert result.score == 0
        assert result.incorrect == 1

    def test_a_blank_paper_scores_zero_not_negative(self):
        questions = [_mcq(f"q{i}", answer=0) for i in range(5)]
        result = score_attempt(
            questions=questions, responses={}, sections={"A": JEE_A}
        )
        assert result.score == 0
        assert result.unattempted == 5

    def test_full_marks_matches_the_section_maximum(self):
        questions = [_mcq(f"q{i}", answer=1) for i in range(20)]
        responses = {f"q{i}": {"selected": [1]} for i in range(20)}
        result = score_attempt(
            questions=questions, responses=responses, sections={"A": JEE_A}
        )
        assert result.score == 80
        assert result.max_score == 80
