import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/quiz/data/quiz_repository.dart';
import 'package:speedquiz/features/quiz/domain/quiz_models.dart';
import 'package:speedquiz/features/quiz/domain/speedrun_rules.dart';
import 'package:speedquiz/features/quiz/presentation/quiz_play_controller.dart';
import 'package:speedquiz/features/quiz/presentation/quiz_play_screen.dart';

PlayableQuestion _question({
  required String id,
  int sequenceIndex = 0,
  int timeLimitMs = 10000,
}) {
  return PlayableQuestion(
    quizQuestionId: id,
    questionId: 'q_$id',
    sequenceIndex: sequenceIndex,
    prompt: 'Prompt $id',
    // Deliberately not "A"/"B"/…: the option tiles are badged with those
    // letters, and a finder could not tell the badge from the answer.
    options: const [
      QuizOption(index: 0, text: 'Mercury'),
      QuizOption(index: 1, text: 'Venus'),
      QuizOption(index: 2, text: 'Mars'),
      QuizOption(index: 3, text: 'Jupiter'),
    ],
    timeLimitMs: timeLimitMs,
    servedAt: DateTime.now(),
  );
}

QuizSession _session({
  String mode = 'speedrun',
  int? timeRemainingMs = 45000,
  PlayableQuestion? question,
}) {
  return QuizSession(
    id: 'session-1',
    topicId: 't1',
    topicName: 'Astronomy',
    mode: mode,
    difficulty: 'medium',
    status: 'active',
    score: 0,
    streak: 0,
    bestStreak: 0,
    questionTimeLimitMs: 10000,
    currentQuestionIndex: 0,
    correctCount: 0,
    incorrectCount: 0,
    questionNumber: 1,
    timeBudgetMs: 45000,
    timeRemainingMs: timeRemainingMs,
    currentQuestion: question ?? _question(id: 'qq1'),
  );
}

AnswerFeedback _feedback({
  bool isCorrect = true,
  bool runEnded = false,
  int timeRemainingMs = 40000,
  int? timeDeltaMs = 2600,
  int streak = 1,
  PlayableQuestion? nextQuestion,
}) {
  return AnswerFeedback(
    isCorrect: isCorrect,
    correctOptionIndex: 0,
    correctOptionText: 'Mercury',
    explanation: 'Because.',
    basePoints: 100,
    speedBonus: 120,
    streakMultiplier: 1.0,
    pointsAwarded: 220,
    score: 220,
    streak: streak,
    bestStreak: streak,
    sessionStatus: runEnded ? 'completed' : 'active',
    runEnded: runEnded,
    timeRemainingMs: timeRemainingMs,
    timeDeltaMs: timeDeltaMs,
    speedTier: 'blitz',
    nextQuestion: nextQuestion,
  );
}

/// Concrete repository with the network swapped out. The Dio instance is never
/// used — every method that would reach out is overridden.
class _FakeQuizRepository extends QuizRepository {
  _FakeQuizRepository({required this.session, required this.feedback})
      : super(Dio());

  final QuizSession session;
  final AnswerFeedback feedback;

  final List<bool> submittedTimeouts = [];

  @override
  Future<QuizSession> createSession({
    required String topicId,
    required String mode,
    required String difficulty,
    bool adaptive = false,
    String? language,
  }) async =>
      session;

  @override
  Future<AnswerFeedback> submitAnswer({
    required String sessionId,
    required String quizQuestionId,
    int? selectedOptionIndex,
    int? clientElapsedMs,
    bool timedOut = false,
  }) async {
    submittedTimeouts.add(timedOut);
    return feedback;
  }

  @override
  Future<QuizResult> getResult(String sessionId) async => _result;

  @override
  Future<QuizResult> finishSession(String sessionId) async => _result;
}

const _result = QuizResult(
  sessionId: 'session-1',
  topicName: 'Astronomy',
  mode: 'speedrun',
  difficulty: 'medium',
  finalScore: 2400,
  accuracy: 80,
  bestStreak: 6,
  questionsAnswered: 15,
  correctCount: 12,
  incorrectCount: 3,
  averageAnswerMs: 2100,
  durationMs: 92000,
  xpEarned: 240,
  isPersonalBest: true,
  previousBest: 1800,
  shareText: 'SpeedQuiz — 2400',
);

/// Drives the count-in to completion. Beats are plain timers, so the widget
/// tester's clock is enough — no real waiting.
Future<void> _pumpCountIn(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.pump(
      const Duration(milliseconds: SpeedrunRules.countdownBeatMs),
    );
  }
  await tester.pump(const Duration(milliseconds: SpeedrunRules.goBeatMs));
}

/// Renders the play screen on a real phone surface — the narrow column is
/// exactly where a HUD row with a clock, a burst and a badge would overflow.
Future<void> _pumpPlayScreen(
  WidgetTester tester,
  _FakeQuizRepository repo,
) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [quizRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: const QuizPlayScreen(
          topicId: 't1',
          mode: 'speedrun',
          difficulty: 'medium',
          topicName: 'Astronomy',
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('SpeedrunRules', () {
    test('every speed tier the server can report has a word in every language',
        () {
      // The identifiers are the wire contract; the words live in the string
      // tables. Both languages must cover all four, or a Hindi speedrun flashes
      // an empty chip on its fastest answers.
      expect(SpeedrunRules.speedTiers, {'blitz', 'fast', 'clean', 'clutch'});
      for (final language in AppLanguage.values) {
        final l10n = stringsFor(language);
        final words = {
          l10n.speedTierBlitz,
          l10n.speedTierFast,
          l10n.speedTierClean,
          l10n.speedTierClutch,
        };
        expect(words.length, 4, reason: 'tiers must be distinguishable');
        expect(words.every((w) => w.trim().isNotEmpty), isTrue);
      }
    });

    test('the verdict flash lasts exactly what the server charges for it', () {
      // Mirrors FEEDBACK_BURN_MS in backend/app/services/speedrun.py. If these
      // drift the HUD clock lands on the wrong number between questions.
      expect(SpeedrunRules.flashMs, 800);
    });
  });

  group('QuizPlayController — speedrun', () {
    testWidgets('counts in before the first question, clock already loaded',
        (tester) async {
      final repo = _FakeQuizRepository(
        session: _session(),
        feedback: _feedback(),
      );
      final controller = QuizPlayController(repo);

      controller.start(topicId: 't1', mode: 'speedrun', difficulty: 'medium');
      await tester.pump();

      expect(controller.state, isA<QuizPlayCountdown>());
      expect((controller.state as QuizPlayCountdown).beat, 3);
      // The clock is on screen from the first beat, but is not running yet.
      expect(controller.runClockMs.value, 45000);

      await tester.pump(
        const Duration(milliseconds: SpeedrunRules.countdownBeatMs),
      );
      expect((controller.state as QuizPlayCountdown).beat, 2);

      await tester.pump(
        const Duration(milliseconds: SpeedrunRules.countdownBeatMs),
      );
      expect((controller.state as QuizPlayCountdown).beat, 1);

      await tester.pump(
        const Duration(milliseconds: SpeedrunRules.countdownBeatMs),
      );
      expect((controller.state as QuizPlayCountdown).beat, 0);

      await tester.pump(const Duration(milliseconds: SpeedrunRules.goBeatMs));
      expect(controller.state, isA<QuizPlayActive>());

      controller.dispose();
    });

    testWidgets('other modes start straight away', (tester) async {
      final repo = _FakeQuizRepository(
        session: _session(mode: 'casual', timeRemainingMs: null),
        feedback: _feedback(),
      );
      final controller = QuizPlayController(repo);

      controller.start(topicId: 't1', mode: 'casual', difficulty: 'medium');
      await tester.pump();

      expect(controller.state, isA<QuizPlayActive>());

      controller.dispose();
    });

    testWidgets('a verdict advances itself — no tap, no panel', (tester) async {
      final repo = _FakeQuizRepository(
        session: _session(),
        feedback: _feedback(
          nextQuestion: _question(
            id: 'qq2',
            sequenceIndex: 1,
            timeLimitMs: 10000,
          ),
        ),
      );
      final controller = QuizPlayController(repo);

      controller.start(topicId: 't1', mode: 'speedrun', difficulty: 'medium');
      await tester.pump();
      await _pumpCountIn(tester);

      controller.submit(optionIndex: 0);
      await tester.pump();

      final flashing = controller.state as QuizPlayActive;
      expect(flashing.answered, isTrue);
      expect(flashing.session.currentQuestion?.quizQuestionId, 'qq1');

      // Nothing is tapped: the flash times out and the run moves on.
      await tester.pump(const Duration(milliseconds: SpeedrunRules.flashMs));
      await tester.pump();

      final next = controller.state as QuizPlayActive;
      expect(next.answered, isFalse);
      expect(next.session.currentQuestion?.quizQuestionId, 'qq2');

      controller.dispose();
    });

    testWidgets('the clock keeps draining through the verdict flash',
        (tester) async {
      final repo = _FakeQuizRepository(
        session: _session(),
        feedback: _feedback(
          timeRemainingMs: 38400,
          nextQuestion: _question(id: 'qq2', sequenceIndex: 1),
        ),
      );
      final controller = QuizPlayController(repo);

      controller.start(topicId: 't1', mode: 'speedrun', difficulty: 'medium');
      await tester.pump();
      await _pumpCountIn(tester);

      controller.submit(optionIndex: 0);
      await tester.pump();

      // The server has already billed the flash, so the HUD is handed that time
      // back to spend on screen — it lands on 38400 as the next question opens.
      expect(
        controller.runClockMs.value,
        38400 + SpeedrunRules.flashMs,
      );

      controller.dispose();
    });

    testWidgets('an empty clock ends the question instead of letting the '
        'player answer on', (tester) async {
      final repo = _FakeQuizRepository(
        session: _session(timeRemainingMs: 0),
        feedback: _feedback(isCorrect: false, runEnded: true, timeRemainingMs: 0),
      );
      final controller = QuizPlayController(repo);

      controller.start(topicId: 't1', mode: 'speedrun', difficulty: 'medium');
      await tester.pump();
      await _pumpCountIn(tester);

      // First run-clock tick sees nothing left and closes the question out.
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pump();

      expect(repo.submittedTimeouts, [true]);

      controller.dispose();
    });

    testWidgets('a run-ending answer flashes, then lands on results',
        (tester) async {
      final repo = _FakeQuizRepository(
        session: _session(),
        feedback: _feedback(
          isCorrect: false,
          runEnded: true,
          timeRemainingMs: 0,
          timeDeltaMs: -3000,
        ),
      );
      final controller = QuizPlayController(repo);

      controller.start(topicId: 't1', mode: 'speedrun', difficulty: 'medium');
      await tester.pump();
      await _pumpCountIn(tester);

      controller.submit(optionIndex: 1);
      await tester.pump();
      expect(controller.state, isA<QuizPlayActive>());
      // The clock is emptied outright — no flash allowance on a dead run.
      expect(controller.runClockMs.value, 0);

      await tester.pump(const Duration(milliseconds: SpeedrunRules.flashMs));
      await tester.pump();

      expect(controller.state, isA<QuizPlayFinished>());
      expect((controller.state as QuizPlayFinished).result.finalScore, 2400);

      controller.dispose();
    });
  });

  group('QuizPlayScreen — speedrun', () {
    testWidgets('the count-in carries the rules', (tester) async {
      final repo = _FakeQuizRepository(
        session: _session(),
        feedback: _feedback(),
      );
      await _pumpPlayScreen(tester, repo);

      expect(find.text('3'), findsOneWidget);
      expect(find.text('SPEEDRUN'), findsOneWidget);
      expect(find.textContaining('buy time back'), findsOneWidget);
      expect(find.textContaining('burns 3 seconds'), findsOneWidget);

      await _pumpCountIn(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the HUD leads with the run clock, not a time chip',
        (tester) async {
      final repo = _FakeQuizRepository(
        session: _session(),
        feedback: _feedback(),
      );
      await _pumpPlayScreen(tester, repo);
      await _pumpCountIn(tester);

      expect(find.text('RUN CLOCK'), findsOneWidget);
      expect(find.text('45.0'), findsOneWidget);
      expect(find.text('Prompt qq1'), findsOneWidget);
      // The verdict panel and its NEXT button are gone in this mode.
      expect(find.text('NEXT'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a correct answer bursts the time it bought', (tester) async {
      final repo = _FakeQuizRepository(
        session: _session(),
        feedback: _feedback(
          timeRemainingMs: 41200,
          timeDeltaMs: 3100,
          nextQuestion: _question(id: 'qq2', sequenceIndex: 1),
        ),
      );
      await _pumpPlayScreen(tester, repo);
      await _pumpCountIn(tester);

      await tester.tap(find.text('Mercury'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));

      expect(find.text('+3.1s'), findsOneWidget);
      expect(find.text('BLITZ'), findsOneWidget);
      // Still no panel to tap through.
      expect(find.text('NEXT'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a wrong answer bursts the time it cost', (tester) async {
      final repo = _FakeQuizRepository(
        session: _session(),
        feedback: _feedback(
          isCorrect: false,
          streak: 0,
          timeRemainingMs: 38000,
          timeDeltaMs: -3000,
          nextQuestion: _question(id: 'qq2', sequenceIndex: 1),
        ),
      );
      await _pumpPlayScreen(tester, repo);
      await _pumpCountIn(tester);

      await tester.tap(find.text('Venus'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));

      expect(find.text('−3.0s'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('flags the question where the limit tightens', (tester) async {
      final repo = _FakeQuizRepository(
        session: _session(),
        feedback: _feedback(
          // Depth 4 is the first step down: 10s becomes 9.25s.
          nextQuestion: _question(
            id: 'qq2',
            sequenceIndex: 4,
            timeLimitMs: 9250,
          ),
        ),
      );
      await _pumpPlayScreen(tester, repo);
      await _pumpCountIn(tester);

      expect(find.text('⚡ FASTER'), findsNothing);

      await tester.tap(find.text('Mercury'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: SpeedrunRules.flashMs));
      await tester.pump();

      expect(find.text('⚡ FASTER'), findsOneWidget);
      expect(find.text('Prompt qq2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a hot streak lights up overdrive', (tester) async {
      final repo = _FakeQuizRepository(
        session: _session(),
        feedback: _feedback(
          streak: 6,
          nextQuestion: _question(id: 'qq2', sequenceIndex: 1),
        ),
      );
      await _pumpPlayScreen(tester, repo);
      await _pumpCountIn(tester);

      expect(find.text('🔥'), findsOneWidget);

      await tester.tap(find.text('Mercury'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));

      expect(find.text('OVERDRIVE ×6'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('QuizResult', () {
    test('reads the run duration a speedrun result headlines', () {
      final parsed = QuizResult.fromJson({
        'session_id': 's1',
        'topic_name': 'Astronomy',
        'mode': 'speedrun',
        'difficulty': 'medium',
        'final_score': 2400,
        'accuracy': 80.0,
        'best_streak': 6,
        'questions_answered': 15,
        'correct_count': 12,
        'incorrect_count': 3,
        'average_answer_ms': 2100,
        'duration_ms': 92000,
        'xp_earned': 240,
        'is_personal_best': true,
        'previous_best': 1800,
        'share_text': 'x',
      });
      expect(parsed.durationMs, 92000);
    });

    test('older payloads without a duration still parse', () {
      final parsed = QuizResult.fromJson({
        'session_id': 's1',
        'topic_name': 'Astronomy',
        'mode': 'casual',
        'difficulty': 'medium',
        'final_score': 100,
        'accuracy': 50.0,
        'best_streak': 1,
        'questions_answered': 2,
        'correct_count': 1,
        'incorrect_count': 1,
        'average_answer_ms': 3000,
        'xp_earned': 10,
        'is_personal_best': false,
        'previous_best': 0,
        'share_text': 'x',
      });
      expect(parsed.durationMs, 0);
    });
  });

  group('AnswerFeedback', () {
    test('reads the speedrun fields', () {
      final parsed = AnswerFeedback.fromJson({
        'is_correct': true,
        'selected_option_index': 2,
        'correct_option_index': 2,
        'correct_option_text': 'C',
        'explanation': 'Because.',
        'base_points': 100,
        'speed_bonus': 140,
        'streak_multiplier': 2.0,
        'points_awarded': 580,
        'score': 3200,
        'streak': 10,
        'best_streak': 10,
        'time_remaining_ms': 41200,
        'session_status': 'active',
        'run_ended': false,
        'milestone_bonus': 200,
        'time_delta_ms': 3100,
        'time_burned_ms': 2300,
        'overdrive': true,
        'speed_tier': 'blitz',
      });

      expect(parsed.milestoneBonus, 200);
      expect(parsed.timeDeltaMs, 3100);
      expect(parsed.timeBurnedMs, 2300);
      expect(parsed.overdrive, isTrue);
      expect(parsed.speedTier, 'blitz');
    });

    test('a non-speedrun payload leaves them at their defaults', () {
      final parsed = AnswerFeedback.fromJson({
        'is_correct': false,
        'selected_option_index': null,
        'correct_option_index': 1,
        'correct_option_text': 'B',
        'explanation': 'Because.',
        'base_points': 0,
        'speed_bonus': 0,
        'streak_multiplier': 1.0,
        'points_awarded': 0,
        'score': 400,
        'streak': 0,
        'best_streak': 3,
        'session_status': 'active',
        'run_ended': false,
      });

      expect(parsed.milestoneBonus, 0);
      expect(parsed.timeDeltaMs, isNull);
      expect(parsed.overdrive, isFalse);
      expect(parsed.speedTier, isNull);
    });
  });
}
