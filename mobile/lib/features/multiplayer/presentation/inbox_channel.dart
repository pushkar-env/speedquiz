import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/features/multiplayer/data/match_socket.dart';
import 'package:speedquiz/features/multiplayer/data/multiplayer_repository.dart';
import 'package:speedquiz/features/multiplayer/domain/multiplayer_models.dart';
import 'package:speedquiz/features/multiplayer/presentation/multiplayer_providers.dart';
import 'package:speedquiz/features/multiplayer/presentation/notifications_screen.dart';

/// One socket on the signed-in player's own channel, held for the session.
///
/// What it replaces
/// ----------------
/// Everything social used to arrive only when the screen it lived on was
/// opened fresh: the friends list and the request list are `autoDispose`
/// futures with no refresh, and the badge count is read on mount and on
/// resume. So a friend request sent while the other player was sitting *on*
/// the friends screen did not appear at all, and one sent while they were
/// elsewhere appeared whenever they next wandered back. Push was supposed to
/// cover the gap and could not: Android does not raise a tray notification for
/// a foregrounded app, and nothing was listening for the message either.
///
/// Now the server writes every inbox row to a per-player Redis stream and this
/// holds the other end of it. A request, a challenge, or a result lands on the
/// device as fast as the two of them can reach Redis, and the affected
/// providers are invalidated on the spot.
///
/// Push is still the path for a *closed* app, which this cannot be. The two do
/// not conflict: the foreground push handler only refreshes counts, and the
/// banner is raised from here.
class InboxChannel {
  InboxChannel(this._ref);

  final Ref _ref;

  MatchSocket? _socket;
  StreamSubscription<MatchSocketEvent>? _subscription;
  final _events = StreamController<InboxEvent>.broadcast();

  /// Notifications as they arrive, for the shell to raise a banner from.
  Stream<InboxEvent> get events => _events.stream;

  bool get isConnected => _socket?.isConnected ?? false;

  void start() {
    if (_socket != null) return;
    // No matchId: this subscribes to the player's own channel.
    final socket = MatchSocket(_ref.read(multiplayerRepositoryProvider));
    _socket = socket;
    _subscription = socket.events.listen(_onSocketEvent);
    unawaited(socket.connect());
  }

  /// Skip the backoff — for coming back to the foreground.
  void reconnectNow() => _socket?.reconnectNow();

  void _onSocketEvent(MatchSocketEvent event) {
    switch (event.kind) {
      case MatchSocketEventKind.connected:
        // Anything that landed while the socket was down is already in the
        // inbox; a reconnect is the moment to notice it.
        _ref.invalidate(socialSummaryProvider);
      case MatchSocketEventKind.disconnected:
        break;
      case MatchSocketEventKind.message:
        if (event.type == MatchEvents.notification) _onNotification(event.data);
    }
  }

  void _onNotification(Map<String, dynamic> data) {
    final type = appNotificationTypeFromWire(data['type'] as String?);

    // The badge is affected by every type, so it is invalidated unconditionally
    // and the rest are narrowed — refetching the friends list because a match
    // finished would be three requests to change nothing.
    _ref
      ..invalidate(socialSummaryProvider)
      ..invalidate(notificationsProvider);

    switch (type) {
      case AppNotificationType.friendRequest:
      case AppNotificationType.friendAccepted:
        _ref
          ..invalidate(friendRequestsProvider)
          ..invalidate(friendsProvider);
      case AppNotificationType.matchInvite:
      case AppNotificationType.matchYourTurn:
      case AppNotificationType.matchResult:
      case AppNotificationType.matchExpiring:
        _ref
          ..invalidate(matchListProvider)
          // An invite or a result changes the "continue" affordance on a
          // friend's tile, which is read from the same list.
          ..invalidate(friendsProvider);
    }

    if (_events.isClosed) return;
    _events.add(
      InboxEvent(
        type: type,
        notificationId: data['notification_id'] as String?,
        actorUserId: data['actor_user_id'] as String?,
        matchId: data['match_id'] as String?,
        deepLink: data['deep_link'] as String?,
        payload: (data['payload'] as Map<String, dynamic>?) ?? const {},
      ),
    );
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    await _socket?.dispose();
    _socket = null;
    if (!_events.isClosed) await _events.close();
  }
}

@immutable
class InboxEvent {
  const InboxEvent({
    required this.type,
    this.notificationId,
    this.actorUserId,
    this.matchId,
    this.deepLink,
    this.payload = const {},
  });

  final AppNotificationType type;

  /// The inbox row this event was written from, so acting on the banner can
  /// mark it read and keep the bell's count honest.
  final String? notificationId;
  final String? actorUserId;
  final String? matchId;
  final String? deepLink;
  final Map<String, dynamic> payload;

  /// The actor's name, when the server sent one. The inbox row itself carries
  /// the full player brief; the event carries only what a banner needs.
  String? get actorName {
    final name = payload['actor'];
    return name is String && name.isNotEmpty ? name : null;
  }

  /// Friendship edge id, on a friend request — what lets the banner answer it
  /// without a trip to the requests screen first.
  String? get requestId {
    final id = payload['request_id'];
    return id is String && id.isNotEmpty ? id : null;
  }
}

/// The channel itself. Its lifetime is whoever is listening to
/// [inboxEventsProvider] — in practice the signed-in shell, which is exactly
/// the window in which the player can see anything it delivers.
///
/// `autoDispose` matters here rather than being a default: this owns a socket
/// and a reconnect timer, and a channel that outlived the shell would keep
/// retrying — with a fresh ticket request each time — on behalf of a screen
/// nobody is looking at, or an account that has signed out.
final inboxChannelProvider = Provider.autoDispose<InboxChannel>((ref) {
  final channel = InboxChannel(ref);
  ref.onDispose(() => unawaited(channel.dispose()));
  channel.start();
  return channel;
});

/// Notifications as a provider, so a screen can `ref.listen` for them.
///
/// Also what keeps [inboxChannelProvider] alive: listening to this holds the
/// channel, and dropping the listener closes the socket with it.
final inboxEventsProvider = StreamProvider.autoDispose<InboxEvent>((ref) {
  return ref.watch(inboxChannelProvider).events;
});
