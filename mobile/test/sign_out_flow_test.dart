import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/achievements/data/achievements_repository.dart';
import 'package:speedquiz/features/achievements/domain/achievement_models.dart';
import 'package:speedquiz/features/auth/data/auth_repository.dart';
import 'package:speedquiz/features/auth/data/auth_token_store.dart';
import 'package:speedquiz/features/auth/domain/auth_models.dart';
import 'package:speedquiz/features/daily/data/daily_repository.dart';
import 'package:speedquiz/features/daily/domain/daily_models.dart';
import 'package:speedquiz/features/entitlements/data/entitlements_repository.dart';
import 'package:speedquiz/features/entitlements/domain/entitlement_models.dart';
import 'package:speedquiz/features/multiplayer/presentation/inbox_channel.dart';
import 'package:speedquiz/features/topics/data/topics_repository.dart';

const _user = AuthUser(
  id: '00000000-0000-0000-0000-000000000001',
  username: 'player_test',
  displayName: 'Player Test',
  isGuest: false,
  isPremium: false,
  level: 2,
  xp: 100,
  coins: 10,
  currentStreak: 1,
  dailyStreak: 1,
  bestStreak: 4,
  onboardingCompleted: true,
  themePreference: 'dark',
  avatarId: 'avatar_01',
);

const _topics = [
  TopicItem(id: 't1', name: 'Astronomy', icon: '🌌', questionCount: 900),
];

const _daily = DailyChallengeInfo(
  id: 'd1',
  challengeDate: '2026-08-11',
  title: 'Daily Challenge',
  topicId: 't1',
  topicName: 'Astronomy',
  difficulty: 'medium',
  questionCount: 10,
  status: 'available',
);

const _achievements = AchievementList(items: [], unlockedCount: 0, total: 0);

const _entitlements = EntitlementsMe(
  isPremium: false,
  enforceCaps: false,
  customTopicsUnlimited: true,
  devToggleAllowed: false,
);

class _FakeRepo extends AuthRepository {
  _FakeRepo() : super(Dio(), AuthTokenStore());

  bool signedOut = false;

  @override
  Future<AuthUser?> fetchMe() async => signedOut ? null : _user;

  @override
  Future<bool> hasStoredSession() async => !signedOut;

  @override
  Future<void> signOut() async => signedOut = true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('signing out lands on a rendered landing screen', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final container = ProviderContainer(
      overrides: [
        authRepositoryProvider.overrideWithValue(_FakeRepo()),
        topicsProvider.overrideWith((ref) async => _topics),
        dailyChallengeProvider.overrideWith((ref) async => _daily),
        achievementsProvider.overrideWith((ref) async => _achievements),
        entitlementsProvider.overrideWith((ref) async => _entitlements),
        // The shell holds a realtime socket for challenges and friend
        // requests. Stubbed for the same reason every other network provider
        // above is.
        inboxEventsProvider.overrideWith((ref) => const Stream.empty()),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: MaterialApp.router(
              localizationsDelegates: const [
                SqLocalizations.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              supportedLocales: AppLanguage.supportedLocales,
              theme: AppTheme.dark(),
              routerConfig: container.read(appRouterProvider),
            ),
          ),
        ),
      ),
    );

    // Boot: splash restores the session and the router lands on Home.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Start a run'), findsOneWidget);

    // Go to Profile via the shell tab.
    await tester.tap(find.text('Profile'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Player Test'), findsOneWidget);

    // Sign out now lives on the Settings screen.
    await tester.scrollUntilVisible(
      find.text('Settings'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Settings').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Appearance'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('SIGN OUT'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('SIGN OUT'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Sign out?'), findsOneWidget);

    await tester.tap(find.text('SIGN OUT').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    expect(tester.takeException(), isNull);

    // The landing screen must actually be on screen and painted — a blank
    // dark route would still "route correctly" while showing nothing.
    expect(find.text('PLAY AS GUEST'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);

    final opacity = tester.widgetList<FadeTransition>(
      find.ancestor(
        of: find.text('PLAY AS GUEST'),
        matching: find.byType(FadeTransition),
      ),
    );
    for (final fade in opacity) {
      expect(
        fade.opacity.value,
        greaterThan(0.0),
        reason: 'landing content must be visible, not faded out',
      );
    }
  });
}
