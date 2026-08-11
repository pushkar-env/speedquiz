import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speedquiz/features/auth/data/auth_repository.dart';
import 'package:speedquiz/features/auth/data/auth_token_store.dart';
import 'package:speedquiz/features/auth/domain/auth_models.dart';
import 'package:speedquiz/features/auth/presentation/auth_controller.dart';

const _user = AuthUser(
  id: '00000000-0000-0000-0000-000000000001',
  username: 'player_test',
  isGuest: true,
  isPremium: false,
  level: 3,
  xp: 250,
  coins: 10,
  currentStreak: 2,
  onboardingCompleted: false,
  themePreference: 'dark',
  avatarId: 'avatar_01',
);

class _FakeRepo extends AuthRepository {
  _FakeRepo({this.me, this.meThrows, this.storedSession = false})
      : super(Dio(), AuthTokenStore());

  AuthUser? me;
  Object? meThrows;
  bool storedSession;

  int signOutCalls = 0;
  int guestCalls = 0;

  @override
  Future<bool> hasStoredSession() async => storedSession;

  @override
  Future<AuthUser?> fetchMe() async {
    final error = meThrows;
    if (error != null) throw error;
    return me;
  }

  @override
  Future<AuthSession> signInAsGuest() async {
    guestCalls++;
    return const AuthSession(
      accessToken: 'access',
      refreshToken: 'refresh',
      user: _user,
    );
  }

  @override
  Future<void> signOut() async {
    signOutCalls++;
    storedSession = false;
  }
}

/// Builds the real provider graph with a fake repository behind it, so tests
/// read state the same way the app does.
({ProviderContainer container, _FakeRepo repo}) _harness(_FakeRepo repo) {
  final container = ProviderContainer(
    overrides: [authRepositoryProvider.overrideWithValue(repo)],
  );
  addTearDown(container.dispose);
  return (container: container, repo: repo);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('bootstrap authenticates when a stored session is still valid', () async {
    final h = _harness(_FakeRepo(me: _user));

    await h.container.read(authControllerProvider.notifier).bootstrap();

    final state = h.container.read(authControllerProvider);
    expect(state, isA<AuthAuthenticated>());
    expect((state as AuthAuthenticated).user.level, 3);
  });

  test('bootstrap lands on the landing screen when there is no token', () async {
    final h = _harness(_FakeRepo());

    await h.container.read(authControllerProvider.notifier).bootstrap();

    final state = h.container.read(authControllerProvider);
    expect(state, isA<AuthSignedOut>());
    expect((state as AuthSignedOut).message, isNull);
  });

  test('a network failure surfaces a retry instead of destroying the session',
      () async {
    // Regression guard: an offline launch used to wipe the stored tokens and
    // silently start a brand-new guest account, losing the player's progress.
    final h = _harness(
      _FakeRepo(
        storedSession: true,
        meThrows: DioException(
          requestOptions: RequestOptions(path: '/auth/me'),
          type: DioExceptionType.connectionError,
        ),
      ),
    );

    await h.container.read(authControllerProvider.notifier).bootstrap();

    final state = h.container.read(authControllerProvider);
    expect(state, isA<AuthSignedOut>());
    expect((state as AuthSignedOut).hasStoredSession, isTrue);
    expect(state.message, isNotNull);
    expect(h.repo.signOutCalls, 0, reason: 'tokens must survive a network blip');
    expect(h.repo.guestCalls, 0, reason: 'no silent guest account replacement');
  });

  test('continueAsGuest authenticates through the repository', () async {
    final h = _harness(_FakeRepo());

    await h.container.read(authControllerProvider.notifier).continueAsGuest();

    expect(h.container.read(authControllerProvider), isA<AuthAuthenticated>());
    expect(h.repo.guestCalls, 1);
  });

  test('signOut clears tokens and returns to the signed-out state', () async {
    final h = _harness(_FakeRepo(me: _user, storedSession: true));
    final controller = h.container.read(authControllerProvider.notifier);
    await controller.bootstrap();
    expect(h.container.read(authControllerProvider), isA<AuthAuthenticated>());

    await controller.signOut();

    final state = h.container.read(authControllerProvider);
    expect(state, isA<AuthSignedOut>());
    expect((state as AuthSignedOut).pending, isFalse);
    expect(h.repo.signOutCalls, 1);
  });

  test('applyProgress updates the signed-in user in place', () async {
    final h = _harness(_FakeRepo(me: _user));
    final controller = h.container.read(authControllerProvider.notifier);
    await controller.bootstrap();

    controller.applyProgress(level: 4, xp: 40, coins: 99, dailyStreak: 5);

    final user =
        (h.container.read(authControllerProvider) as AuthAuthenticated).user;
    expect(user.level, 4);
    expect(user.xp, 40);
    expect(user.coins, 99);
    expect(user.dailyStreak, 5);
    expect(user.currentStreak, 5);
  });

  test('applyProgress is a no-op while signed out', () async {
    final h = _harness(_FakeRepo());
    final controller = h.container.read(authControllerProvider.notifier);
    await controller.bootstrap();

    controller.applyProgress(level: 9);

    expect(h.container.read(authControllerProvider), isA<AuthSignedOut>());
  });

  test('currentUserProvider exposes the signed-in user and nothing else',
      () async {
    final h = _harness(_FakeRepo(me: _user));
    expect(h.container.read(currentUserProvider), isNull);

    await h.container.read(authControllerProvider.notifier).bootstrap();

    expect(h.container.read(currentUserProvider)?.username, 'player_test');
  });
}
