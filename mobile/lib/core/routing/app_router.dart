import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:speedquiz/core/routing/nav.dart';
import 'package:speedquiz/core/routing/page_transitions.dart';
import 'package:speedquiz/features/exams/presentation/exams_screen.dart';
import 'package:speedquiz/features/exams/presentation/mock_result_screen.dart';
import 'package:speedquiz/features/exams/presentation/mock_test_screen.dart';
import 'package:speedquiz/features/auth/presentation/auth_controller.dart';
import 'package:speedquiz/features/custom_topics/presentation/custom_topic_screen.dart';
import 'package:speedquiz/features/entitlements/presentation/premium_paywall_sheet.dart';
import 'package:speedquiz/features/explore/presentation/explore_screen.dart';
import 'package:speedquiz/features/home/presentation/home_screen.dart';
import 'package:speedquiz/features/leaderboard/presentation/leaderboard_screen.dart';
import 'package:speedquiz/features/multiplayer/presentation/battle_hub_screen.dart';
import 'package:speedquiz/features/multiplayer/presentation/battle_screen.dart';
import 'package:speedquiz/features/multiplayer/presentation/friends_screen.dart';
import 'package:speedquiz/features/multiplayer/presentation/match_history_screen.dart';
import 'package:speedquiz/features/multiplayer/presentation/notifications_screen.dart';
import 'package:speedquiz/features/multiplayer/presentation/ranked_screen.dart';
import 'package:speedquiz/features/multiplayer/presentation/username_edit_screen.dart';
import 'package:speedquiz/features/onboarding/presentation/landing_screen.dart';
import 'package:speedquiz/features/onboarding/presentation/onboarding_screen.dart';
import 'package:speedquiz/features/onboarding/presentation/splash_screen.dart';
import 'package:speedquiz/features/profile/presentation/achievements_screen.dart';
import 'package:speedquiz/features/profile/presentation/profile_edit_screen.dart';
import 'package:speedquiz/features/profile/presentation/profile_screen.dart';
import 'package:speedquiz/features/profile/presentation/settings_screen.dart';
import 'package:speedquiz/features/profile/presentation/stats_screen.dart';
import 'package:speedquiz/features/quiz/domain/quiz_models.dart';
import 'package:speedquiz/features/quiz/presentation/quiz_play_screen.dart';
import 'package:speedquiz/features/quiz/presentation/quiz_results_loader_screen.dart';
import 'package:speedquiz/features/quiz/presentation/quiz_setup_screen.dart';
import 'package:speedquiz/features/share/presentation/shared_result_screen.dart';
import 'package:speedquiz/features/shell/presentation/main_shell.dart';
import 'package:speedquiz/features/studio/presentation/quiz_code_screen.dart';
import 'package:speedquiz/features/studio/presentation/quiz_detail_screen.dart';
import 'package:speedquiz/features/studio/presentation/quiz_editor_screen.dart';
import 'package:speedquiz/features/studio/presentation/studio_screen.dart';

abstract final class Routes {
  static const splash = '/splash';
  static const onboarding = '/onboarding';
  static const landing = '/landing';
  static const home = '/home';
  static const explore = '/explore';
  static const battle = '/battle';
  static const leaderboard = '/leaderboard';
  static const profile = '/profile';
  static const friends = '/battle/friends';
  static const ranked = '/battle/ranked';
  static const matchHistory = '/battle/history';
  static const username = '/profile/username';
  static const notifications = '/battle/notifications';

  /// Deep-link target for a match. Push notifications carry exactly this path,
  /// so the shape lives here rather than being spelled out at each call site.
  static String matchPath(String matchId) => '/battle/match/$matchId';

  /// The five bottom-bar destinations.
  ///
  /// A notification may point at one of these — an on-device reminder sends
  /// the player to Home or to quiz setup — and a tab has to be *switched to*,
  /// not pushed: pushing one stacks a second copy of the shell on top of the
  /// first. See `DeepLinkListener`.
  static const tabRoots = <String>[
    home,
    explore,
    battle,
    leaderboard,
    profile,
  ];

  static bool isTabRoot(String location) => tabRoots.contains(location);
  static const profileEdit = '/profile/edit';
  static const achievements = '/profile/achievements';
  static const stats = '/profile/stats';
  static const premium = '/premium';
  static const settings = '/settings';
  static const quizSetup = '/quiz/setup';
  static const quizPlay = '/quiz/play';
  static const customTopic = '/custom-topic';
  static const sharePrefix = '/share/';

  // --- Quiz studio -------------------------------------------------------
  static const studio = '/studio';
  static const quizEditorNew = '/studio/new';

  /// A quiz someone can play, share or challenge with.
  static String quizDetailPath(String quizId) => '/studio/quiz/$quizId';

  /// The author's editor for one quiz.
  static String quizEditorPath(String quizId) => '/studio/quiz/$quizId/edit';

  /// A share code arriving from outside the app. The studio resolves it,
  /// which is also what grants standing access.
  static String quizCodePath(String code) => '/studio/code/$code';

  // --- Exam mode ---------------------------------------------------------
  static const exams = '/exams';

  static String examPapersPath(String examSlug) => '/exams/$examSlug';

  /// Opens a paper and starts (or resumes) an attempt on it.
  static String mockTestPath(String paperId) => '/exams/paper/$paperId/test';

  static String mockResultPath(String attemptId) =>
      '/exams/attempt/$attemptId/result';
}

final _rootNavigatorKey = GlobalKey<NavigatorState>();
final _shellNavigatorKey = GlobalKey<NavigatorState>();

final appRouterProvider = Provider<GoRouter>((ref) {
  final refresh = _RouteRefresh(ref);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: Routes.splash,
    refreshListenable: refresh,
    redirect: (context, state) {
      final auth = ref.read(authControllerProvider);
      final location = state.matchedLocation;

      // Public share cards stay reachable without a session — a deep link
      // from a friend must never bounce to the landing screen.
      if (location.startsWith(Routes.sharePrefix)) return null;

      switch (auth) {
        case AuthBooting():
          return location == Routes.splash ? null : Routes.splash;
        case AuthSignedOut():
          // Always the ways in. Onboarding used to sit in front of this, which
          // meant a returning player was asked to choose a name and a language
          // before they had a chance to say they already had both.
          return location == Routes.landing ? null : Routes.landing;
        case AuthAuthenticated(:final user):
          // Now the flow lives here, and only for an account that is genuinely
          // new — a fresh guest or a first Google sign-in. See
          // `AuthUser.needsOnboarding`.
          if (user.needsOnboarding) {
            return location == Routes.onboarding ? null : Routes.onboarding;
          }
          return (location == Routes.splash ||
                  location == Routes.landing ||
                  location == Routes.onboarding)
              ? Routes.home
              : null;
      }
    },
    routes: [
      GoRoute(
        path: Routes.splash,
        pageBuilder: (context, state) =>
            sqFadeThroughPage(state: state, child: const SplashScreen()),
      ),
      GoRoute(
        path: Routes.onboarding,
        pageBuilder: (context, state) =>
            sqFadeThroughPage(state: state, child: const OnboardingScreen()),
      ),
      GoRoute(
        path: Routes.landing,
        pageBuilder: (context, state) =>
            sqFadeThroughPage(state: state, child: const LandingScreen()),
      ),
      ShellRoute(
        navigatorKey: _shellNavigatorKey,
        builder: (context, state, child) => MainShell(child: child),
        routes: [
          GoRoute(
            path: Routes.home,
            pageBuilder: (context, state) =>
                sqFadeThroughPage(state: state, child: const HomeScreen()),
          ),
          GoRoute(
            path: Routes.explore,
            pageBuilder: (context, state) =>
                sqFadeThroughPage(state: state, child: const ExploreScreen()),
          ),
          GoRoute(
            path: Routes.battle,
            pageBuilder: (context, state) =>
                sqFadeThroughPage(state: state, child: const BattleHubScreen()),
          ),
          GoRoute(
            path: Routes.leaderboard,
            pageBuilder: (context, state) => sqFadeThroughPage(
              state: state,
              child: const LeaderboardScreen(),
            ),
          ),
          GoRoute(
            path: Routes.profile,
            pageBuilder: (context, state) =>
                sqFadeThroughPage(state: state, child: const ProfileScreen()),
          ),
        ],
      ),
      // Profile sub-screens sit on the root navigator so they cover the
      // bottom bar — they are destinations, not tabs.
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: Routes.profileEdit,
        pageBuilder: (context, state) => sqSharedAxisPage(
          state: state,
          child: const SqBackGuard(
            fallback: Routes.profile,
            child: ProfileEditScreen(),
          ),
        ),
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: Routes.achievements,
        pageBuilder: (context, state) => sqSharedAxisPage(
          state: state,
          child: const SqBackGuard(
            fallback: Routes.profile,
            child: AchievementsScreen(),
          ),
        ),
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: Routes.stats,
        pageBuilder: (context, state) => sqSharedAxisPage(
          state: state,
          child: const SqBackGuard(
            fallback: Routes.profile,
            child: StatsScreen(),
          ),
        ),
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: Routes.premium,
        pageBuilder: (context, state) => sqModalPage(
          state: state,
          child: const SqBackGuard(
            fallback: Routes.profile,
            child: PremiumScreen(),
          ),
        ),
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: Routes.settings,
        pageBuilder: (context, state) => sqSharedAxisPage(
          state: state,
          child: const SqBackGuard(
            fallback: Routes.profile,
            child: SettingsScreen(),
          ),
        ),
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: Routes.quizSetup,
        pageBuilder: (context, state) {
          final extra = state.extra as Map<String, dynamic>?;
          return sqModalPage(
            state: state,
            child: SqBackGuard(
              fallback: Routes.home,
              child: QuizSetupScreen(
                initialTopicId: extra?['topicId'] as String?,
                initialTopicName: extra?['topicName'] as String?,
              ),
            ),
          );
        },
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: Routes.customTopic,
        pageBuilder: (context, state) => sqModalPage(
          state: state,
          child: const SqBackGuard(
            fallback: Routes.home,
            child: CustomTopicScreen(),
          ),
        ),
      ),
      // Exam mode sits on the root navigator for the same reason the studio
      // does, and one more: a live mock test has a running clock, so a stray
      // tap on the bottom bar must not be able to walk away from it.
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: Routes.exams,
        builder: (context, state) => const ExamsScreen(),
        routes: [
          GoRoute(
            path: 'paper/:paperId/test',
            parentNavigatorKey: _rootNavigatorKey,
            builder: (context, state) => MockTestScreen(
              paperId: state.pathParameters['paperId']!,
            ),
          ),
          GoRoute(
            path: 'attempt/:attemptId/result',
            parentNavigatorKey: _rootNavigatorKey,
            builder: (context, state) => MockResultScreen(
              attemptId: state.pathParameters['attemptId']!,
            ),
          ),
          GoRoute(
            path: ':examSlug',
            parentNavigatorKey: _rootNavigatorKey,
            builder: (context, state) => ExamPapersScreen(
              examSlug: state.pathParameters['examSlug']!,
            ),
          ),
        ],
      ),
      // The studio sits on the root navigator: writing a quiz is a
      // destination, not a tab, and a half-written question must not be
      // interruptible by a stray tap on the bottom bar.
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: Routes.studio,
        pageBuilder: (context, state) => sqModalPage(
          state: state,
          child: const SqBackGuard(
            fallback: Routes.home,
            child: StudioScreen(),
          ),
        ),
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: Routes.quizEditorNew,
        pageBuilder: (context, state) => sqSharedAxisPage(
          state: state,
          // No SqBackGuard: the editor registers its own PopScope so leaving
          // flushes whatever metadata has not been written yet, and two
          // PopScopes on one route both fire.
          child: const QuizEditorScreen(),
        ),
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/studio/quiz/:quizId/edit',
        pageBuilder: (context, state) => sqSharedAxisPage(
          state: state,
          child: QuizEditorScreen(quizId: state.pathParameters['quizId']!),
        ),
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/studio/quiz/:quizId',
        pageBuilder: (context, state) => sqSharedAxisPage(
          state: state,
          child: SqBackGuard(
            fallback: Routes.studio,
            child: QuizDetailScreen(quizId: state.pathParameters['quizId']!),
          ),
        ),
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/studio/code/:code',
        pageBuilder: (context, state) => sqSharedAxisPage(
          state: state,
          child: SqBackGuard(
            fallback: Routes.studio,
            child: QuizCodeScreen(code: state.pathParameters['code']!),
          ),
        ),
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: Routes.quizPlay,
        pageBuilder: (context, state) {
          final extra = state.extra as Map<String, dynamic>? ?? {};
          final sessionExtra = extra['session'];
          return sqSharedAxisPage(
            state: state,
            child: QuizPlayScreen(
              topicId: extra['topicId'] as String,
              topicName: extra['topicName'] as String?,
              mode: extra['mode'] as String? ?? 'casual',
              difficulty: extra['difficulty'] as String? ?? 'medium',
              adaptive: extra['adaptive'] as bool? ?? false,
              // Absent for the daily and for deep links, where the server
              // picks the player's last language rather than the client.
              language: extra['language'] as String?,
              existingSession: sessionExtra is QuizSession
                  ? sessionExtra
                  : null,
            ),
          );
        },
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/quiz/results/:sessionId',
        pageBuilder: (context, state) {
          final extra = state.extra;
          // A finished run passes QuizResultArgs; a deep link or cold start
          // passes nothing and the screen refetches.
          final args = switch (extra) {
            QuizResultArgs() => extra,
            QuizResult() => QuizResultArgs(result: extra),
            _ => null,
          };
          return sqSharedAxisPage(
            state: state,
            child: SqBackGuard(
              fallback: Routes.home,
              child: QuizResultsLoaderScreen(
                sessionId: state.pathParameters['sessionId']!,
                args: args,
              ),
            ),
          );
        },
      ),
      // Battle destinations sit on the root navigator: they cover the bottom
      // bar because they are places you go, not tabs you switch between. The
      // match route in particular must not be interruptible by a tab tap
      // while a round clock is running.
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: Routes.friends,
        pageBuilder: (context, state) => sqSharedAxisPage(
          state: state,
          child: SqBackGuard(
            fallback: Routes.battle,
            // A friend-request notification points at `?tab=requests`, so
            // tapping it lands on the tab the request is actually on.
            child: FriendsScreen(
              openRequests: state.uri.queryParameters['tab'] == 'requests',
            ),
          ),
        ),
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: Routes.notifications,
        pageBuilder: (context, state) => sqSharedAxisPage(
          state: state,
          child: const SqBackGuard(
            fallback: Routes.battle,
            child: NotificationsScreen(),
          ),
        ),
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: Routes.matchHistory,
        pageBuilder: (context, state) => sqSharedAxisPage(
          state: state,
          child: const SqBackGuard(
            fallback: Routes.battle,
            child: MatchHistoryScreen(),
          ),
        ),
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: Routes.ranked,
        pageBuilder: (context, state) => sqSharedAxisPage(
          state: state,
          child: const SqBackGuard(
            fallback: Routes.battle,
            child: RankedScreen(),
          ),
        ),
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/battle/match/:matchId',
        // No SqBackGuard here, unlike every other root route. BattleScreen
        // registers its own PopScope — back mid-match has to confirm a forfeit
        // and then *stay* on the result — and two PopScopes on one route both
        // fire, so the guard walked the player out from under the dialog. The
        // screen does the guard's `popOrGo` itself instead; see its PopScope.
        pageBuilder: (context, state) => sqSharedAxisPage(
          state: state,
          child: BattleScreen(matchId: state.pathParameters['matchId']!),
        ),
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: Routes.username,
        pageBuilder: (context, state) => sqSharedAxisPage(
          state: state,
          child: const SqBackGuard(
            fallback: Routes.profile,
            child: UsernameEditScreen(),
          ),
        ),
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/share/results/:sessionId',
        pageBuilder: (context, state) => sqSharedAxisPage(
          state: state,
          child: SqBackGuard(
            fallback: Routes.home,
            child: SharedResultScreen(
              sessionId: state.pathParameters['sessionId']!,
            ),
          ),
        ),
      ),
    ],
  );
});

/// Re-runs the redirect whenever anything it reads changes.
///
/// Onboarding is in here alongside auth because finishing the flow moves a
/// still-signed-out player from `/onboarding` to `/landing` — a route change
/// with no auth change behind it.
class _RouteRefresh extends ChangeNotifier {
  _RouteRefresh(this.ref) {
    _subs = [
      ref.listen<AuthState>(
        authControllerProvider,
        (previous, next) => notifyListeners(),
      ),
      // Onboarding is no longer a routing input of its own: the flow runs
      // behind sign-in and finishes by marking the *account* onboarded, which
      // arrives through the auth listener above.
    ];
  }

  final Ref ref;
  late final List<ProviderSubscription<Object?>> _subs;

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.close();
    }
    super.dispose();
  }
}
