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
    test('a brand-new account is asked', () {
      expect(_freshGuest.needsOnboarding, isTrue);
    });

    test('an account with a life of its own is never asked', () {
      // The reported bug, as a unit: this account carries
      // `onboardingCompleted == false` — it predates the flag — but it is on
      // level 7 with 4200 XP. Nobody with that on the board is a new player,
      // and asking them to pick a name is asking them to rename themselves.
      expect(_establishedPlayer.onboardingCompleted, isFalse);
      expect(_establishedPlayer.needsOnboarding, isFalse);
    });

    test('an account that has answered is never asked again', () {
      expect(
        _freshGuest.copyWith(onboardingCompleted: true).needsOnboarding,
        isFalse,
      );
    });

    test('a signed-out device is asked nothing at all', () async {
      // The flow lives behind sign-in now, so a device record — however fresh
      // — is not a reason to interrupt anyone. This is what made every
      // reinstall, and every failed session restore, look like a first run.
      final h = _harness();
      await h.container.read(onboardingControllerProvider.notifier).hydrate();

      await h.container.read(authControllerProvider.notifier).bootstrap();

      expect(h.container.read(authControllerProvider), isA<AuthSignedOut>());
      expect(h.profile.onboardingUpdate, isNull);
    });
  });

  group('reaching the profile', () {
    test('the name and both languages land as the flow finishes', () async {
      final h = _harness();
      final onboarding =
          h.container.read(onboardingControllerProvider.notifier);
      await onboarding.hydrate();
      await h.container.read(authControllerProvider.notifier).continueAsGuest();
      await h.container
          .read(appLanguageProvider.notifier)
          .setLanguage(AppLanguage.hindi);
      await h.container
          .read(quizLanguageProvider.notifier)
          .setLanguage(AppLanguage.hindi);

      await onboarding.complete(name: 'Aanya');

      final update = h.profile.onboardingUpdate;
      expect(update, isNotNull);
      expect(update!.displayName, 'Aanya');
      expect(update.appLanguage, 'hi');
      expect(update.quizLanguage, 'hi');

      // And the app is already showing it, without a second round trip.
      final state = h.container.read(authControllerProvider) as AuthAuthenticated;
      expect(state.user.chosenName, 'Aanya');
      expect(state.user.needsOnboarding, isFalse, reason: 'the gate has closed');
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getBool('onboarding_v1_pending'),
        isFalse,
        reason: 'the device stops carrying an answer the server now has',
      );
    });

    test('skipping the name still records the language', () async {
      final h = _harness();
      final onboarding =
          h.container.read(onboardingControllerProvider.notifier);
      await onboarding.hydrate();
      await h.container.read(authControllerProvider.notifier).continueAsGuest();

      await onboarding.complete(name: null);

      final update = h.profile.onboardingUpdate;
      expect(update, isNotNull);
      expect(update!.displayName, isNull);
      expect(update.appLanguage, 'en');
    });

    test('a failed write still lets the player through', () async {
      // The router holds a player on this screen until the account says it is
      // onboarded. Waiting on the network to release them would trap anyone
      // who finished the flow on a bad connection.
      final h = _harness();
      final onboarding =
          h.container.read(onboardingControllerProvider.notifier);
      await onboarding.hydrate();
      await h.container.read(authControllerProvider.notifier).continueAsGuest();
      h.profile.failWith = DioException(
        requestOptions: RequestOptions(path: '/users/me'),
        type: DioExceptionType.connectionError,
      );

      await onboarding.complete(name: 'Aanya');

      final state = h.container.read(authControllerProvider) as AuthAuthenticated;
      expect(state.user.needsOnboarding, isFalse, reason: 'not trapped');
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getBool('onboarding_v1_pending'),
        isTrue,
        reason: 'the answer is still owed to the server',
      );

      // Next launch, back online: the session hook pays the debt.
      h.profile.failWith = null;
      await h.container.read(authControllerProvider.notifier).bootstrap();

      expect(h.profile.onboardingUpdate?.displayName, 'Aanya');
    });

    test('a retry never renames an account that has been played', () async {
      // The retry path runs on *any* session, including a sign-in to an
      // established account on a device still carrying someone else's answer.
      final h = _harness(google: _establishedPlayer);
      final onboarding =
          h.container.read(onboardingControllerProvider.notifier);
      await onboarding.hydrate();
      await h.container.read(authControllerProvider.notifier).continueAsGuest();
      h.profile.failWith = DioException(
        requestOptions: RequestOptions(path: '/users/me'),
        type: DioExceptionType.connectionError,
      );
      await onboarding.complete(name: 'Typed On The Way In');
      h.profile.failWith = null;
      h.profile.currentDisplayName = _establishedPlayer.displayName;
      // The failed attempt is on the record too; this asserts about the retry.
      h.profile.updates.clear();

      await h.container.read(authControllerProvider.notifier).signInWithGoogle();

      final update = h.profile.onboardingUpdate;
      expect(update, isNotNull);
      expect(update!.displayName, isNull, reason: 'the account keeps its name');
      final state = h.container.read(authControllerProvider) as AuthAuthenticated;
      expect(state.user.chosenName, 'Nova Sharma');
    });
  });

  testWidgets('a first run signs in, then names itself, then lands on Home',
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

    // Splash finds no session and offers the ways in. Nothing is asked of
    // someone who has not said who they are yet — this is the whole change.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('PLAY AS GUEST'), findsOneWidget);
    expect(find.text('Pick your language'), findsNothing);

    await tester.tap(find.text('PLAY AS GUEST'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    // Now there is an account, and it is a new one.
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
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    // The generated handle never reaches the greeting.
    expect(h.profile.onboardingUpdate?.displayName, 'Aanya');
    expect(find.textContaining('AANYA'), findsOneWidget);
    expect(find.textContaining('player_a1b2c3d4'), findsNothing);
  });
}
