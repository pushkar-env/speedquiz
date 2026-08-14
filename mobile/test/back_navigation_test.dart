import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// Regression cover for the two navigation bugs reported on Android:
///
///  * the close button on the topic/setup screen did nothing, and
///  * the system back button closed the app instead of going back.
///
/// Both had one cause: `context.go` replaces the whole router stack, so a
/// screen reached that way has nothing to pop, and `Navigator.maybePop()`
/// silently no-ops.
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
  challengeDate: '2026-08-12',
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

  @override
  Future<AuthUser?> fetchMe() async => _user;

  @override
  Future<bool> hasStoredSession() async => true;

  @override
  Future<void> signOut() async {}
}

/// Drives the real router, then settles the boot redirect onto Home.
Future<ProviderContainer> _bootToHome(WidgetTester tester) async {
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
      // The shell holds a realtime socket for challenges and friend requests.
      // Nothing here is about that, and left live it opens a connection and
      // schedules a reconnect the test framework then reports as a leaked
      // timer. Stubbed for the same reason every other network provider above
      // is.
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

  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
  expect(find.text('Start a run'), findsOneWidget);
  return container;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

/// Fires the Android system back button through the same path the platform
/// uses: the engine's `popRoute` channel message.
Future<void> _systemBack(WidgetTester tester) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/navigation',
    const JSONMethodCodec().encodeMethodCall(
      const MethodCall('popRoute'),
    ),
    (_) {},
  );
  await _settle(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('close button leaves setup even when it is the only page',
      (tester) async {
    final container = await _bootToHome(tester);

    // `go`, not `push` — this is the state the results screen leaves behind,
    // and the state in which the close button used to do nothing at all.
    container.read(appRouterProvider).go(Routes.quizSetup);
    await _settle(tester);
    expect(find.text('New run'), findsOneWidget);

    await tester.tap(find.byTooltip('Close'));
    await _settle(tester);

    expect(find.text('New run'), findsNothing);
    expect(find.text('Start a run'), findsOneWidget);
  });

  testWidgets('system back leaves setup instead of closing the app',
      (tester) async {
    final container = await _bootToHome(tester);

    container.read(appRouterProvider).go(Routes.quizSetup);
    await _settle(tester);
    expect(find.text('New run'), findsOneWidget);

    await _systemBack(tester);

    expect(find.text('Start a run'), findsOneWidget);
  });

  testWidgets('system back on a tab returns to Home rather than exiting',
      (tester) async {
    await _bootToHome(tester);

    await tester.tap(find.text('Profile'));
    await _settle(tester);
    expect(find.text('Player Test'), findsOneWidget);

    await _systemBack(tester);

    expect(find.text('Start a run'), findsOneWidget);
  });

  testWidgets('system back on Home asks before exiting', (tester) async {
    await _bootToHome(tester);

    await _systemBack(tester);

    // Still in the app, with a prompt rather than a silent exit.
    expect(find.text('Start a run'), findsOneWidget);
    expect(find.text('Press back again to exit'), findsOneWidget);
  });

  testWidgets('back from a pushed sub-screen still pops normally',
      (tester) async {
    final container = await _bootToHome(tester);

    container.read(appRouterProvider).push(Routes.settings);
    await _settle(tester);
    expect(find.text('Appearance'), findsOneWidget);

    await _systemBack(tester);

    expect(find.text('Appearance'), findsNothing);
    expect(find.text('Start a run'), findsOneWidget);
  });
}
