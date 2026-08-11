import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/auth/data/auth_repository.dart';
import 'package:speedquiz/features/auth/data/auth_token_store.dart';
import 'package:speedquiz/features/auth/data/google_auth_service.dart';
import 'package:speedquiz/features/auth/domain/auth_models.dart';
import 'package:speedquiz/features/auth/presentation/auth_controller.dart';
import 'package:speedquiz/features/onboarding/presentation/landing_screen.dart';
import 'package:speedquiz/features/onboarding/presentation/splash_screen.dart';

class _FakeAuthRepository extends AuthRepository {
  _FakeAuthRepository() : super(Dio(), AuthTokenStore());

  @override
  Future<AuthSession> signInAsGuest() async => throw StateError('not used');

  @override
  Future<AuthUser?> fetchMe() async => null;

  @override
  Future<void> signOut() async {}
}

/// Holds a fixed state so widget tests never touch the network.
class _PinnedAuthController extends AuthController {
  _PinnedAuthController(this._pinned)
      : super(_FakeAuthRepository(), GoogleAuthService()) {
    state = _pinned;
  }

  final AuthState _pinned;

  @override
  Future<void> bootstrap() async => state = _pinned;
}

Widget _harness({required Widget home, required AuthState auth}) {
  return ProviderScope(
    overrides: [
      authControllerProvider.overrideWith((ref) => _PinnedAuthController(auth)),
    ],
    child: MaterialApp(
      theme: AppTheme.dark(),
      // Reduce-motion also stops the ambient backdrop and float loops, which
      // would otherwise keep `pumpAndSettle` spinning forever.
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: home,
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('splash shows SpeedQuiz branding while restoring a session',
      (tester) async {
    await tester.pumpWidget(
      _harness(home: const SplashScreen(), auth: const AuthBooting()),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('SPEEDQUIZ'), findsOneWidget);
    expect(find.textContaining('Endless AI quizzes'), findsOneWidget);
  });

  testWidgets('landing offers both guest and Google entry points',
      (tester) async {
    await tester.pumpWidget(
      _harness(home: const LandingScreen(), auth: const AuthSignedOut()),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 800));

    expect(find.text('PLAY AS GUEST'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
  });

  testWidgets('landing surfaces a connection problem with a retry',
      (tester) async {
    await tester.pumpWidget(
      _harness(
        home: const LandingScreen(),
        auth: const AuthSignedOut(
          message: 'Cannot reach the server.',
          hasStoredSession: true,
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 800));

    expect(find.text('Cannot reach the server.'), findsOneWidget);
    expect(find.text('RETRY'), findsOneWidget);
    // A restorable session must not be silently replaced by a fresh guest.
    expect(find.text('START A NEW GUEST RUN'), findsOneWidget);
  });

  group('theme', () {
    test('dark theme uses the brand accent as primary', () {
      expect(AppTheme.dark().colorScheme.primary, AppColors.accent);
    });

    test('light theme uses the deep accent so labels pass contrast on white',
        () {
      expect(AppTheme.light().colorScheme.primary, AppColors.accentDeep);
    });

    test('both themes bundle the display and body families', () {
      for (final theme in [AppTheme.dark(), AppTheme.light()]) {
        expect(theme.textTheme.displaySmall?.fontFamily, 'SpaceGrotesk');
        expect(theme.textTheme.bodyMedium?.fontFamily, 'DMSans');
      }
    });
  });

  group('contrast', () {
    // WCAG 2.1 AA: 4.5:1 for body text, 3:1 for large/bold text and icons.
    for (final brightness in Brightness.values) {
      final name = brightness.name;
      final p = SqPalette.of(brightness);

      test('$name body text clears 4.5:1 on the page background', () {
        expect(_contrast(p.textPrimary, p.background), greaterThanOrEqualTo(4.5));
        expect(_contrast(p.textPrimary, p.surface), greaterThanOrEqualTo(4.5));
      });

      test('$name secondary text clears 4.5:1 on surfaces', () {
        expect(
          _contrast(p.textSecondary, p.surface),
          greaterThanOrEqualTo(4.5),
        );
      });

      test('$name accent labels clear 4.5:1 on surfaces', () {
        expect(_contrast(p.accent, p.surface), greaterThanOrEqualTo(4.5));
      });
    }

    test('primary button ink clears 4.5:1 on the brand gradient', () {
      const ink = Color(0xFF04110C);
      for (final stop in AppColors.brandGradient.colors) {
        expect(_contrast(ink, stop), greaterThanOrEqualTo(4.5));
      }
    });
  });
}

/// WCAG 2.1 relative luminance.
double _luminance(Color color) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();

  return 0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);
}

double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final lighter = math.max(la, lb);
  final darker = math.min(la, lb);
  return (lighter + 0.05) / (darker + 0.05);
}
