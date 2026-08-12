import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/network/api_errors.dart';
import 'package:speedquiz/features/quiz/data/quiz_repository.dart';
import 'package:speedquiz/features/quiz/domain/quiz_models.dart';
import 'package:speedquiz/features/quiz/domain/speedrun_rules.dart';

sealed class QuizPlayState {
  const QuizPlayState();
}

class QuizPlayIdle extends QuizPlayState {
  const QuizPlayIdle();
}

class QuizPlayLoading extends QuizPlayState {
  const QuizPlayLoading();
}

/// Speedrun only: the "3 · 2 · 1 · GO" beat between a loaded session and the
/// first question. The clock does not start until it lands, so nobody loses
/// time to a question they have not been shown yet.
class QuizPlayCountdown extends QuizPlayState {
  const QuizPlayCountdown(this.beat);

  /// 3, 2, 1, then 0 for GO.
  final int beat;
}

class QuizPlayActive extends QuizPlayState {
  const QuizPlayActive({
    required this.session,
    this.feedback,
    this.submitting = false,
    this.selectedOptionIndex,
    this.tightened = false,
  });

  final QuizSession session;
  final AnswerFeedback? feedback;
  final bool submitting;
  final int? selectedOptionIndex;

  /// This question is on a shorter clock than the last one — speedrun's
  /// difficulty ramp, made visible.
  final bool tightened;

  bool get isSpeedrun => session.mode == 'speedrun';
  bool get answered => feedback != null;
}

class QuizPlayFinished extends QuizPlayState {
  const QuizPlayFinished(this.result);
  final QuizResult result;
}

/// Failures the *screen* has localized copy for.
///
/// The controller has no `BuildContext` and must not hold a string table — it
/// outlives a language change, and rebuilding it would restart the run. So it
/// classifies the failure and the screen words it. [QuizPlayError.message]
/// stays as the fallback for everything else, including prose the server sent.
enum QuizPlayFailure {
  unknown,
  entitlementCap,
  contentLanguageUnavailable,
  noQuestion,
  noNextQuestion,
}

class QuizPlayError extends QuizPlayState {
  const QuizPlayError(
    this.message, {
    this.failure = QuizPlayFailure.unknown,
  });

  final String message;
  final QuizPlayFailure failure;

  bool get isEntitlementCap => failure == QuizPlayFailure.entitlementCap;
}

class QuizPlayController extends StateNotifier<QuizPlayState> {
  QuizPlayController(this._repo) : super(const QuizPlayIdle());

  final QuizRepository _repo;

  /// Countdown values live outside [state] on purpose: the tickers run at
  /// 10-20Hz, and pushing them through the state notifier would rebuild the
  /// whole question tree — options, prompt and all — several times a second.
  /// Only the timer widgets listen to these.
  final ValueNotifier<int> remainingMs = ValueNotifier<int>(0);

  /// Speedrun's run clock. Unlike [remainingMs] this is not per question — it
  /// is the run itself, and it keeps draining through the verdict flash.
  final ValueNotifier<int> runClockMs = ValueNotifier<int>(0);

  Timer? _ticker;
  Timer? _flashTimer;
  Timer? _runClockTicker;
  DateTime? _questionStartedAt;
  bool _disposed = false;

  /// Run clock as an anchor pair: the clock read [_clockBaseMs] at
  /// [_clockAnchor], and every tick projects forward from there. A null anchor
  /// means the clock is frozen — while an answer is in flight, so a slow
  /// network never costs the player time the server is not charging them for.
  int _clockBaseMs = 0;
  DateTime? _clockAnchor;

  Future<void> start({
    required String topicId,
    required String mode,
    required String difficulty,
    bool adaptive = false,
    String? language,
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
            language: language,
          );
      if (_disposed) return;

      if (session.mode == 'speedrun') {
        runClockMs.value = session.timeRemainingMs ?? 0;
        await _countIn();
        if (_disposed) return;
      }
      _beginQuestion(session);
    } catch (error) {
      _fail(error);
    }
  }

  Future<void> _countIn() async {
    for (final beat in const [3, 2, 1, 0]) {
      if (_disposed) return;
      state = QuizPlayCountdown(beat);
      await Future<void>.delayed(
        Duration(
          milliseconds: beat == 0
              ? SpeedrunRules.goBeatMs
              : SpeedrunRules.countdownBeatMs,
        ),
      );
    }
  }

  void _fail(Object error) {
    if (_disposed) return;
    _cancelTimers();
    state = QuizPlayError(
      apiErrorMessage(
        error,
        fallback: error is DioException
            ? (error.message ?? error.toString())
            : error.toString(),
      ),
      failure: _classify(error),
    );
  }

  static QuizPlayFailure _classify(Object error) {
    if (isEntitlementUniqueCap(error)) return QuizPlayFailure.entitlementCap;
    if (isContentLanguageUnavailable(error)) {
      return QuizPlayFailure.contentLanguageUnavailable;
    }
    return QuizPlayFailure.unknown;
  }

  void _cancelTimers() {
    _ticker?.cancel();
    _ticker = null;
    _flashTimer?.cancel();
    _flashTimer = null;
    _stopRunClock();
  }

  // --- Run clock -----------------------------------------------------------

  /// Set the clock to [ms] and let it run from now.
  void _setRunClock(int ms) {
    _clockBaseMs = ms.clamp(0, SpeedrunRules.clockCapMs);
    _clockAnchor = DateTime.now();
    runClockMs.value = _clockBaseMs;
    _runClockTicker ??= Timer.periodic(
      const Duration(milliseconds: 50),
      (_) => _tickRunClock(),
    );
  }

  /// Hold the clock where it is — used while an answer is in flight.
  void _freezeRunClock() {
    _clockBaseMs = runClockMs.value;
    _clockAnchor = null;
  }

  void _stopRunClock() {
    _runClockTicker?.cancel();
    _runClockTicker = null;
    _clockAnchor = null;
  }

  void _tickRunClock() {
    final anchor = _clockAnchor;
    if (anchor == null) return;

    final elapsed = DateTime.now().difference(anchor).inMilliseconds;
    final left = (_clockBaseMs - elapsed).clamp(0, SpeedrunRules.clockCapMs);
    runClockMs.value = left;
    if (left > 0) return;

    _clockAnchor = null;
    // Out of time mid-question. End it here rather than letting the player
    // keep answering on a dead clock while the per-question timer runs down.
    final current = state;
    if (current is QuizPlayActive &&
        !current.answered &&
        !current.submitting &&
        current.isSpeedrun) {
      submit(timedOut: true);
    }
  }

  // --- Question flow -------------------------------------------------------

  void _beginQuestion(QuizSession session, {bool tightened = false}) {
    _ticker?.cancel();
    _flashTimer?.cancel();

    final question = session.currentQuestion;
    if (question == null) {
      state = const QuizPlayError(
        'No question available.',
        failure: QuizPlayFailure.noQuestion,
      );
      return;
    }

    _questionStartedAt = DateTime.now();
    remainingMs.value = question.timeLimitMs;
    state = QuizPlayActive(session: session, tightened: tightened);

    if (session.mode == 'speedrun') {
      _setRunClock(session.timeRemainingMs ?? runClockMs.value);
    }

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
    // The server charges the question and the flash, never the round trip.
    if (current.isSpeedrun) _freezeRunClock();

    state = QuizPlayActive(
      session: current.session,
      submitting: true,
      selectedOptionIndex: optionIndex,
      tightened: current.tightened,
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

      if (isSpeedrun) {
        // The server has already taken the flash off the clock, so hand the
        // player that time back and let it drain live during the flash: it
        // lands on the server's value exactly as the next question opens.
        final serverClock = feedback.timeRemainingMs ?? 0;
        if (feedback.runEnded) {
          runClockMs.value = serverClock;
          _stopRunClock();
        } else {
          _setRunClock(serverClock + SpeedrunRules.flashMs);
        }
      }

      state = QuizPlayActive(
        session: updatedSession,
        feedback: feedback,
        selectedOptionIndex: optionIndex,
        tightened: current.tightened,
      );

      if (isSpeedrun) {
        _startSpeedrunFlash(toResults: feedback.runEnded);
      }
      // Other modes wait for an explicit NEXT / SEE RESULTS tap.
    } catch (error) {
      _fail(error);
    }
  }

  /// Speedrun never asks the player to tap through a verdict. The answer flashes
  /// for [SpeedrunRules.flashMs] — long enough to read a colour and a number,
  /// short enough that the run never loses its pulse — then moves on by itself.
  void _startSpeedrunFlash({bool toResults = false}) {
    _flashTimer?.cancel();
    _flashTimer = Timer(
      const Duration(milliseconds: SpeedrunRules.flashMs),
      () async {
        if (_disposed) return;
        final current = state;
        if (current is! QuizPlayActive || !current.answered) return;

        if (toResults || current.feedback!.runEnded) {
          await _loadResult(current.session.id);
        } else {
          await continueAfterFeedback();
        }
      },
    );
  }

  Future<void> _loadResult(String sessionId) async {
    _stopRunClock();
    try {
      final result = await _repo.getResult(sessionId);
      if (!_disposed) state = QuizPlayFinished(result);
    } catch (error) {
      _fail(error);
    }
  }

  Future<void> continueAfterFeedback() async {
    _flashTimer?.cancel();

    final current = state;
    if (current is! QuizPlayActive || !current.answered) return;
    final feedback = current.feedback!;

    if (feedback.runEnded) {
      await _loadResult(current.session.id);
      return;
    }

    final next = feedback.nextQuestion;
    if (next == null) {
      state = const QuizPlayError(
        'No next question was returned.',
        failure: QuizPlayFailure.noNextQuestion,
      );
      return;
    }

    final previousLimit = current.session.currentQuestion?.timeLimitMs;
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
      tightened: previousLimit != null && next.timeLimitMs < previousLimit,
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
    runClockMs.dispose();
    super.dispose();
  }
}

final quizPlayControllerProvider =
    StateNotifierProvider.autoDispose<QuizPlayController, QuizPlayState>((ref) {
  return QuizPlayController(ref.watch(quizRepositoryProvider));
});
