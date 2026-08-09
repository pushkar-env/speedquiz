import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:quizverse/core/network/api_errors.dart';
import 'package:quizverse/features/quiz/data/quiz_repository.dart';
import 'package:quizverse/features/quiz/domain/quiz_models.dart';

sealed class QuizPlayState {
  const QuizPlayState();
}

class QuizPlayIdle extends QuizPlayState {
  const QuizPlayIdle();
}

class QuizPlayLoading extends QuizPlayState {
  const QuizPlayLoading();
}

class QuizPlayActive extends QuizPlayState {
  const QuizPlayActive({
    required this.session,
    required this.remainingMs,
    this.feedback,
    this.submitting = false,
    this.selectedOptionIndex,
    this.autoAdvanceRemainingMs,
  });

  final QuizSession session;
  final int remainingMs;
  final AnswerFeedback? feedback;
  final bool submitting;
  final int? selectedOptionIndex;

  /// Speedrun-only: countdown before auto-advancing (null when not counting).
  final int? autoAdvanceRemainingMs;

  bool get isSpeedrun => session.mode == 'speedrun';
}

class QuizPlayFinished extends QuizPlayState {
  const QuizPlayFinished(this.result);
  final QuizResult result;
}

class QuizPlayError extends QuizPlayState {
  const QuizPlayError(this.message, {this.isEntitlementCap = false});
  final String message;
  final bool isEntitlementCap;
}

class QuizPlayController extends StateNotifier<QuizPlayState> {
  QuizPlayController(this._repo) : super(const QuizPlayIdle());

  final QuizRepository _repo;
  Timer? _ticker;
  Timer? _autoAdvanceTicker;
  DateTime? _questionStartedAt;
  bool _disposed = false;

  static const _speedrunAutoAdvanceMs = 3000;

  Future<void> start({
    required String topicId,
    required String mode,
    required String difficulty,
    bool adaptive = false,
    QuizSession? existingSession,
  }) async {
    _cancelTimers();
    state = const QuizPlayLoading();
    try {
      final session = existingSession ??
          await _repo.createSession(
            topicId: topicId,
            mode: mode,
            difficulty: difficulty,
            adaptive: adaptive,
          );
      _beginQuestion(session);
    } catch (error) {
      state = QuizPlayError(
        _friendlyError(error),
        isEntitlementCap: isEntitlementUniqueCap(error),
      );
    }
  }

  String _friendlyError(Object error) {
    if (isEntitlementUniqueCap(error)) {
      return 'Free unique-question limit reached for this topic. '
          'Go Premium (Profile) to keep playing.';
    }
    return apiErrorMessage(
      error,
      fallback: error is DioException
          ? (error.message ?? error.toString())
          : error.toString(),
    );
  }

  void _cancelTimers() {
    _ticker?.cancel();
    _ticker = null;
    _autoAdvanceTicker?.cancel();
    _autoAdvanceTicker = null;
  }

  void _beginQuestion(QuizSession session) {
    _cancelTimers();
    final question = session.currentQuestion;
    if (question == null) {
      state = const QuizPlayError('No question available');
      return;
    }
    _questionStartedAt = DateTime.now();
    state = QuizPlayActive(
      session: session,
      remainingMs: question.timeLimitMs,
    );
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final current = state;
      if (current is! QuizPlayActive ||
          current.feedback != null ||
          current.submitting) {
        return;
      }
      final started = _questionStartedAt;
      if (started == null) return;
      final elapsed = DateTime.now().difference(started).inMilliseconds;
      final remaining = (current.session.currentQuestion!.timeLimitMs - elapsed)
          .clamp(0, current.session.currentQuestion!.timeLimitMs);
      if (remaining <= 0) {
        _ticker?.cancel();
        submit(timedOut: true);
        return;
      }
      state = QuizPlayActive(session: current.session, remainingMs: remaining);
    });
  }

  Future<void> submit({int? optionIndex, bool timedOut = false}) async {
    final current = state;
    if (current is! QuizPlayActive ||
        current.submitting ||
        current.feedback != null) {
      return;
    }
    final question = current.session.currentQuestion;
    if (question == null) return;

    _ticker?.cancel();
    state = QuizPlayActive(
      session: current.session,
      remainingMs: current.remainingMs,
      submitting: true,
      selectedOptionIndex: optionIndex,
    );

    final elapsed = _questionStartedAt == null
        ? null
        : DateTime.now().difference(_questionStartedAt!).inMilliseconds;

    try {
      final feedback = await _repo.submitAnswer(
        sessionId: current.session.id,
        quizQuestionId: question.quizQuestionId,
        selectedOptionIndex: timedOut ? null : optionIndex,
        clientElapsedMs: elapsed,
        timedOut: timedOut,
      );

      // Keep the answered question on-screen for inline feedback.
      final updatedSession = current.session.copyWith(
        score: feedback.score,
        streak: feedback.streak,
        bestStreak: feedback.bestStreak,
        lives: feedback.lives,
        timeRemainingMs: feedback.timeRemainingMs,
        status: feedback.sessionStatus,
        questionNumber: current.session.questionNumber,
        currentQuestion: question,
      );

      final isSpeedrun = updatedSession.mode == 'speedrun';
      state = QuizPlayActive(
        session: updatedSession,
        remainingMs: 0,
        feedback: feedback,
        selectedOptionIndex: optionIndex,
        autoAdvanceRemainingMs:
            isSpeedrun && !feedback.runEnded ? _speedrunAutoAdvanceMs : null,
      );

      if (feedback.runEnded) {
        if (isSpeedrun) {
          state = QuizPlayActive(
            session: updatedSession,
            remainingMs: 0,
            feedback: feedback,
            selectedOptionIndex: optionIndex,
            autoAdvanceRemainingMs: _speedrunAutoAdvanceMs,
          );
          _startSpeedrunAutoAdvance(toResults: true);
        }
        // Other modes: wait for SEE RESULTS tap.
        return;
      }

      if (isSpeedrun) {
        _startSpeedrunAutoAdvance();
      }
    } catch (error) {
      state = QuizPlayError(
        _friendlyError(error),
        isEntitlementCap: isEntitlementUniqueCap(error),
      );
    }
  }

  void _startSpeedrunAutoAdvance({bool toResults = false}) {
    _autoAdvanceTicker?.cancel();
    final started = DateTime.now();
    _autoAdvanceTicker =
        Timer.periodic(const Duration(milliseconds: 50), (timer) async {
      if (_disposed) {
        timer.cancel();
        return;
      }
      final current = state;
      if (current is! QuizPlayActive || current.feedback == null) {
        timer.cancel();
        return;
      }
      final elapsed = DateTime.now().difference(started).inMilliseconds;
      final remaining =
          (_speedrunAutoAdvanceMs - elapsed).clamp(0, _speedrunAutoAdvanceMs);
      if (remaining <= 0) {
        timer.cancel();
        if (toResults || current.feedback!.runEnded) {
          final result = await _repo.getResult(current.session.id);
          if (!_disposed) state = QuizPlayFinished(result);
        } else {
          await continueAfterFeedback();
        }
        return;
      }
      state = QuizPlayActive(
        session: current.session,
        remainingMs: current.remainingMs,
        feedback: current.feedback,
        selectedOptionIndex: current.selectedOptionIndex,
        autoAdvanceRemainingMs: remaining,
      );
    });
  }

  Future<void> continueAfterFeedback() async {
    _autoAdvanceTicker?.cancel();
    final current = state;
    if (current is! QuizPlayActive || current.feedback == null) return;
    final feedback = current.feedback!;
    if (feedback.runEnded) {
      final result = await _repo.getResult(current.session.id);
      if (!_disposed) state = QuizPlayFinished(result);
      return;
    }
    final next = feedback.nextQuestion;
    if (next == null) {
      state = const QuizPlayError('No next question');
      return;
    }
    final session = current.session.copyWith(
      score: feedback.score,
      streak: feedback.streak,
      bestStreak: feedback.bestStreak,
      lives: feedback.lives,
      timeRemainingMs: feedback.timeRemainingMs,
      questionNumber: next.sequenceIndex + 1,
      currentQuestion: next,
    );
    _beginQuestion(session);
  }

  Future<void> endRun() async {
    final current = state;
    if (current is! QuizPlayActive) return;
    _cancelTimers();
    state = const QuizPlayLoading();
    try {
      final result = await _repo.finishSession(current.session.id);
      if (!_disposed) state = QuizPlayFinished(result);
    } catch (error) {
      if (!_disposed) {
        state = QuizPlayError(
          _friendlyError(error),
          isEntitlementCap: isEntitlementUniqueCap(error),
        );
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelTimers();
    super.dispose();
  }
}

final quizPlayControllerProvider =
    StateNotifierProvider.autoDispose<QuizPlayController, QuizPlayState>((ref) {
  return QuizPlayController(ref.watch(quizRepositoryProvider));
});
