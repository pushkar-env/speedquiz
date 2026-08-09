"""Tests for option-order scoring helpers and timeout fairness."""

from app.services.quiz_service import (
    _client_correct_index,
    _normalize_option_order,
)


def test_normalize_option_order_coerces_strings():
    assert _normalize_option_order(["2", "0", "3", "1"]) == [2, 0, 3, 1]


def test_normalize_option_order_rejects_bad_perm():
    assert _normalize_option_order([0, 0, 1, 2]) == [0, 1, 2, 3]


def test_client_correct_index_maps_shuffle():
    order = [2, 0, 3, 1]
    # Original correct is 1 → appears at client index 3
    assert _client_correct_index(order, 1) == 3


def test_selection_mapping_matches_correctness():
    order = [3, 1, 0, 2]
    correct_original = 0
    client_correct = _client_correct_index(order, correct_original)
    selected_original = order[client_correct]
    assert selected_original == correct_original
