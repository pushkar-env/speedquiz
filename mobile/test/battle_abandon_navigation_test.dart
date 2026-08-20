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
import 'package:speedquiz/features/auth/data/auth_repository.dart';
import 'package:speedquiz/features/auth/data/auth_token_store.dart';
import 'package:speedquiz/features/auth/domain/auth_models.dart';
import 'package:speedquiz/features/multiplayer/data/multiplayer_repository.dart';
import 'package:speedquiz/features/multiplayer/domain/multiplayer_models.dart';
import 'package:speedquiz/features/multiplayer/presentation/inbox_channel.dart';

/// Abandoning a match has to leave the player who quit *on the result screen*.
///
/// It did not. The battle route wrapped the screen in an [SqBackGuard] while
/// the screen registered a `PopScope` of its own, and a `PopScope` binds to the
/// route rather than the widget — Flutter invokes every entry registered on a
/// route for one back press (`ModalRoute.onPopInvokedWithResult` walks
/// `_popEntries`, and a single `canPop: false` blocks the pop for all of them).
///
/// So back fired two callbacks. The guard's ran first and walked to the Battle
/// list; the screen's then opened the abandon dialog over a screen the player
/// had already been carried off. The forfeit still reached the server, so the
/// opponent got their result while the player who quit — the one who just took
/// the loss and the rating with it — was looking at the match list instead.
const _matchId = '00000000-0000-0000-0000-00000000000f';
const _me = '00000000-0000-0000-0000-0000000000a1';
const _them = '00000000-0000-0000-0000-0000000000b2';

const _user = AuthUser(
  id: _me,
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

Map<String, dynamic> _participant(
  String userId, {
  required bool isMe,
  String status = 'playing',
  int score = 0,
  int? placement,
}) {
  return {
    'user_id': userId,
    'player': {'user_id': userId, 'username': isMe ? 'me' : 'them'},
    'status': status,
    'is_me': isMe,
    'score': score,
    'rounds_answered': 2,
    'correct_count': 1,
    'answered_current_round': false,
    'placement': ?placement,
  };
}

/// Mid-board and live: `isMyTurn`, so back is the abandon button.
Map<String, dynamic> _liveMatch() => {
      'id': _matchId,
      'topic_id': '00000000-0000-0000-0000-00000000000e',
      'topic_name': 'Astronomy',
      'host_user_id': _me,
      'status': 'live',
      'delivery': 'live',
      'format': 'duel',
      'question_count': 7,
      'current_round_index': 2,
      'my_rounds_answered': 2,
      'server_time': '2026-08-14T10:00:00Z',
      'created_at': '2026-08-14T09:59:00Z',
      'participants': [
        _participant(_me, isMe: true, score: 120),
        _participant(_them, isMe: false, score: 90),
      ],
    };

/// What the server hands back from `leave`: settled, with the quitter forfeited.
Map<String, dynamic> _forfeitedMatch() => {
      ..._liveMatch(),
      'status': 'completed',
      'my_outcome': 'loss',
      'participants': [
        _participant(_me, isMe: true, status: 'forfeited', score: 120, placement: 2),
        _participant(_them, isMe: false, status: 'finished', score: 90, placement: 1),
      ],
    };

/// `GET /round`, which is flat — not the nested `round.start` event shape.
Map<String, dynamic> _round() => {
      'round_index': 2,
      'total_rounds': 7,
      'question_id': '00000000-0000-0000-0000-0000000000c3',
      'prompt': 'Which planet is closest to the sun?',
      'time_limit_ms': 15000,
      'options': [
        {'index': 0, 'text': 'Mercury'},
        {'index': 1, 'text': 'Venus'},
        {'index': 2, 'text': 'Mars'},
        {'index': 3, 'text': 'Earth'},
      ],
      'served_at': '2026-08-14T10:00:03Z',
      'deadline_at': '2026-08-14T10:00:18Z',
      'server_time': '2026-08-14T10:00:00Z',
    };

class _FakeAuthRepo extends AuthRepository {
  _FakeAuthRepo() : super(Dio(), AuthTokenStore());

  @override
  Future<AuthUser?> fetchMe() async => _user;

  @override
  Future<bool> hasStoredSession() async => true;

  @override
  Future<void> signOut() async {}
}

class _FakeMatchRepo extends MultiplayerRepository {
  _FakeMatchRepo() : super(Dio());

  bool left = false;

  @override
  Future<MatchState> fetchMatch(String matchId) async =>
      MatchState.fromJson(left ? _forfeitedMatch() : _liveMatch());

  @override
  Future<MatchRound> fetchRound(String matchId) async =>
      MatchRound.fromJson(_round());

  @override
  Future<MatchState> leave(String matchId) async {
    left = true;
    return MatchState.fromJson(_forfeitedMatch());
  }

  @override
  Future<MatchResult> fetchResult(String matchId) async =>
      MatchResult.fromJson({
        'match': _forfeitedMatch(),
        'standings': _forfeitedMatch()['participants'],
        'my_outcome': 'loss',
        'my_placement': 2,
        'rating_delta': -12,
      });

  @override
  Future<({List<MatchState> active, List<MatchState> recent})>
      fetchMatches() async =>
          (active: <MatchState>[], recent: <MatchState>[]);

  // No socket in a widget test. Failing the ticket keeps the controller on its
  // polling fallback instead of opening a real connection.
  @override
  Future<({String ticket, String path})> realtimeTicket() async =>
      throw StateError('no socket in tests');
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Tear the match down *inside* the test body.
///
/// The controller polls on a two-second timer and the socket schedules its own
/// reconnect, and the binding asserts on any timer still pending once the tree
/// is gone — a check that runs before `addTearDown` ever gets a turn.
Future<void> _close(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(const SizedBox.shrink());
  container.dispose();
  await tester.pump();
}

/// Fires the Android system back button the way the platform does.
Future<void> _systemBack(WidgetTester tester) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/navigation',
    const JSONMethodCodec().encodeMethodCall(const MethodCall('popRoute')),
    (_) {},
  );
  await _settle(tester);
}

Future<ProviderContainer> _openMatch(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: [
      authRepositoryProvider.overrideWithValue(_FakeAuthRepo()),
      multiplayerRepositoryProvider.overrideWithValue(_FakeMatchRepo()),
      inboxEventsProvider.overrideWith((ref) => const Stream.empty()),
    ],
  );
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
  await _settle(tester);

  // `go`, not `push`: how a deep link, a notification and a rematch all arrive,
  // and the case where a plain `pop` would close the app.
  container.read(appRouterProvider).go(Routes.matchPath(_matchId));
  await _settle(tester);
  await _settle(tester);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('back mid-match asks before forfeiting rather than just leaving',
      (tester) async {
    final container = await _openMatch(tester);

    await _systemBack(tester);

    // The dialog, and still on the match — not carried off underneath it.
    expect(find.text('Abandon the match?'), findsOneWidget);

    await _close(tester, container);
  });

  testWidgets('abandoning leaves the player on the result, not the match list',
      (tester) async {
    final container = await _openMatch(tester);

    await _systemBack(tester);
    await tester.tap(find.text('ABANDON'));
    await _settle(tester);
    await _settle(tester);

    // The result they just caused: the loss, why it ended, and a way to play
    // again. Landing on the Battle list instead is the reported bug.
    expect(find.text('You lost'), findsOneWidget);
    expect(find.text('You abandoned the match.'), findsOneWidget);
    expect(find.text('REMATCH'), findsOneWidget);
    expect(find.text('HOME'), findsOneWidget);

    await _close(tester, container);
  });

  testWidgets('cancelling the dialog keeps the match running', (tester) async {
    final container = await _openMatch(tester);

    await _systemBack(tester);
    await tester.tap(find.text('Cancel'));
    await _settle(tester);

    expect(find.text('Abandon the match?'), findsNothing);
    expect(find.text('You lost'), findsNothing);
    // Still the live board.
    expect(find.text('Which planet is closest to the sun?'), findsOneWidget);

    await _close(tester, container);
  });

  testWidgets('back from the result screen leaves instead of closing the app',
      (tester) async {
    final container = await _openMatch(tester);

    await _systemBack(tester);
    await tester.tap(find.text('ABANDON'));
    await _settle(tester);
    await _settle(tester);
    expect(find.text('You lost'), findsOneWidget);

    // The screen owns back entirely now, so it also has to cover what
    // SqBackGuard used to: this route is the bottom of the stack, where a bare
    // pop would close the app rather than go anywhere.
    await _systemBack(tester);

    expect(
      container.read(appRouterProvider).state.matchedLocation,
      Routes.battle,
      reason: 'a bare pop here would have closed the app instead',
    );
    // And the match screen is actually gone, not merely routed past — the
    // outgoing page lingers for the length of the transition.
    await _settle(tester);
    await _settle(tester);
    expect(find.text('You lost'), findsNothing);

    await _close(tester, container);
  });
}
