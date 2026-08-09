import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quizverse/core/theme/app_theme.dart';
import 'package:quizverse/features/auth/data/auth_repository.dart';
import 'package:quizverse/features/auth/data/auth_token_store.dart';
import 'package:quizverse/features/auth/domain/auth_models.dart';
import 'package:quizverse/features/auth/presentation/auth_controller.dart';
import 'package:quizverse/features/onboarding/presentation/splash_screen.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAuthRepository extends AuthRepository {
  _FakeAuthRepository() : super(Dio(), AuthTokenStore());

  @override
  Future<AuthSession> signInAsGuest() async {
    throw StateError('not used');
  }

  @override
  Future<AuthUser?> fetchMe() async => null;

  @override
  Future<void> signOut() async {}
}

class _SteadyAuthController extends AuthController {
  _SteadyAuthController() : super(_FakeAuthRepository());

  @override
  Future<void> bootstrap() async {
    state = AuthAuthenticated(
      const AuthUser(
        id: '00000000-0000-0000-0000-000000000001',
        username: 'player_test',
        isGuest: true,
        isPremium: false,
        level: 1,
        xp: 0,
        coins: 0,
        currentStreak: 0,
        onboardingCompleted: false,
        themePreference: 'dark',
        avatarId: 'avatar_01',
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Splash shows QuizVerse branding', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authControllerProvider.overrideWith((ref) => _SteadyAuthController()),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const SplashScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('QUIZVERSE'), findsOneWidget);
    expect(find.textContaining('Endless AI quizzes'), findsOneWidget);
  });

  test('dark theme uses accent teal', () {
    final theme = AppTheme.dark();
    expect(theme.colorScheme.primary, AppColors.accent);
  });
}
