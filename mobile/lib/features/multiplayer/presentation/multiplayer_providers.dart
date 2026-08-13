import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/features/multiplayer/data/multiplayer_repository.dart';
import 'package:speedquiz/features/multiplayer/domain/multiplayer_models.dart';
import 'package:speedquiz/features/social/data/social_repository.dart';

/// Read-side providers for every multiplayer screen except the battle itself,
/// which owns mutable state and lives in `battle_controller.dart`.

final friendsProvider = FutureProvider.autoDispose<List<Friend>>((ref) {
  return ref.watch(socialRepositoryProvider).fetchFriends();
});

final friendRequestsProvider = FutureProvider.autoDispose<
    ({List<FriendRequest> incoming, List<FriendRequest> outgoing})>((ref) {
  return ref.watch(socialRepositoryProvider).fetchRequests();
});

final usernameStatusProvider = FutureProvider.autoDispose<UsernameStatus>((ref) {
  return ref.watch(socialRepositoryProvider).fetchUsername();
});

final matchListProvider = FutureProvider.autoDispose<
    ({List<MatchState> active, List<MatchState> recent})>((ref) {
  return ref.watch(multiplayerRepositoryProvider).fetchMatches();
});

final rankedProfileProvider = FutureProvider.autoDispose<RankedProfile>((ref) {
  return ref.watch(multiplayerRepositoryProvider).fetchRank();
});

final rankedLeaderboardProvider = FutureProvider.autoDispose<
    ({String seasonKey, List<RankedLeaderboardEntry> items, RankedLeaderboardEntry? me})>(
  (ref) => ref.watch(multiplayerRepositoryProvider).fetchRankedLeaderboard(),
);

final blockedPlayersProvider = FutureProvider.autoDispose<List<PlayerBrief>>((ref) {
  return ref.watch(socialRepositoryProvider).fetchBlocked();
});

/// Badge counts for the shell — friend requests plus matches awaiting a turn.
///
/// Deliberately *not* polled on a timer. An earlier draft refreshed every 45
/// seconds; that is a wakeup and a request every 45 seconds, forever, for
/// three integers behind a dot. Push notifications exist precisely so the
/// urgent case reaches the player without the app asking, and the badge is
/// refreshed at the moments it is actually about to be looked at: when the
/// shell mounts, when the app returns to the foreground, and after any action
/// that changes a count.
///
/// The side benefit is that nothing here keeps a timer alive past disposal,
/// which is what a background poller inevitably does.
final socialSummaryProvider = FutureProvider<SocialSummary>((ref) {
  return ref.watch(socialRepositoryProvider).fetchSummary();
});

/// Wait out a debounce, reporting whether the provider survived it.
///
/// Riverpod 2 has no `ref.mounted`, so cancellation is observed by hooking
/// `onDispose` before the delay and checking the flag after it. Without this
/// every keystroke's request completes and the last one to *return* wins,
/// which is not necessarily the last one typed.
Future<bool> _debounce(Ref ref, Duration duration) async {
  var disposed = false;
  ref.onDispose(() => disposed = true);
  await Future<void>.delayed(duration);
  return !disposed;
}

/// Debounced availability check for the username field.
///
/// Fires per keystroke, so typing eight characters must cost one call rather
/// than eight — `autoDispose` tears down the superseded provider and the
/// debounce above notices before the request goes out.
final usernameAvailabilityProvider = FutureProvider.autoDispose
    .family<UsernameAvailability?, String>((ref, query) async {
  final trimmed = query.trim();
  if (trimmed.length < 3) return null;
  if (!await _debounce(ref, const Duration(milliseconds: 350))) return null;

  return ref.watch(socialRepositoryProvider).checkUsername(trimmed);
});

final playerSearchProvider = FutureProvider.autoDispose
    .family<({List<PlayerBrief> players, Map<String, String> relationships}), String>(
  (ref, query) async {
    const empty = (players: <PlayerBrief>[], relationships: <String, String>{});
    final trimmed = query.trim();
    if (trimmed.length < 2) return empty;
    if (!await _debounce(ref, const Duration(milliseconds: 300))) return empty;

    return ref.watch(socialRepositoryProvider).search(trimmed);
  },
);

/// The ranked search.
///
/// Polls rather than holding a socket: matchmaking resolves in seconds, the
/// player is staring at the screen the whole time, and the server pairs on the
/// poll itself — so the poll *is* the mechanism, not an approximation of one.
class RankedQueueController extends StateNotifier<AsyncValue<QueueTicket?>> {
  RankedQueueController(this._repository) : super(const AsyncValue.data(null));

  final MultiplayerRepository _repository;
  Timer? _poll;

  Future<void> search({String? language}) async {
    state = const AsyncValue.loading();
    try {
      final ticket = await _repository.joinQueue(language: language);
      state = AsyncValue.data(ticket);
      if (ticket.state == QueueState.searching) _startPolling();
    } catch (error, stack) {
      state = AsyncValue.error(error, stack);
    }
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) async {
      try {
        final ticket = await _repository.pollQueue();
        if (!mounted) return;
        state = AsyncValue.data(ticket);
        if (ticket.state != QueueState.searching) _poll?.cancel();
      } catch (_) {
        // Keep searching through a blip; cancelling on one failed poll would
        // drop the player out of a queue they are still in server-side.
      }
    });
  }

  Future<void> cancel() async {
    _poll?.cancel();
    try {
      await _repository.leaveQueue();
    } catch (_) {
      // The ticket expires on its own; nothing to recover.
    }
    if (mounted) state = const AsyncValue.data(null);
  }

  @override
  void dispose() {
    _poll?.cancel();
    // Leaving the screen leaves the queue. A ticket that outlived its screen
    // would pair the player into a match nobody is watching.
    unawaited(_repository.leaveQueue());
    super.dispose();
  }
}

final rankedQueueProvider = StateNotifierProvider.autoDispose<RankedQueueController,
    AsyncValue<QueueTicket?>>((ref) {
  return RankedQueueController(ref.watch(multiplayerRepositoryProvider));
});

/// Mutations that several screens share, each invalidating what it changed.
class SocialActions {
  const SocialActions(this._ref);

  final Ref _ref;

  SocialRepository get _repository => _ref.read(socialRepositoryProvider);

  Future<void> sendRequest({String? userId, String? username, String? friendCode}) async {
    await _repository.sendRequest(
      userId: userId,
      username: username,
      friendCode: friendCode,
    );
    _ref.invalidate(friendRequestsProvider);
    _ref.invalidate(friendsProvider);
  }

  Future<void> accept(String requestId) async {
    await _repository.acceptRequest(requestId);
    _ref
      ..invalidate(friendRequestsProvider)
      ..invalidate(friendsProvider);
  }

  Future<void> decline(String requestId) async {
    await _repository.declineRequest(requestId);
    _ref.invalidate(friendRequestsProvider);
  }

  Future<void> cancelRequest(String requestId) async {
    await _repository.cancelRequest(requestId);
    _ref.invalidate(friendRequestsProvider);
  }

  Future<void> unfriend(String userId) async {
    await _repository.unfriend(userId);
    _ref.invalidate(friendsProvider);
  }

  Future<void> block(String userId) async {
    await _repository.block(userId);
    _ref
      ..invalidate(friendsProvider)
      ..invalidate(friendRequestsProvider)
      ..invalidate(blockedPlayersProvider);
  }

  Future<void> unblock(String userId) async {
    await _repository.unblock(userId);
    _ref.invalidate(blockedPlayersProvider);
  }
}

final socialActionsProvider = Provider<SocialActions>(SocialActions.new);

/// Machine-readable error code from a Dio failure, for the UI to localize.
///
/// The server sends `{"detail": {"code": ..., "message": ...}}`; the message is
/// English prose written for logs, so the client renders from the code and
/// keeps the player's language.
String errorCodeOf(Object error) {
  final dynamic dynamicError = error;
  try {
    final detail = dynamicError.response?.data?['detail'];
    if (detail is Map && detail['code'] is String) return detail['code'] as String;
  } catch (_) {
    // Not a Dio error, or an unexpected body shape.
  }
  return 'network_error';
}

@immutable
class ChallengeDraft {
  const ChallengeDraft({
    required this.topicId,
    required this.topicName,
    this.difficulty = 'medium',
    this.questionCount = 7,
  });

  final String topicId;
  final String topicName;
  final String difficulty;
  final int questionCount;
}
