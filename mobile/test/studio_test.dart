import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/routing/deep_links.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/studio/data/custom_quiz_repository.dart';
import 'package:speedquiz/features/studio/domain/custom_quiz_models.dart';
import 'package:speedquiz/features/studio/presentation/quiz_detail_screen.dart';
import 'package:speedquiz/features/studio/presentation/quiz_editor_screen.dart';
import 'package:speedquiz/features/studio/presentation/studio_screen.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// Devanagari block — Hindi copy has to be in script, not transliterated.
final _devanagari = RegExp(r'[ऀ-ॿ]');

Map<String, dynamic> _quizJson({
  String id = 'q1',
  String title = 'Bollywood 2000s',
  String status = 'published',
  String visibility = 'link',
  String? code = 'BCD234',
  int questionCount = 8,
  int playCount = 12,
  bool isOwner = true,
  int? myBest,
  List<String> blockers = const [],
}) {
  return {
    'id': id,
    'topic_id': 'topic-$id',
    'title': title,
    'description': 'Films, songs and the decade that made them.',
    'icon': '🎬',
    'language': 'en',
    'visibility': visibility,
    'status': status,
    'code': code,
    'question_count': questionCount,
    'default_mode': 'casual',
    'default_difficulty': 'medium',
    'play_count': playCount,
    'player_count': 5,
    'top_score': 4200,
    'author': <String, dynamic>{
      'user_id': 'u1',
      'username': 'ravi',
      'display_name': 'Ravi',
      'avatar_id': 'avatar_02',
      'is_premium': false,
    },
    'is_owner': isOwner,
    'my_best_score': myBest,
    'publish_blockers': blockers,
    'created_at': '2026-08-01T10:00:00Z',
    'updated_at': '2026-08-20T10:00:00Z',
    'published_at': '2026-08-02T10:00:00Z',
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('parsing', () {
    test('a quiz round-trips from the wire', () {
      final quiz = CustomQuiz.fromJson(_quizJson());
      expect(quiz.title, 'Bollywood 2000s');
      expect(quiz.visibility, QuizVisibility.link);
      expect(quiz.status, QuizStatus.published);
      expect(quiz.isPlayable, isTrue);
      expect(quiz.author.name, 'Ravi');
    });

    test('an unknown visibility falls back to the safest tier', () {
      // A build that predates a future tier must not throw on it, and must not
      // guess *outwards* — showing a quiz to more people than the author chose
      // is the one failure that cannot be walked back.
      final quiz = CustomQuiz.fromJson(_quizJson(visibility: 'galactic'));
      expect(quiz.visibility, QuizVisibility.private);
    });

    test('an unknown status reads as a draft, not as live', () {
      final quiz = CustomQuiz.fromJson(_quizJson(status: 'quantum'));
      expect(quiz.status, QuizStatus.draft);
      expect(quiz.isPlayable, isFalse);
    });

    test('an author name falls back to the handle', () {
      final json = _quizJson();
      (json['author'] as Map<String, dynamic>)['display_name'] = null;
      expect(CustomQuiz.fromJson(json).author.name, 'ravi');
    });

    test('a played quiz cannot be hard-deleted', () {
      // Deleting cascades to every score posted on it, so the client must not
      // even offer the action once somebody has played.
      expect(CustomQuiz.fromJson(_quizJson(playCount: 3)).canHardDelete, isFalse);
      expect(CustomQuiz.fromJson(_quizJson(playCount: 0)).canHardDelete, isTrue);
    });

    test('a question keeps its answer key and reports its correct option', () {
      final question = CustomQuizQuestion.fromJson({
        'id': 'qq1',
        'position': 2,
        'prompt': 'Which film won Best Picture in 2004?',
        'options': ['Lagaan', 'Devdas', 'Black', 'Swades'],
        'correct_option_index': 2,
        'difficulty': 'hard',
        'ai_drafted': true,
        'times_served': 4,
      });
      expect(question.correctOption, 'Black');
      expect(question.aiDrafted, isTrue);
      expect(question.isNew, isFalse);
    });

    test('a blank question is marked new so the editor knows to POST it', () {
      final blank = CustomQuizQuestion.blank();
      expect(blank.isNew, isTrue);
      expect(blank.options, hasLength(4));
    });

    test('a question serializes only the fields the API accepts', () {
      final json = CustomQuizQuestion.blank()
          .copyWith(
            prompt: 'Capital of France?',
            options: ['Paris', 'Lyon', 'Nice', 'Marseille'],
            correctOptionIndex: 0,
          )
          .toJson();
      expect(json.keys, containsAll(['prompt', 'options', 'correct_option_index']));
      // An empty explanation is omitted rather than sent as "": the server
      // fills a blank one with the restated answer, and "" would defeat that.
      expect(json.containsKey('explanation'), isFalse);
      expect(json.containsKey('id'), isFalse);
    });

    test('AI drafts arrive without ids, so the editor treats them as new', () {
      final batch = QuizDraftBatch.fromJson({
        'questions': [
          {
            'prompt': 'Who wrote Midnight\'s Children?',
            'options': ['Rushdie', 'Roy', 'Seth', 'Ghosh'],
            'correct_option_index': 0,
            'difficulty': 'medium',
          },
        ],
        'remaining_today': 2,
      });
      expect(batch.questions, hasLength(1));
      expect(batch.questions.single.isNew, isTrue);
      expect(batch.questions.single.aiDrafted, isTrue);
      expect(batch.remainingToday, 2);
    });

    test('a premium account reports unlimited slots rather than zero', () {
      final library = CustomQuizLibrary.fromJson({
        'mine': [_quizJson()],
        'shared': [],
        'remaining_slots': null,
        'max_questions': 50,
      });
      expect(library.remainingSlots, isNull);
      expect(library.atLimit, isFalse, reason: 'null means unlimited, not used up');
      expect(library.maxQuestions, 50);
    });

    test('a used-up free account is at its limit', () {
      final library = CustomQuizLibrary.fromJson({
        'mine': [_quizJson()],
        'shared': [],
        'remaining_slots': 0,
        'max_questions': 20,
      });
      expect(library.atLimit, isTrue);
    });

    test('the board knows when the viewer is already listed', () {
      final board = QuizLeaderboard.fromJson({
        'quiz_id': 'q1',
        'entries': [
          {
            'rank': 1,
            'user_id': 'u9',
            'username': 'ravi',
            'best_score': 900,
            'accuracy': 88.0,
            'played_at': '2026-08-20T10:00:00Z',
            'is_me': true,
          },
        ],
        'me': {
          'rank': 1,
          'user_id': 'u9',
          'username': 'ravi',
          'best_score': 900,
          'accuracy': 88.0,
          'played_at': '2026-08-20T10:00:00Z',
          'is_me': true,
        },
        'total_players': 1,
      });
      // The pinned footer exists for a player who fell off the page. Drawing
      // it directly under their own listed row reads as a rendering bug.
      expect(board.meIsListed, isTrue);
    });
  });

  group('share-code deep links', () {
    test('maps the custom scheme', () {
      expect(
        locationFromDeepLink(Uri.parse('speedquiz://quiz/BCD234')),
        '/studio/code/BCD234',
      );
      expect(
        locationFromDeepLink(Uri.parse('speedquiz:///quiz/BCD234')),
        '/studio/code/BCD234',
      );
    });

    test('maps the short https form a chat message can carry', () {
      expect(
        locationFromDeepLink(Uri.parse('https://speedquiz.app/q/BCD234')),
        '/studio/code/BCD234',
      );
    });

    test('normalizes a code a messaging app mangled', () {
      // Lowercased by an autocorrect, and with the punctuation a chat client
      // glued to the end of the link.
      expect(
        locationFromDeepLink(Uri.parse('https://speedquiz.app/q/bcd-234')),
        '/studio/code/BCD234',
      );
    });

    test('rejects anything that is not a whole code', () {
      for (final url in [
        'https://speedquiz.app/q/BCD',
        'https://speedquiz.app/q/BCD2345678',
        'https://speedquiz.app/q/AEIOU1',
      ]) {
        expect(
          locationFromDeepLink(Uri.parse(url)),
          isNull,
          reason: '$url is not a valid share code',
        );
      }
    });

    test('does not swallow the result links it sits next to', () {
      expect(
        locationFromDeepLink(Uri.parse('https://speedquiz.app/r/abc-123')),
        '/share/results/abc-123',
      );
    });
  });

  group('copy', () {
    test('every studio string is translated into Devanagari', () {
      final hi = stringsFor(AppLanguage.hindi);
      final samples = <String>[
        hi.studioTitle,
        hi.studioHeadline,
        hi.studioCreate,
        hi.studioOpenWithCode,
        hi.homeMakeQuiz,
        hi.editorNewTitle,
        hi.editorPublish,
        hi.editorAiDraft,
        hi.questionPromptLabel,
        hi.questionOptionsHint,
        hi.aiDraftTitle,
        hi.quizPlaySolo,
        hi.quizChallengeFriend,
        hi.quizLeaderboardTitle,
        hi.quizReportTitle,
        hi.resultsCustomQuiz,
        hi.quizStatusDraft,
        hi.quizVisibilityLink,
      ];
      for (final sample in samples) {
        expect(
          sample,
          matches(_devanagari),
          reason: '"$sample" reads as untranslated English',
        );
      }
    });

    test('no language leaves a studio string empty', () {
      for (final language in AppLanguage.values) {
        final l10n = stringsFor(language);
        final values = <String>[
          l10n.studioTitle,
          l10n.studioMine,
          l10n.studioShared,
          l10n.studioEmptyBody,
          l10n.editorAddQuestion,
          l10n.editorSaved,
          l10n.questionCorrect,
          l10n.aiDraftGenerate,
          l10n.quizShare,
          l10n.quizNoPlaysYet,
          l10n.resultsXpSuppressed,
        ];
        expect(values.every((v) => v.trim().isNotEmpty), isTrue);
      }
    });

    test('interpolations survive translation', () {
      for (final language in AppLanguage.values) {
        final l10n = stringsFor(language);
        expect(l10n.studioSlotsLeft(2, 3), contains('2'));
        expect(l10n.editorQuestionsCounter(4, 20), contains('20'));
        expect(l10n.quizShareMessage('Films', 'BCD234'), contains('BCD234'));
        expect(l10n.quizShareMessage('Films', 'BCD234'), contains('Films'));
        expect(l10n.quizYourBest('4,200'), contains('4,200'));
        expect(l10n.quizByAuthor('Ravi'), contains('Ravi'));
        expect(l10n.aiDraftRemaining(3), contains('3'));
      }
    });

    test('every studio error code has its own sentence', () {
      for (final language in AppLanguage.values) {
        final l10n = stringsFor(language);
        final generic = l10n.quizError('not_a_real_code');
        for (final code in [
          'too_few_questions',
          'question_limit_exceeded',
          'quiz_limit_reached',
          'duplicate_question',
          'quiz_has_plays',
          'quiz_not_found',
          'quiz_archived',
          'quiz_archived_owner',
          'quiz_not_published',
          'quiz_empty',
          'quiz_too_short_to_challenge',
          'invalid_code',
          'ai_draft_limit',
          'ai_draft_failed',
          'cannot_report_own',
        ]) {
          expect(
            l10n.quizError(code),
            isNot(generic),
            reason: '$code falls through to the generic network message',
          );
        }
      }
    });

    test('an unmapped code still says something useful', () {
      // The table falls through to `matchError`, which itself falls through to
      // the network copy — a blank string here would be a silent failure.
      for (final language in AppLanguage.values) {
        expect(stringsFor(language).quizError('brand_new_code').trim(), isNotEmpty);
      }
    });
  });

  group('studio hub', () {
    testWidgets('lists your quizzes and the ones shared with you', (
      tester,
    ) async {
      await _pump(
        tester,
        const StudioScreen(),
        library: CustomQuizLibrary.fromJson({
          'mine': [_quizJson(title: 'Bollywood 2000s')],
          'shared': [
            _quizJson(
              id: 'q2',
              title: 'Cricket Trivia',
              isOwner: false,
              myBest: 1500,
            ),
          ],
          'remaining_slots': 2,
          'max_questions': 20,
        }),
      );

      expect(find.text('Bollywood 2000s'), findsOneWidget);
      expect(find.text('Cricket Trivia'), findsOneWidget);
      expect(find.text('Your quizzes'), findsOneWidget);
      expect(find.text('Shared with you'), findsOneWidget);
    });

    testWidgets('an empty studio explains what to do next', (tester) async {
      await _pump(
        tester,
        const StudioScreen(),
        library: const CustomQuizLibrary(
          mine: [],
          shared: [],
          remainingSlots: 3,
          maxQuestions: 20,
        ),
      );
      expect(find.text('Nothing here yet'), findsOneWidget);
      expect(find.text('Create a quiz'), findsOneWidget);
    });

    testWidgets('lays out in Hindi', (tester) async {
      await _pump(
        tester,
        const StudioScreen(),
        language: AppLanguage.hindi,
        library: CustomQuizLibrary.fromJson({
          'mine': [_quizJson()],
          'shared': [],
          'remaining_slots': 2,
          'max_questions': 20,
        }),
      );
      // The title appears in the header and again on the hero badge.
      expect(find.text('क्विज़ स्टूडियो'), findsWidgets);
      expect(find.text('क्विज़ बनाएँ'), findsOneWidget);
    });

    testWidgets('lays out in light theme', (tester) async {
      await _pump(
        tester,
        const StudioScreen(),
        brightness: Brightness.light,
        library: CustomQuizLibrary.fromJson({
          'mine': [_quizJson()],
          'shared': [],
          'remaining_slots': 0,
          'max_questions': 20,
        }),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('editor', () {
    testWidgets('a brand-new quiz opens on an empty form', (tester) async {
      await _pump(
        tester,
        const QuizEditorScreen(),
        library: const CustomQuizLibrary(
          mine: [],
          shared: [],
          remainingSlots: 3,
          maxQuestions: 20,
        ),
      );
      expect(find.text('New quiz'), findsWidgets);
      expect(find.text('No questions yet'), findsOneWidget);
      // Nothing to publish yet, so the action is present but inert.
      final publish = tester.widget<SqButton>(
        find.widgetWithText(SqButton, 'Publish'),
      );
      expect(publish.onPressed, isNull);
    });

    testWidgets('an existing quiz lists its questions with the answer key', (
      tester,
    ) async {
      await _pump(
        tester,
        const QuizEditorScreen(quizId: 'q1'),
        library: const CustomQuizLibrary(
          mine: [],
          shared: [],
          remainingSlots: 2,
          maxQuestions: 20,
        ),
        quiz: CustomQuiz.fromJson({
          ..._quizJson(status: 'draft', questionCount: 1),
          'questions': [
            {
              'id': 'qq1',
              'position': 0,
              'prompt': 'Which film won Best Picture in 2004?',
              'options': ['Lagaan', 'Devdas', 'Black', 'Swades'],
              'correct_option_index': 2,
              'difficulty': 'medium',
            },
          ],
        }),
      );
      expect(find.text('Which film won Best Picture in 2004?'), findsOneWidget);
      expect(find.text('Black'), findsOneWidget);
    });

    testWidgets('lays out in Hindi', (tester) async {
      await _pump(
        tester,
        const QuizEditorScreen(),
        language: AppLanguage.hindi,
        library: const CustomQuizLibrary(
          mine: [],
          shared: [],
          remainingSlots: 3,
          maxQuestions: 20,
        ),
      );
      // Asserted on the header and the action bar, both of which are always
      // laid out. The add-question button lives in the list's footer sliver,
      // which is only built once it scrolls into view.
      expect(find.text('नई क्विज़'), findsOneWidget);
      expect(find.text('प्रकाशित करें'), findsOneWidget);
    });
  });

  group('quiz detail', () {
    testWidgets('a playable quiz offers every mode and a board', (tester) async {
      await _pump(
        tester,
        const QuizDetailScreen(quizId: 'q1'),
        library: const CustomQuizLibrary(
          mine: [],
          shared: [],
          remainingSlots: 2,
          maxQuestions: 20,
        ),
        quiz: CustomQuiz.fromJson(_quizJson(isOwner: false)),
        board: const QuizLeaderboard(
          quizId: 'q1',
          entries: [],
          totalPlayers: 0,
        ),
      );
      expect(find.text('Play solo'), findsOneWidget);
      expect(find.text('Challenge a friend'), findsOneWidget);
      // The three modes survive onto a custom quiz, which is the whole point.
      expect(find.text('Casual'), findsOneWidget);
      expect(find.text('Speedrun'), findsOneWidget);
      expect(find.text('Survival'), findsOneWidget);
      expect(find.text('Nobody has played it yet. Go first.'), findsOneWidget);
    });

    testWidgets('a draft tells its author to publish before sharing', (
      tester,
    ) async {
      await _pump(
        tester,
        const QuizDetailScreen(quizId: 'q1'),
        library: const CustomQuizLibrary(
          mine: [],
          shared: [],
          remainingSlots: 2,
          maxQuestions: 20,
        ),
        quiz: CustomQuiz.fromJson(_quizJson(status: 'draft', code: null)),
        board: const QuizLeaderboard(
          quizId: 'q1',
          entries: [],
          totalPlayers: 0,
        ),
      );
      expect(
        find.text('This is a draft. Publish it to share or challenge with it.'),
        findsOneWidget,
      );
      expect(find.text('Play solo'), findsNothing);
    });

    testWidgets('the board ranks players by their best run', (tester) async {
      await _pump(
        tester,
        const QuizDetailScreen(quizId: 'q1'),
        library: const CustomQuizLibrary(
          mine: [],
          shared: [],
          remainingSlots: 2,
          maxQuestions: 20,
        ),
        quiz: CustomQuiz.fromJson(_quizJson(isOwner: false, myBest: 3100)),
        board: QuizLeaderboard.fromJson({
          'quiz_id': 'q1',
          'entries': [
            {
              'rank': 1,
              'user_id': 'u2',
              'username': 'meera',
              'display_name': 'Meera',
              'best_score': 5200,
              'accuracy': 94.0,
              'played_at': '2026-08-20T10:00:00Z',
            },
          ],
          'total_players': 4,
        }),
      );
      expect(find.text('Meera'), findsOneWidget);
      expect(find.text('5,200'), findsOneWidget);
    });
  });

}

/// Serves one canned quiz wherever a screen would otherwise call the API.
class _FakeQuizRepo extends CustomQuizRepository {
  _FakeQuizRepo(this.quiz) : super(Dio());

  final CustomQuiz quiz;

  @override
  Future<CustomQuiz> fetchQuiz(String quizId) async => quiz;
}

/// Pumps a studio screen against a canned library and asserts it laid out.
Future<void> _pump(
  WidgetTester tester,
  Widget screen, {
  required CustomQuizLibrary library,
  CustomQuiz? quiz,
  QuizLeaderboard? board,
  Brightness brightness = Brightness.dark,
  AppLanguage language = AppLanguage.english,
}) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        customQuizLibraryProvider.overrideWith((ref) async => library),
        if (quiz != null) ...[
          customQuizProvider.overrideWith((ref, id) async => quiz),
          // The editor fetches through the repository rather than the
          // provider, so the seam has to be stubbed here too — otherwise it
          // reaches for the network and the test hangs on a real HttpClient.
          customQuizRepositoryProvider.overrideWithValue(_FakeQuizRepo(quiz)),
        ],
        if (board != null)
          quizLeaderboardProvider.overrideWith((ref, id) async => board),
      ],
      child: MaterialApp(
        theme: brightness == Brightness.dark
            ? AppTheme.dark(script: language.script)
            : AppTheme.light(script: language.script),
        locale: language.locale,
        localizationsDelegates: const [
          SqLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLanguage.supportedLocales,
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: screen,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  expect(tester.takeException(), isNull);
}
