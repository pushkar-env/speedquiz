import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/network/api_errors.dart';
import 'package:speedquiz/features/quiz/data/quiz_repository.dart';
import 'package:speedquiz/features/quiz/domain/quiz_models.dart';

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
    this.feedback,
    this.submitting = false,
    this.selectedOptionIndex,
  });

  final QuizSession session;
  final AnswerFeedback? feedback;
  final bool submitting;
  final int? selectedOptionIndex;

  bool get isSpeedrun => session.mode == 'speedrun';
  bool get answered => feedback != null;
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

  /// Countdown values live outside [state] on purpose: the tickers run at
  /// 10-20Hz, and pushing them through the state notifier would rebuild the
  /// whole question tree — options, prompt and all — several times a second.
  /// Only the timer widgets listen to these.
  final ValueNotifier<int> remainingMs = ValueNotifier<int>(0);
  final ValueNotifier<int?> autoAdvanceMs = ValueNotifier<int?>(null);

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
      _fail(error);
    }
  }

  void _fail(Object error) {
    if (_disposed) return;
    state = QuizPlayError(
      _friendlyError(error),
      isEntitlementCap: isEntitlementUniqueCap(error),
    );
  }

  String _friendlyError(Object error) {
    if (isEntitlementUniqueCap(error)) {
      return 'You have hit the free unique-question limit for this topic. '
          'Go Premium to keep playing it.';
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
    autoAdvanceMs.value = null;
  }

  void _beginQuestion(QuizSession session) {
    _cancelTimers();
    final question = session.currentQuestion;
    if (question == null) {
      state = const QuizPlayError('No question available.');
      return;
    }

    _questionStartedAt = DateTime.now();
    remainingMs.value = question.timeLimitMs;
    state = QuizPlayActive(session: session);

    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final current = state;
      if (current is! QuizPlayActive ||
          current.answered ||
          current.submitting) {
        return;
      }
      final started = _questionStartedAt;
      if (started == null) return;

      final limit = current.session.currentQuestion?.timeLimitMs ?? 0;
      final elapsed = DateTime.now().difference(started).inMilliseconds;
      final left = (limit - elapsed).clamp(0, limit);
      remainingMs.value = left;

      if (left <= 0) {
        _ticker?.cancel();
        submit(timedOut: true);
      }
    });
  }

  Future<void> submit({int? optionIndex, bool timedOut = false}) async {
    final current = state;
    if (current is! QuizPlayActive || current.submitting || current.answered) {
      return;
    }
    final question = current.session.currentQuestion;
    if (question == null) return;

    _ticker?.cancel();
    state = QuizPlayActive(
      session: current.session,
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
      if (_disposed) return;

      // Keep the answered question on screen so feedback has context.
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
      remainingMs.value = 0;
      autoAdvanceMs.value = isSpeedrun ? _speedrunAutoAdvanceMs : null;

      state = QuizPlayActive(
        session: updatedSession,
        feedback: feedback,
        selectedOptionIndex: optionIndex,
      );

      if (isSpeedrun) {
        _startSpeedrunAutoAdvance(toResults: feedback.runEnded);
      }
      // Other modes wait for an explicit NEXT / SEE RESULTS tap.
    } catch (error) {
      _fail(error);
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
      if (current is! QuizPlayActive || !current.answered) {
        timer.cancel();
        return;
      }

      final elapsed = DateTime.now().difference(started).inMilliseconds;
      final left =
          (_speedrunAutoAdvanceMs - elapsed).clamp(0, _speedrunAutoAdvanceMs);
      autoAdvanceMs.value = left;

      if (left <= 0) {
        timer.cancel();
        if (toResults || current.feedback!.runEnded) {
          await _loadResult(current.session.id);
        } else {
          await continueAfterFeedback();
        }
      }
    });
  }

  Future<void> _loadResult(String sessionId) async {
    try {
      final result = await _repo.getResult(sessionId);
      if (!_disposed) state = QuizPlayFinished(result);
    } catch (error) {
      _fail(error);
    }
  }

  Future<void> continueAfterFeedback() async {
    _autoAdvanceTicker?.cancel();
    autoAdvanceMs.value = null;

    final current = state;
    if (current is! QuizPlayActive || !current.answered) return;
    final feedback = current.feedback!;

    if (feedback.runEnded) {
      await _loadResult(current.session.id);
      return;
    }

    final next = feedback.nextQuestion;
    if (next == null) {
      state = const QuizPlayError('No next question was returned.');
      return;
    }

    _beginQuestion(
      current.session.copyWith(
        score: feedback.score,
        streak: feedback.streak,
        bestStreak: feedback.bestStreak,
        lives: feedback.lives,
        timeRemainingMs: feedback.timeRemainingMs,
        questionNumber: next.sequenceIndex + 1,
        currentQuestion: next,
      ),
    );
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
      _fail(error);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelTimers();
    remainingMs.dispose();
    autoAdvanceMs.dispose();
    super.dispose();
  }
}

final quizPlayControllerProvider =
    StateNotifierProvider.autoDispose<QuizPlayController, QuizPlayState>((ref) {
  return QuizPlayController(ref.watch(quizRepositoryProvider));
});
