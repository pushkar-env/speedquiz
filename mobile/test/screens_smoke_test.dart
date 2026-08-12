import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/achievements/data/achievements_repository.dart';
import 'package:speedquiz/features/achievements/domain/achievement_models.dart';
import 'package:speedquiz/features/auth/data/auth_repository.dart';
import 'package:speedquiz/features/auth/data/auth_token_store.dart';
import 'package:speedquiz/features/auth/data/google_auth_service.dart';
import 'package:speedquiz/features/auth/domain/auth_models.dart';
import 'package:speedquiz/features/auth/presentation/auth_controller.dart';
import 'package:speedquiz/features/daily/data/daily_repository.dart';
import 'package:speedquiz/features/daily/domain/daily_models.dart';
import 'package:speedquiz/features/entitlements/data/entitlements_repository.dart';
import 'package:speedquiz/features/entitlements/domain/entitlement_models.dart';
import 'package:speedquiz/features/explore/presentation/explore_screen.dart';
import 'package:speedquiz/features/home/presentation/home_screen.dart';
import 'package:speedquiz/features/leaderboard/data/leaderboard_repository.dart';
import 'package:speedquiz/features/leaderboard/domain/leaderboard_models.dart';
import 'package:speedquiz/features/leaderboard/presentation/leaderboard_screen.dart';
import 'package:speedquiz/features/profile/data/profile_repository.dart';
import 'package:speedquiz/features/profile/domain/profile_models.dart';
import 'package:speedquiz/features/profile/presentation/achievements_screen.dart';
import 'package:speedquiz/features/profile/presentation/profile_edit_screen.dart';
import 'package:speedquiz/features/profile/presentation/profile_screen.dart';
import 'package:speedquiz/features/profile/presentation/settings_screen.dart';
import 'package:speedquiz/features/profile/presentation/stats_screen.dart';
import 'package:speedquiz/features/quiz/domain/quiz_models.dart';
import 'package:speedquiz/features/quiz/presentation/quiz_results_screen.dart';
import 'package:speedquiz/features/quiz/presentation/quiz_setup_screen.dart';
import 'package:speedquiz/features/topics/data/topics_repository.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

const _user = AuthUser(
  id: '00000000-0000-0000-0000-000000000001',
  email: 'player@example.com',
  username: 'player_test',
  displayName: 'Player Test',
  isGuest: false,
  isPremium: false,
  level: 4,
  xp: 900,
  coins: 120,
  currentStreak: 3,
  dailyStreak: 3,
  bestStreak: 11,
  onboardingCompleted: true,
  themePreference: 'dark',
  avatarId: 'avatar_01',
);

const _science = TopicCategory(
  slug: 'science',
  name: 'Science',
  icon: '🔬',
  sortOrder: 10,
);
const _technology = TopicCategory(
  slug: 'technology',
  name: 'Technology',
  icon: '💻',
  sortOrder: 20,
);

const _topics = [
  TopicItem(
    id: 't1',
    slug: 'astronomy',
    name: 'Astronomy',
    icon: '🌌',
    questionCount: 940,
    category: _science,
    isTrending: true,
  ),
  TopicItem(
    id: 't2',
    slug: 'programming',
    name: 'Programming',
    icon: '💻',
    questionCount: 610,
    category: _technology,
  ),
  TopicItem(
    id: 't3',
    slug: 'deep-sea',
    name: 'Deep Sea',
    icon: '🐙',
    questionCount: 0,
    category: _science,
  ),
];

const _daily = DailyChallengeInfo(
  id: 'd1',
  challengeDate: '2026-08-11',
  title: 'Daily Challenge',
  topicId: 't1',
  topicName: 'Astronomy',
  topicIcon: '🌌',
  difficulty: 'medium',
  questionCount: 10,
  status: 'available',
);

const _board = LeaderboardBoard(
  scope: 'weekly',
  periodKey: '2026-W33',
  total: 4,
  me: LeaderboardMe(rank: 4, score: 4200, username: 'player_test'),
  items: [
    LeaderboardEntry(
      rank: 1,
      userId: 'u1',
      username: 'nova',
      score: 12800,
      isMe: false,
    ),
    LeaderboardEntry(
      rank: 2,
      userId: 'u2',
      username: 'quark',
      score: 11100,
      isMe: false,
    ),
    LeaderboardEntry(
      rank: 3,
      userId: 'u3',
      username: 'lumen',
      score: 9050,
      isMe: false,
    ),
    LeaderboardEntry(
      rank: 4,
      userId: '00000000-0000-0000-0000-000000000001',
      username: 'player_test',
      score: 4200,
      isMe: true,
    ),
  ],
);

const _achievements = AchievementList(
  unlockedCount: 1,
  total: 2,
  items: [
    AchievementItem(
      id: 'a1',
      code: 'first_run',
      name: 'First Run',
      description: 'Finish your first quiz',
      icon: 'flag',
      category: 'general',
      xpReward: 50,
      coinsReward: 5,
      sortOrder: 1,
      unlocked: true,
    ),
    AchievementItem(
      id: 'a2',
      code: 'streak_10',
      name: 'On Fire',
      description: 'Hit a streak of 10',
      icon: 'fire',
      category: 'streaks',
      xpReward: 120,
      coinsReward: 20,
      sortOrder: 2,
      unlocked: false,
    ),
  ],
);

const _profile = UserProfile(
  userId: '00000000-0000-0000-0000-000000000001',
  username: 'player_test',
  displayName: 'Player Test',
  avatarId: 'avatar_03',
  level: 4,
  xp: 900,
  coins: 120,
  currentStreak: 3,
  bestStreak: 11,
  dailyStreak: 3,
  isPremium: false,
  statistics: ProfileStats(
    totalQuizzes: 24,
    totalQuestions: 320,
    totalCorrect: 268,
    totalIncorrect: 52,
    accuracy: 83.75,
    bestScore: 9400,
    bestStreak: 11,
    averageAnswerMs: 4300,
    topicMastery: {'t1': 78.0, 't2': 44.5},
  ),
);

const _entitlements = EntitlementsMe(
  isPremium: false,
  enforceCaps: false,
  customTopicsUnlimited: true,
  devToggleAllowed: false,
);

final _result = QuizResult(
  sessionId: 's1',
  topicName: 'Astronomy',
  mode: 'casual',
  difficulty: 'hard',
  finalScore: 8420,
  accuracy: 82.5,
  bestStreak: 9,
  questionsAnswered: 20,
  correctCount: 17,
  incorrectCount: 3,
  averageAnswerMs: 4200,
  xpEarned: 310,
  isPersonalBest: true,
  previousBest: 7100,
  shareText: 'SpeedQuiz — 8420',
  level: 4,
  xp: 900,
  newAchievements: const [
    AchievementUnlock(
      id: 'a1',
      code: 'first_run',
      name: 'First Run',
      description: 'Finish your first quiz',
      icon: 'flag',
      category: 'general',
      xpReward: 50,
      coinsReward: 5,
    ),
  ],
);

class _FakeAuthRepository extends AuthRepository {
  _FakeAuthRepository() : super(Dio(), AuthTokenStore());

  @override
  Future<AuthUser?> fetchMe() async => _user;

  @override
  Future<void> signOut() async {}
}

class _SignedInController extends AuthController {
  _SignedInController() : super(_FakeAuthRepository(), GoogleAuthService()) {
    state = const AuthAuthenticated(_user);
  }

  @override
  Future<void> bootstrap() async => state = const AuthAuthenticated(_user);
}

Widget _app(Widget screen, {Brightness brightness = Brightness.dark}) {
  return ProviderScope(
    overrides: [
      authControllerProvider.overrideWith((ref) => _SignedInController()),
      topicsProvider.overrideWith((ref) async => _topics),
      dailyChallengeProvider.overrideWith((ref) async => _daily),
      achievementsProvider.overrideWith((ref) async => _achievements),
      entitlementsProvider.overrideWith((ref) async => _entitlements),
      leaderboardProvider.overrideWith((ref, scope) async => _board),
      profileProvider.overrideWith((ref) async => _profile),
    ],
    child: MaterialApp(
      theme: brightness == Brightness.dark
          ? AppTheme.dark()
          : AppTheme.light(),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: screen,
        ),
      ),
    ),
  );
}

/// Renders at a realistic phone size — a desktop-sized test surface hides the
/// narrow-column overflows these tests exist to catch.
void _usePhoneSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

/// Pumps a screen and asserts it laid out cleanly. Catches the class of bug
/// that only shows up at runtime: unbounded constraints, overflow, a null
/// dereference inside build.
Future<void> _expectBuilds(
  WidgetTester tester,
  Widget screen, {
  Brightness brightness = Brightness.dark,
}) async {
  _usePhoneSurface(tester);
  await tester.pumpWidget(_app(screen, brightness: brightness));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  expect(tester.takeException(), isNull);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('home builds with live data', (tester) async {
    await _expectBuilds(tester, const HomeScreen());
    expect(find.text('Start a run'), findsOneWidget);
    expect(find.text('PLAY'), findsOneWidget);

    // Home shortcuts must be real, tappable topics — not decorative labels.
    // The rail sits below the fold in a lazy ListView, so it has to be
    // scrolled into existence first.
    await tester.scrollUntilVisible(
      find.text('Astronomy'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Astronomy'), findsWidgets);
  });

  testWidgets('explore groups topics by category and flags trending',
      (tester) async {
    await _expectBuilds(tester, const ExploreScreen());

    // Category rail plus a section header per category.
    expect(find.text('Trending now'), findsOneWidget);
    expect(find.text('Science'), findsWidgets);
    expect(find.text('Technology'), findsWidgets);
    expect(find.text('RANDOM'), findsOneWidget);

    // Unstocked topics are still shown, but separated out. Explore nests
    // horizontal rails, so the target scrollable has to be named explicitly.
    await tester.scrollUntilVisible(
      find.text('Bank filling up'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Bank filling up'), findsOneWidget);
  });

  testWidgets('explore filters to a single category when one is picked',
      (tester) async {
    await _expectBuilds(tester, const ExploreScreen());

    await tester.tap(find.text('Technology').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    // Trending is unfiltered-only, and Science drops out of the results.
    expect(find.text('Trending now'), findsNothing);
    expect(find.text('Programming'), findsOneWidget);
    expect(find.text('Astronomy'), findsNothing);
  });

  testWidgets('leaderboard builds with a podium', (tester) async {
    await _expectBuilds(tester, const LeaderboardScreen());
    expect(find.text('🥇'), findsOneWidget);
    expect(find.text('nova'), findsOneWidget);
  });

  testWidgets('profile hub links out to the detail screens', (tester) async {
    await _expectBuilds(tester, const ProfileScreen());
    expect(find.text('Player Test'), findsOneWidget);

    // Signed-in identity the hub now spells out, rather than only implying.
    expect(find.text('@player_test'), findsOneWidget);
    expect(find.text('player@example.com'), findsOneWidget);

    // The hub itself only summarises; each area has its own screen. The list
    // is lazy, so anything below the fold has to be scrolled to before it
    // exists in the tree at all.
    expect(find.text('Profile details'), findsOneWidget);
    expect(find.text('Achievements'), findsOneWidget);

    for (final label in ['Statistics', 'Go Premium', 'Settings']) {
      await tester.scrollUntilVisible(
        find.text(label),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets('achievements screen lists and filters', (tester) async {
    await _expectBuilds(tester, const AchievementsScreen());
    expect(find.text('1 of 2 unlocked'), findsOneWidget);
    expect(find.text('First Run'), findsOneWidget);
    expect(find.text('On Fire'), findsOneWidget);

    await tester.tap(find.textContaining('Unlocked · 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    expect(find.text('First Run'), findsOneWidget);
    expect(find.text('On Fire'), findsNothing);
  });

  testWidgets('settings screen owns sign out', (tester) async {
    await _expectBuilds(tester, const SettingsScreen());
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Sound effects'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('SIGN OUT'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('SIGN OUT'), findsOneWidget);
  });

  testWidgets('profile edit offers a name field and avatar picker',
      (tester) async {
    await _expectBuilds(tester, const ProfileEditScreen());
    expect(find.text('Display name'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    // Saving is disabled until something actually changes.
    final save = tester.widget<SqButton>(
      find.widgetWithText(SqButton, 'SAVE CHANGES'),
    );
    expect(save.onPressed, isNull);
  });

  testWidgets('quiz setup builds with topics, difficulties and modes',
      (tester) async {
    await _expectBuilds(tester, const QuizSetupScreen());
    // The CTA is sticky and reflects that no topic is chosen yet.
    expect(find.text('PICK A TOPIC'), findsOneWidget);
    // Chips render as "<icon>  <name>".
    expect(find.textContaining('Astronomy'), findsOneWidget);

    // Mode cards sit below the fold; scrolling must reach the last one.
    await tester.scrollUntilVisible(find.text('Sudden Death'), 300);
    expect(find.text('Sudden Death'), findsOneWidget);
  });

  testWidgets('quiz setup preselects a topic passed from Explore',
      (tester) async {
    await _expectBuilds(
      tester,
      const QuizSetupScreen(initialTopicId: 't1', initialTopicName: 'Astronomy'),
    );
    expect(find.text('START · ASTRONOMY'), findsOneWidget);
  });

  testWidgets('stats screen renders lifetime numbers and mastery',
      (tester) async {
    await _expectBuilds(tester, const StatsScreen());
    expect(find.text('Lifetime accuracy'), findsOneWidget);
    expect(find.text('84%'), findsOneWidget);
    // Mastery keys are joined back to topic names.
    expect(find.text('Astronomy'), findsOneWidget);
  });

  testWidgets('results builds with score, stats and unlocks', (tester) async {
    await _expectBuilds(
      tester,
      QuizResultsScreen(args: QuizResultArgs(result: _result)),
    );
    expect(find.text('NEW PERSONAL BEST'), findsOneWidget);
    expect(find.text('First Run'), findsOneWidget);
    // Without a topic id (deep link / cold start) replay falls back to setup.
    expect(find.text('NEW RUN'), findsOneWidget);
    expect(find.text('PLAY AGAIN'), findsNothing);
  });

  testWidgets('results offers instant replay and a level-up callout',
      (tester) async {
    await _expectBuilds(
      tester,
      QuizResultsScreen(
        args: QuizResultArgs(
          result: _result,
          topicId: 't1',
          mode: 'casual',
          difficulty: 'hard',
          leveledUp: true,
        ),
      ),
    );
    expect(find.text('PLAY AGAIN'), findsOneWidget);
    expect(find.textContaining('LEVEL UP'), findsOneWidget);
  });

  testWidgets('home lays out in light theme', (tester) async {
    await _expectBuilds(
      tester,
      const HomeScreen(),
      brightness: Brightness.light,
    );
  });

  testWidgets('explore lays out in light theme', (tester) async {
    await _expectBuilds(
      tester,
      const ExploreScreen(),
      brightness: Brightness.light,
    );
  });

  testWidgets('profile lays out in light theme', (tester) async {
    await _expectBuilds(
      tester,
      const ProfileScreen(),
      brightness: Brightness.light,
    );
  });
}
