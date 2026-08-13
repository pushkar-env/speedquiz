import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:speedquiz/core/routing/nav.dart';
import 'package:speedquiz/core/routing/page_transitions.dart';
import 'package:speedquiz/features/auth/presentation/auth_controller.dart';
import 'package:speedquiz/features/custom_topics/presentation/custom_topic_screen.dart';
import 'package:speedquiz/features/entitlements/presentation/premium_paywall_sheet.dart';
import 'package:speedquiz/features/explore/presentation/explore_screen.dart';
import 'package:speedquiz/features/home/presentation/home_screen.dart';
import 'package:speedquiz/features/leaderboard/presentation/leaderboard_screen.dart';
import 'package:speedquiz/features/multiplayer/presentation/battle_hub_screen.dart';
import 'package:speedquiz/features/multiplayer/presentation/battle_screen.dart';
import 'package:speedquiz/features/multiplayer/presentation/friends_screen.dart';
import 'package:speedquiz/features/multiplayer/presentation/notifications_screen.dart';
import 'package:speedquiz/features/multiplayer/presentation/ranked_screen.dart';
import 'package:speedquiz/features/multiplayer/presentation/username_edit_screen.dart';
import 'package:speedquiz/features/onboarding/domain/onboarding_state.dart';
import 'package:speedquiz/features/onboarding/presentation/landing_screen.dart';
import 'package:speedquiz/features/onboarding/presentation/onboarding_controller.dart';
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
  static const username = '/profile/username';
  static const notifications = '/battle/notifications';

  /// Deep-link target for a match. Push notifications carry exactly this path,
  /// so the shape lives here rather than being spelled out at each call site.
  static String matchPath(String matchId) => '/battle/match/$matchId';
  static const profileEdit = '/profile/edit';
  static const achievements = '/profile/achievements';
  static const stats = '/profile/stats';
  static const premium = '/premium';
  static const settings = '/settings';
  static const quizSetup = '/quiz/setup';
  static const quizPlay = '/quiz/play';
  static const customTopic = '/custom-topic';
  static const sharePrefix = '/share/';
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
          // A first run answers two questions before it is offered an account;
          // everyone else goes straight to the ways in.
          if (ref.read(onboardingControllerProvider).isNeeded) {
            return location == Routes.onboarding ? null : Routes.onboarding;
          }
          return location == Routes.landing ? null : Routes.landing;
        case AuthAuthenticated():
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
          child: const SqBackGuard(
            fallback: Routes.battle,
            child: FriendsScreen(),
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
        pageBuilder: (context, state) => sqSharedAxisPage(
          state: state,
          child: SqBackGuard(
            fallback: Routes.battle,
            child: BattleScreen(matchId: state.pathParameters['matchId']!),
          ),
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
      ref.listen<OnboardingState>(
        onboardingControllerProvider,
        (previous, next) {
          if (previous?.status != next.status) notifyListeners();
        },
      ),
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
