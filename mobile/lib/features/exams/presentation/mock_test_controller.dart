import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/features/exams/data/exam_repository.dart';
import 'package:speedquiz/features/exams/domain/exam_models.dart';

/// How often a delta batch is flushed to the server.
///
/// The candidate's answer sheet lives on the device during the test; this is
/// only a checkpoint. Writing on every tap would be hundreds of round trips per
/// attempt for no benefit — and would make the test unusable on a patchy
/// connection, which is where these tests are actually taken.
const _syncInterval = Duration(seconds: 25);

/// Local clock tick. Purely cosmetic — the deadline is the server's.
const _tickInterval = Duration(seconds: 1);

class MockTestState {
  const MockTestState({
    required this.manifest,
    required this.attempt,
    required this.responses,
    required this.index,
    required this.remaining,
    this.pendingSync = 0,
    this.syncing = false,
    this.lastSyncError,
    this.submitting = false,
  });

  final PaperManifest manifest;
  final MockAttempt attempt;
  final Map<String, QuestionResponse> responses;
  final int index;
  final Duration remaining;

  /// How many edits have not reached the server yet. Surfaced so the candidate
  /// can see that work is saved locally even while offline.
  final int pendingSync;
  final bool syncing;
  final String? lastSyncError;
  final bool submitting;

  ExamQuestion get question => manifest.questions[index];

  QuestionResponse responseFor(String id) =>
      responses[id] ?? QuestionResponse(examQuestionId: id);

  QuestionResponse get current => responseFor(question.id);

  int get answeredCount =>
      responses.values.where((r) => r.state.isAnswered).length;

  int get markedCount => responses.values.where((r) => r.state.isMarked).length;

  bool get isLastQuestion => index >= manifest.questions.length - 1;

  MockTestState copyWith({
    MockAttempt? attempt,
    Map<String, QuestionResponse>? responses,
    int? index,
    Duration? remaining,
    int? pendingSync,
    bool? syncing,
    String? lastSyncError,
    bool clearSyncError = false,
    bool? submitting,
  }) => MockTestState(
    manifest: manifest,
    attempt: attempt ?? this.attempt,
    responses: responses ?? this.responses,
    index: index ?? this.index,
    remaining: remaining ?? this.remaining,
    pendingSync: pendingSync ?? this.pendingSync,
    syncing: syncing ?? this.syncing,
    lastSyncError: clearSyncError
        ? null
        : (lastSyncError ?? this.lastSyncError),
    submitting: submitting ?? this.submitting,
  );
}

/// Drives one live mock test.
///
/// Local-first: every interaction writes to memory immediately and the network
/// is a background concern. The one thing that is never local is the clock —
/// `remaining` is re-anchored to the server's answer on every sync, so a device
/// with a wrong or tampered clock cannot buy extra time.
class MockTestController extends StateNotifier<MockTestState> {
  MockTestController(
    this._repository, {
    required PaperManifest manifest,
    required MockAttempt attempt,
  }) : super(
         MockTestState(
           manifest: manifest,
           attempt: attempt,
           responses: {for (final r in attempt.responses) r.examQuestionId: r},
           index: 0,
           remaining: Duration(milliseconds: attempt.remainingMs),
         ),
       ) {
    _revision = attempt.responses.fold<int>(
      0,
      (highest, r) => r.clientRevision > highest ? r.clientRevision : highest,
    );
    _markVisited();
    _ticker = Timer.periodic(_tickInterval, (_) => _tick());
    _syncTimer = Timer.periodic(_syncInterval, (_) => flush());
  }

  final ExamRepository _repository;
  Timer? _ticker;
  Timer? _syncTimer;

  /// Monotonic, so the server can discard an out-of-order retry.
  int _revision = 0;

  /// Question ids edited since the last successful flush.
  final Set<String> _dirty = {};

  /// When the current question was opened, for per-question timing.
  DateTime _openedAt = DateTime.now();

  /// Fires when the clock runs out, so the screen can submit and navigate.
  VoidCallback? onTimeExpired;

  void _tick() {
    final next = state.remaining - _tickInterval;
    if (next <= Duration.zero) {
      state = state.copyWith(remaining: Duration.zero);
      _ticker?.cancel();
      onTimeExpired?.call();
      return;
    }
    state = state.copyWith(remaining: next);
  }

  void _markVisited() {
    final question = state.question;
    final existing = state.responseFor(question.id);
    if (existing.state != ResponseState.notVisited) return;
    _write(
      existing.copyWith(
        state: ResponseState.notAnswered,
        visitCount: existing.visitCount + 1,
      ),
    );
  }

  /// Bank the time spent on the question being left.
  void _bankTime() {
    final question = state.question;
    final existing = state.responseFor(question.id);
    final elapsed = DateTime.now().difference(_openedAt).inMilliseconds;
    if (elapsed <= 0) return;
    _write(existing.copyWith(timeSpentMs: existing.timeSpentMs + elapsed));
    _openedAt = DateTime.now();
  }

  void _write(QuestionResponse response) {
    _revision += 1;
    final updated = response.copyWith(clientRevision: _revision);
    state = state.copyWith(
      responses: {...state.responses, updated.examQuestionId: updated},
      pendingSync:
          _dirty.length + (_dirty.contains(updated.examQuestionId) ? 0 : 1),
    );
    _dirty.add(updated.examQuestionId);
  }

  void goTo(int index) {
    if (index < 0 || index >= state.manifest.questions.length) return;
    if (index == state.index) return;
    _bankTime();
    state = state.copyWith(index: index);
    _openedAt = DateTime.now();
    _markVisited();
  }

  void next() => goTo(state.index + 1);

  void previous() => goTo(state.index - 1);

  void selectOption(int optionIndex) {
    final question = state.question;
    final existing = state.responseFor(question.id);

    List<int> selected;
    if (question.answerType == ExamAnswerType.multi) {
      selected = [...existing.selected];
      selected.contains(optionIndex)
          ? selected.remove(optionIndex)
          : selected.add(optionIndex);
      selected.sort();
    } else {
      // Tapping the chosen option again clears it. On the real interface that
      // is what "Clear Response" does, and having it on the option itself
      // saves a trip to the toolbar.
      selected = existing.selected.contains(optionIndex) ? [] : [optionIndex];
    }

    _write(
      existing.copyWith(
        selected: selected,
        state: _stateFor(
          hasAnswer: selected.isNotEmpty,
          marked: existing.state.isMarked,
        ),
      ),
    );
  }

  void setNumeric(String raw) {
    final question = state.question;
    final existing = state.responseFor(question.id);
    final trimmed = raw.trim();
    final parsed = trimmed.isEmpty ? null : double.tryParse(trimmed);

    _write(
      existing.copyWith(
        numericValue: parsed,
        numericRaw: trimmed.isEmpty ? null : trimmed,
        clearNumeric: trimmed.isEmpty,
        state: _stateFor(
          hasAnswer: parsed != null,
          marked: existing.state.isMarked,
        ),
      ),
    );
  }

  void clearResponse() {
    final existing = state.responseFor(state.question.id);
    _write(
      existing.copyWith(
        selected: const [],
        clearNumeric: true,
        state: _stateFor(hasAnswer: false, marked: existing.state.isMarked),
      ),
    );
  }

  /// Toggle the review flag without changing the answer.
  void toggleMark() {
    final existing = state.responseFor(state.question.id);
    _write(
      existing.copyWith(
        state: _stateFor(
          hasAnswer: existing.hasAnswer,
          marked: !existing.state.isMarked,
        ),
      ),
    );
  }

  static ResponseState _stateFor({
    required bool hasAnswer,
    required bool marked,
  }) {
    if (hasAnswer && marked) return ResponseState.answeredAndMarked;
    if (hasAnswer) return ResponseState.answered;
    if (marked) return ResponseState.marked;
    return ResponseState.notAnswered;
  }

  /// Push everything dirty. Safe to call at any time and from anywhere.
  Future<void> flush() async {
    if (state.syncing || _dirty.isEmpty) return;
    _bankTime();

    final batch = _dirty
        .map((id) => state.responses[id])
        .whereType<QuestionResponse>()
        .toList(growable: false);
    if (batch.isEmpty) return;

    final inFlight = batch.map((r) => r.examQuestionId).toSet();
    state = state.copyWith(syncing: true);
    try {
      final outcome = await _repository.syncResponses(state.attempt.id, batch);
      // Only clear what was actually sent: an edit made while the request was
      // in flight is still pending and must survive.
      _dirty.removeAll(inFlight);
      state = state.copyWith(
        syncing: false,
        pendingSync: _dirty.length,
        // Re-anchor to the server's clock; ours has been free-running.
        remaining: Duration(milliseconds: outcome.remainingMs),
        clearSyncError: true,
      );
      if (outcome.attemptClosed) {
        _ticker?.cancel();
        onTimeExpired?.call();
      }
    } catch (error) {
      // Keep the batch dirty and try again on the next tick. Nothing is lost:
      // the answers are in memory and the request is idempotent.
      state = state.copyWith(
        syncing: false,
        lastSyncError: 'Saved on this device. Will sync when back online.',
      );
      if (kDebugMode) debugPrint('mock test sync failed: $error');
    }
  }

  Future<AttemptResult> submit() async {
    state = state.copyWith(submitting: true);
    _ticker?.cancel();
    _syncTimer?.cancel();
    try {
      // Flush before submitting, or the last few answers score as blank.
      await flush();
      return await _repository.submit(state.attempt.id);
    } finally {
      state = state.copyWith(submitting: false);
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _syncTimer?.cancel();
    // Best-effort final flush; the attempt survives either way because the
    // server auto-submits anything past its deadline.
    unawaited(flush());
    super.dispose();
  }
}
