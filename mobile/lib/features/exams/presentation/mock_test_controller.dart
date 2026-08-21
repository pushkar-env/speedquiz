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
    this.questionRemaining,
    this.locked = const {},
    this.feedback = const {},
    this.checking = false,
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

  /// Time left on the current question, in Timed pacing. Null in Casual.
  final Duration? questionRemaining;

  /// Questions whose per-question timer ran out. They cannot be answered
  /// again — that is what makes Timed pacing train pacing rather than just
  /// display a number.
  final Set<String> locked;

  /// Practice mode: the revealed verdict per question, once checked.
  final Map<String, AnswerCheck> feedback;
  final bool checking;

  bool get isPractice => attempt.isPractice;

  bool get isTimed => attempt.isTimedPacing;

  AnswerCheck? get currentFeedback => feedback[question.id];

  bool get currentLocked =>
      locked.contains(question.id) || feedback.containsKey(question.id);

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
    Duration? questionRemaining,
    bool clearQuestionRemaining = false,
    Set<String>? locked,
    Map<String, AnswerCheck>? feedback,
    bool? checking,
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
    questionRemaining: clearQuestionRemaining
        ? null
        : (questionRemaining ?? this.questionRemaining),
    locked: locked ?? this.locked,
    feedback: feedback ?? this.feedback,
    checking: checking ?? this.checking,
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
    _resetQuestionClock();
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

  /// Fires when the paper clock runs out, so the screen can submit and navigate.
  VoidCallback? onTimeExpired;

  /// Fires when a per-question timer runs out, so the screen can say so. The
  /// advance and the lock have already happened by then.
  VoidCallback? onQuestionExpired;

  void _tick() {
    final next = state.remaining - _tickInterval;
    if (next <= Duration.zero) {
      state = state.copyWith(remaining: Duration.zero);
      _ticker?.cancel();
      onTimeExpired?.call();
      return;
    }
    state = state.copyWith(remaining: next);
    _tickQuestionClock();
  }

  /// Reset the per-question clock for whatever question is now on screen.
  ///
  /// A question already locked keeps a zero clock rather than getting a fresh
  /// one: returning to it must not hand back the time it ran out of.
  void _resetQuestionClock() {
    if (!state.isTimed) return;
    final limit = state.attempt.perQuestionSeconds ?? 0;
    if (limit <= 0) return;
    state = state.copyWith(
      questionRemaining: state.currentLocked
          ? Duration.zero
          : Duration(seconds: limit),
    );
  }

  void _tickQuestionClock() {
    if (!state.isTimed) return;
    final remaining = state.questionRemaining;
    if (remaining == null || remaining <= Duration.zero) return;

    final next = remaining - _tickInterval;
    if (next > Duration.zero) {
      state = state.copyWith(questionRemaining: next);
      return;
    }

    // Out of time. Lock the question and move on — the whole point of Timed
    // pacing is that the pressure is real, so an expired question cannot be
    // returned to later.
    final question = state.question;
    state = state.copyWith(
      questionRemaining: Duration.zero,
      locked: {...state.locked, question.id},
    );
    onQuestionExpired?.call();
    if (!state.isLastQuestion) {
      goTo(state.index + 1);
    }
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
    _resetQuestionClock();
  }

  void next() => goTo(state.index + 1);

  void previous() => goTo(state.index - 1);

  void selectOption(int optionIndex) {
    // A locked question is one whose timer expired, or one already checked in
    // practice. Either way the answer is settled and must not move.
    if (state.currentLocked) return;
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
    if (state.currentLocked) return;
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
    if (state.currentLocked) return;
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

  /// Practice mode: grade the current answer now and reveal the solution.
  ///
  /// Locks the question afterwards. Being told the answer and then being
  /// allowed to change it would make the score meaningless even by practice
  /// standards, and the point of practice is to find out what you actually
  /// knew.
  Future<AnswerCheck?> checkCurrentAnswer() async {
    if (!state.isPractice || state.checking) return null;
    final question = state.question;
    if (state.feedback.containsKey(question.id)) {
      return state.feedback[question.id];
    }

    final response = state.responseFor(question.id);
    if (!response.hasAnswer) return null;

    state = state.copyWith(checking: true);
    try {
      final check = await _repository.checkAnswer(
        state.attempt.id,
        examQuestionId: question.id,
        selected: response.selected,
        numericValue: response.numericValue,
      );
      // The check writes the response server-side, so this one is no longer
      // pending — dropping it avoids a redundant round trip on the next flush.
      _dirty.remove(question.id);
      state = state.copyWith(
        checking: false,
        feedback: {...state.feedback, question.id: check},
        pendingSync: _dirty.length,
        clearQuestionRemaining: true,
      );
      return check;
    } catch (error) {
      state = state.copyWith(
        checking: false,
        lastSyncError: 'Could not check that answer. Try again.',
      );
      if (kDebugMode) debugPrint('practice check failed: $error');
      return null;
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
