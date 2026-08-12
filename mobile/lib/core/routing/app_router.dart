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
import 'package:speedquiz/features/onboarding/presentation/landing_screen.dart';
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
  static const landing = '/landing';
  static const home = '/home';
  static const explore = '/explore';
  static const leaderboard = '/leaderboard';
  static const profile = '/profile';
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
  final refresh = _AuthRefresh(ref);
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
          return location == Routes.landing ? null : Routes.landing;
        case AuthAuthenticated():
          return (location == Routes.splash || location == Routes.landing)
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

class _AuthRefresh extends ChangeNotifier {
  _AuthRefresh(this.ref) {
    _sub = ref.listen<AuthState>(authControllerProvider, (previous, next) {
      notifyListeners();
    });
  }

  final Ref ref;
  late final ProviderSubscription<AuthState> _sub;

  @override
  void dispose() {
    _sub.close();
    super.dispose();
  }
}
