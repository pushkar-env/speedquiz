import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:quizverse/features/auth/presentation/auth_controller.dart';
import 'package:quizverse/features/custom_topics/presentation/custom_topic_screen.dart';
import 'package:quizverse/features/explore/presentation/explore_screen.dart';
import 'package:quizverse/features/home/presentation/home_screen.dart';
import 'package:quizverse/features/leaderboard/presentation/leaderboard_screen.dart';
import 'package:quizverse/features/onboarding/presentation/splash_screen.dart';
import 'package:quizverse/features/profile/presentation/profile_screen.dart';
import 'package:quizverse/features/quiz/domain/quiz_models.dart';
import 'package:quizverse/features/quiz/presentation/quiz_play_screen.dart';
import 'package:quizverse/features/quiz/presentation/quiz_results_screen.dart';
import 'package:quizverse/features/quiz/presentation/quiz_setup_screen.dart';
import 'package:quizverse/features/shell/presentation/main_shell.dart';

final _rootNavigatorKey = GlobalKey<NavigatorState>();
final _shellNavigatorKey = GlobalKey<NavigatorState>();

final appRouterProvider = Provider<GoRouter>((ref) {
  final refresh = _AuthRefresh(ref);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: '/splash',
    refreshListenable: refresh,
    redirect: (context, state) {
      final authState = ref.read(authControllerProvider);
      final loggingIn = state.matchedLocation == '/splash';
      final authed = authState is AuthAuthenticated;
      if (!authed && !loggingIn) return '/splash';
      if (authed && loggingIn) return '/home';
      return null;
    },
    routes: [
      GoRoute(
        path: '/splash',
        builder: (context, state) => const SplashScreen(),
      ),
      ShellRoute(
        navigatorKey: _shellNavigatorKey,
        builder: (context, state, child) => MainShell(child: child),
        routes: [
          GoRoute(path: '/home', builder: (context, state) => const HomeScreen()),
          GoRoute(
            path: '/explore',
            builder: (context, state) => const ExploreScreen(),
          ),
          GoRoute(
            path: '/leaderboard',
            builder: (context, state) => const LeaderboardScreen(),
          ),
          GoRoute(
            path: '/profile',
            builder: (context, state) => const ProfileScreen(),
          ),
        ],
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/quiz/setup',
        builder: (context, state) {
          final extra = state.extra as Map<String, dynamic>?;
          return QuizSetupScreen(
            initialTopicId: extra?['topicId'] as String?,
            initialTopicName: extra?['topicName'] as String?,
          );
        },
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/custom-topic',
        builder: (context, state) => const CustomTopicScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/quiz/play',
        builder: (context, state) {
          final extra = state.extra as Map<String, dynamic>? ?? {};
          final sessionExtra = extra['session'];
          return QuizPlayScreen(
            topicId: extra['topicId'] as String,
            topicName: extra['topicName'] as String?,
            mode: extra['mode'] as String? ?? 'casual',
            difficulty: extra['difficulty'] as String? ?? 'medium',
            adaptive: extra['adaptive'] as bool? ?? false,
            existingSession: sessionExtra is QuizSession ? sessionExtra : null,
          );
        },
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/quiz/results/:sessionId',
        builder: (context, state) {
          final result = state.extra as QuizResult?;
          if (result == null) {
            return Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => context.go('/home'),
                  child: const Text('Back home'),
                ),
              ),
            );
          }
          return QuizResultsScreen(result: result);
        },
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
