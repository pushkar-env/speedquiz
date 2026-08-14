import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/i18n/language_providers.dart';
import 'package:speedquiz/core/routing/app_router.dart';
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
import 'package:speedquiz/features/multiplayer/presentation/inbox_channel.dart';
import 'package:speedquiz/features/onboarding/domain/onboarding_state.dart';
import 'package:speedquiz/features/onboarding/presentation/onboarding_controller.dart';
import 'package:speedquiz/features/profile/data/profile_repository.dart';
import 'package:speedquiz/features/profile/domain/profile_models.dart';
import 'package:speedquiz/features/topics/data/topics_repository.dart';

/// A brand-new guest exactly as the server hands it back: `display_name` is
/// already filled in with the generated handle, which is why "does this account
/// have a name?" cannot be answered by a null check.
const _freshGuest = AuthUser(
  id: '00000000-0000-0000-0000-000000000001',
  username: 'player_a1b2c3d4',
  displayName: 'player_a1b2c3d4',
  isGuest: true,
  isPremium: false,
  level: 1,
  xp: 0,
  coins: 0,
  currentStreak: 0,
  onboardingCompleted: false,
  themePreference: 'dark',
  avatarId: 'avatar_01',
);

/// Someone who has been playing for a while on another device.
const _establishedPlayer = AuthUser(
  id: '00000000-0000-0000-0000-000000000002',
  email: 'nova@example.com',
  username: 'nova',
  displayName: 'Nova Sharma',
  isGuest: false,
  isPremium: false,
  level: 7,
  xp: 4200,
  coins: 300,
  currentStreak: 5,
  dailyStreak: 5,
  bestStreak: 19,
  onboardingCompleted: false,
  themePreference: 'dark',
  avatarId: 'avatar_02',
);

const _topics = [
  TopicItem(id: 't1', name: 'Astronomy', icon: '🌌', questionCount: 900),
];

const _daily = DailyChallengeInfo(
  id: 'd1',
  challengeDate: '2026-08-13',
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

/// One recorded `PATCH /users/me`.
typedef _Update = ({
  String? displayName,
  String? appLanguage,
  String? quizLanguage,
  bool? onboardingCompleted,
});

class _FakeProfileRepository extends ProfileRepository {
  _FakeProfileRepository() : super(Dio());

  final List<_Update> updates = [];
  Object? failWith;

  /// What the server would echo back for a PATCH that did not set a name.
  String? currentDisplayName = _freshGuest.displayName;

  /// The one write onboarding makes, picked out by its flag so an unrelated
  /// language sync racing alongside it cannot be mistaken for it.
  _Update? get onboardingUpdate =>
      updates.where((u) => u.onboardingCompleted == true).firstOrNull;

  @override
  Future<UserProfile> update({
    String? displayName,
    String? avatarId,
    String? themePreference,
    List<String>? favoriteTopicIds,
    bool? onboardingCompleted,
    String? appLanguage,
    String? quizLanguage,
  }) async {
    updates.add((
      displayName: displayName,
      appLanguage: appLanguage,
      quizLanguage: quizLanguage,
      onboardingCompleted: onboardingCompleted,
    ));
    final error = failWith;
    if (error != null) throw error;
    if (displayName != null) currentDisplayName = displayName;
    return UserProfile(
      userId: _freshGuest.id,
      username: _freshGuest.username,
      displayName: currentDisplayName,
      avatarId: avatarId ?? 'avatar_01',
      level: 1,
      xp: 0,
      coins: 0,
      currentStreak: 0,
      bestStreak: 0,
      dailyStreak: 0,
      isPremium: false,
      appLanguage: appLanguage,
      quizLanguage: quizLanguage,
      statistics: ProfileStats.empty,
    );
  }
}

class _FakeAuthRepository extends AuthRepository {
  _FakeAuthRepository({this.me, this.google}) : super(Dio(), AuthTokenStore());

  AuthUser? me;
  AuthUser? google;

  @override
  Future<AuthUser?> fetchMe() async => me;

  @override
  Future<bool> hasStoredSession() async => me != null;

  @override
  Future<AuthSession> signInAsGuest() async {
    me = _freshGuest;
    return const AuthSession(
      accessToken: 'access',
      refreshToken: 'refresh',
      user: _freshGuest,
    );
  }

  @override
  Future<AuthSession> signInWithGoogle(String idToken) async {
    final user = google ?? _establishedPlayer;
    me = user;
    return AuthSession(
      accessToken: 'access',
      refreshToken: 'refresh',
      user: user,
    );
  }

  @override
  Future<void> signOut() async => me = null;
}

class _FakeGoogleAuth extends GoogleAuthService {
  @override
  Future<String?> obtainIdToken() async => 'fake-id-token';

  @override
  Future<void> signOut() async {}
}

typedef _Harness = ({
  ProviderContainer container,
  _FakeAuthRepository auth,
  _FakeProfileRepository profile,
});

_Harness _harness({AuthUser? me, AuthUser? google}) {
  final auth = _FakeAuthRepository(me: me, google: google);
  final profile = _FakeProfileRepository();
  final container = ProviderContainer(
    overrides: [
      authRepositoryProvider.overrideWithValue(auth),
      profileRepositoryProvider.overrideWithValue(profile),
      googleAuthServiceProvider.overrideWithValue(_FakeGoogleAuth()),
      topicsProvider.overrideWith((ref) async => _topics),
      dailyChallengeProvider.overrideWith((ref) async => _daily),
      achievementsProvider.overrideWith((ref) async => _achievements),
      entitlementsProvider.overrideWith((ref) async => _entitlements),
      // The shell holds a realtime socket for challenges and friend requests.
      // Stubbed for the same reason every other network provider above is.
      inboxEventsProvider.overrideWith((ref) => const Stream.empty()),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, auth: auth, profile: profile);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the gate', () {
    test('a fresh install is asked', () async {
      final h = _harness();

      await h.container.read(onboardingControllerProvider.notifier).hydrate();

      expect(
        h.container.read(onboardingControllerProvider).status,
        OnboardingStatus.needed,
      );
    });

    test('an install that already has a session is never asked', () async {
      // The upgrade case: everyone already playing when this shipped must go
      // on playing, including after a later sign-out.
      final h = _harness(me: _freshGuest);
      await h.container.read(onboardingControllerProvider.notifier).hydrate();

      await h.container.read(authControllerProvider.notifier).bootstrap();

      expect(
        h.container.read(onboardingControllerProvider).status,
        OnboardingStatus.done,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('onboarding_v1_seen'), isTrue);
    });

    test('finishing the flow closes it for good', () async {
      final h = _harness();
      final onboarding =
          h.container.read(onboardingControllerProvider.notifier);
      await onboarding.hydrate();

      await onboarding.complete(name: 'Aanya');

      expect(
        h.container.read(onboardingControllerProvider).status,
        OnboardingStatus.done,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('onboarding_v1_name'), 'Aanya');
      expect(prefs.getBool('onboarding_v1_pending'), isTrue);
    });
  });

  group('reaching the profile', () {
    test('the name and both languages land on the first sign-in', () async {
      final h = _harness();
      final onboarding =
          h.container.read(onboardingControllerProvider.notifier);
      await onboarding.hydrate();
      await h.container
          .read(appLanguageProvider.notifier)
          .setLanguage(AppLanguage.hindi);
      await h.container
          .read(quizLanguageProvider.notifier)
          .setLanguage(AppLanguage.hindi);
      await onboarding.complete(name: 'Aanya');

      await h.container.read(authControllerProvider.notifier).continueAsGuest();

      final update = h.profile.onboardingUpdate;
      expect(update, isNotNull);
      expect(update!.displayName, 'Aanya');
      expect(update.appLanguage, 'hi');
      expect(update.quizLanguage, 'hi');

      // And the app is already showing it, without a second round trip.
      final state = h.container.read(authControllerProvider) as AuthAuthenticated;
      expect(state.user.chosenName, 'Aanya');
      expect(
        h.container.read(onboardingControllerProvider).pendingName,
        isNull,
        reason: 'the device stops carrying an answer the server now has',
      );
    });

    test('skipping the name still records the language', () async {
      final h = _harness();
      final onboarding =
          h.container.read(onboardingControllerProvider.notifier);
      await onboarding.hydrate();
      await onboarding.complete(name: null);

      await h.container.read(authControllerProvider.notifier).continueAsGuest();

      final update = h.profile.onboardingUpdate;
      expect(update, isNotNull);
      expect(update!.displayName, isNull);
      expect(update.appLanguage, 'en');
    });

    test('an account that has been played keeps its own name', () async {
      // Reinstall, type something on the way in, then sign into an account
      // that already has a real display name. The account wins.
      final h = _harness();
      final onboarding =
          h.container.read(onboardingControllerProvider.notifier);
      await onboarding.hydrate();
      await onboarding.complete(name: 'Typed On The Way In');
      h.profile.currentDisplayName = _establishedPlayer.displayName;

      await h.container.read(authControllerProvider.notifier).signInWithGoogle();

      final update = h.profile.onboardingUpdate;
      expect(update, isNotNull);
      expect(update!.displayName, isNull);
      final state = h.container.read(authControllerProvider) as AuthAuthenticated;
      expect(state.user.chosenName, 'Nova Sharma');
    });

    test('a failed sync keeps the answer and retries next session', () async {
      final h = _harness();
      final onboarding =
          h.container.read(onboardingControllerProvider.notifier);
      await onboarding.hydrate();
      await onboarding.complete(name: 'Aanya');
      h.profile.failWith = DioException(
        requestOptions: RequestOptions(path: '/users/me'),
        type: DioExceptionType.connectionError,
      );

      await h.container.read(authControllerProvider.notifier).continueAsGuest();

      // The sign-in itself stands — onboarding is not allowed to break it.
      expect(h.container.read(authControllerProvider), isA<AuthAuthenticated>());
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('onboarding_v1_pending'), isTrue);

      // Next launch, back online.
      h.profile.failWith = null;
      await h.container.read(authControllerProvider.notifier).bootstrap();

      expect(h.profile.onboardingUpdate?.displayName, 'Aanya');
      final state = h.container.read(authControllerProvider) as AuthAuthenticated;
      expect(state.user.chosenName, 'Aanya');
    });
  });

  testWidgets('a first run names itself and arrives named on Home',
      (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final h = _harness();
    await h.container.read(onboardingControllerProvider.notifier).hydrate();

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
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
              routerConfig: h.container.read(appRouterProvider),
            ),
          ),
        ),
      ),
    );

    // Splash finds no session and the gate sends a first run to the flow
    // rather than straight at a sign-in wall.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Pick your language'), findsOneWidget);

    await tester.tap(find.text('CONTINUE'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('What should we call you?'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Aanya');
    await tester.pump();
    await tester.tap(find.text("LET'S GO"));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Onboarding hands off to the existing sign-in screen, which now knows
    // who it is talking to.
    expect(find.text('Ready when you are, Aanya.'), findsOneWidget);
    expect(find.text('PLAY AS GUEST'), findsOneWidget);

    await tester.tap(find.text('PLAY AS GUEST'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    // The generated handle never reaches the greeting.
    expect(h.profile.onboardingUpdate?.displayName, 'Aanya');
    expect(find.textContaining('AANYA'), findsOneWidget);
    expect(find.text('Aanya'), findsWidgets);
    expect(find.textContaining('player_a1b2c3d4'), findsNothing);
  });
}
