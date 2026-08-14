import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:speedquiz/core/config/app_config.dart';
import 'package:speedquiz/features/multiplayer/data/multiplayer_repository.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// One live event feed, with reconnection.
///
/// Opened against a match (pass [matchId]) for round events, or against the
/// signed-in player's own channel (leave it null) for friend requests,
/// challenges and results while the app is open.
///
/// Why this is more than `WebSocketChannel.connect`
/// ------------------------------------------------
/// The target audience plays on Indian mobile data, where a two-second dropout
/// mid-round is ordinary. Four things follow, and all of them live here:
///
/// * **Resume, don't restart.** Every event carries a Redis stream id. The last
///   one seen is replayed back to the server on reconnect, which returns the
///   backlog — so a round that started during the gap still arrives.
/// * **Backoff that starts fast.** The first retry is a few hundred
///   milliseconds, because the overwhelmingly common failure is a blip and a
///   full second of "Reconnecting" is a second of a running clock. It grows to
///   several seconds so a genuinely offline phone does not spin the radio flat.
/// * **A liveness watchdog.** A socket can stay open while delivering nothing —
///   a half-open TCP connection survives a carrier handover, and the OS will
///   not tell us for minutes. Every heartbeat is checked for its reply, and a
///   feed that has gone quiet is torn down and rebuilt rather than trusted.
/// * **A ticket per attempt.** Tickets are single-use, so each reconnect
///   fetches a fresh one rather than replaying a spent credential.
///
/// The socket never carries an answer. Answers are HTTP writes, so a dropped
/// connection can lose a notification but never a scored move.
class MatchSocket {
  // Positional rather than named: Dart forbids a named parameter whose name
  // starts with an underscore, so an initializing formal for a private field
  // has to be positional.
  MatchSocket(this._repository, {this.matchId});

  final MultiplayerRepository _repository;

  /// Null subscribes to the player's own channel instead of a match.
  final String? matchId;

  /// Must match the server's `realtime_heartbeat_seconds`.
  static const _heartbeat = Duration(seconds: 20);

  /// Silence longer than this means the connection is dead even though the
  /// socket still looks open. Two missed beats plus slack.
  static const _silenceLimit = Duration(seconds: 50);

  final _events = StreamController<MatchSocketEvent>.broadcast();
  final _random = math.Random();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeatTimer;
  Timer? _reconnect;

  String? _lastEventId;
  DateTime? _lastInbound;
  int _attempt = 0;
  bool _closed = false;
  bool _connecting = false;

  Stream<MatchSocketEvent> get events => _events.stream;

  bool get isConnected => _channel != null;

  Future<void> connect() async {
    if (_closed || _connecting || _channel != null) return;
    _connecting = true;
    try {
      final ticket = await _repository.realtimeTicket();
      final uri = _socketUri(ticket.path, ticket.ticket);
      final channel = WebSocketChannel.connect(uri);
      await channel.ready;
      if (_closed) {
        await channel.sink.close();
        return;
      }

      _channel = channel;
      _attempt = 0;
      _lastInbound = DateTime.now();
      _emit(const MatchSocketEvent.connected());

      _subscription = channel.stream.listen(
        _onMessage,
        onDone: _onDropped,
        onError: (Object _) => _onDropped(),
        cancelOnError: true,
      );
      _startHeartbeat();
    } catch (error) {
      _scheduleReconnect();
    } finally {
      _connecting = false;
    }
  }

  /// Reconnect at once, skipping whatever backoff is pending.
  ///
  /// For the moments where waiting is pointless because the situation has
  /// visibly changed — the app returning to the foreground, most of all, since
  /// a socket almost never survives being backgrounded and the player is
  /// looking at the screen right now.
  void reconnectNow() {
    if (_closed) return;
    _reconnect?.cancel();
    _attempt = 0;
    if (_channel != null) return;
    unawaited(connect());
  }

  Uri _socketUri(String path, String ticket) {
    // The API base is http(s); the socket shares its host, so swap the scheme
    // rather than making the caller configure a second URL that can drift.
    final base = Uri.parse(AppConfig.apiBaseUrl);
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: path,
      queryParameters: {
        'ticket': ticket,
        'match_id': ?matchId,
        'last_event_id': ?_lastEventId,
      },
    );
  }

  void _onMessage(dynamic raw) {
    if (raw is! String) return;
    // Any frame at all proves the far end is alive, including a pong.
    _lastInbound = DateTime.now();

    Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    if (decoded['type'] == 'pong') return;

    final id = decoded['id'] as String?;
    if (id != null) _lastEventId = id;

    _emit(
      MatchSocketEvent.message(
        type: decoded['type'] as String? ?? 'unknown',
        data: (decoded['data'] as Map<String, dynamic>?) ?? const {},
      ),
    );
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    // Also what keeps the server-side presence key alive, so the friends list
    // and the opponent's "connected" dot stay truthful.
    _heartbeatTimer = Timer.periodic(_heartbeat, (_) {
      final since = _lastInbound;
      if (since != null && DateTime.now().difference(since) > _silenceLimit) {
        // Pings have been going into a hole. Rebuild rather than sit on a
        // socket that reports itself connected and delivers nothing — which is
        // the state that leaves a player watching a round they cannot see.
        _onDropped();
        return;
      }
      try {
        _channel?.sink.add(jsonEncode({'type': 'ping'}));
      } catch (_) {
        _onDropped();
      }
    });
  }

  void _onDropped() {
    _teardownConnection();
    if (_closed) return;
    _emit(const MatchSocketEvent.disconnected());
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_closed) return;
    _reconnect?.cancel();
    // Starts at a third of a second: the common case is a blip, and a round
    // clock is running the whole time. Grows to eight so a phone with no
    // signal is not retrying every heartbeat for the rest of the match.
    const schedule = [300, 800, 1500, 3000, 5000, 8000];
    final base = schedule[_attempt.clamp(0, schedule.length - 1)];
    // Jitter, so two players dropped by the same tower do not return in
    // lockstep and land on the same replica at the same instant.
    final delay = base + _random.nextInt(250);
    _attempt++;
    _reconnect = Timer(Duration(milliseconds: delay), connect);
  }

  void _teardownConnection() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _subscription?.cancel();
    _subscription = null;
    final channel = _channel;
    _channel = null;
    unawaited(channel?.sink.close());
  }

  void _emit(MatchSocketEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  Future<void> dispose() async {
    _closed = true;
    _reconnect?.cancel();
    _teardownConnection();
    if (!_events.isClosed) await _events.close();
  }
}

@immutable
class MatchSocketEvent {
  const MatchSocketEvent._(this.kind, {this.type = '', this.data = const {}});

  const MatchSocketEvent.connected() : this._(MatchSocketEventKind.connected);
  const MatchSocketEvent.disconnected()
      : this._(MatchSocketEventKind.disconnected);
  const MatchSocketEvent.message({
    required String type,
    required Map<String, dynamic> data,
  }) : this._(MatchSocketEventKind.message, type: type, data: data);

  final MatchSocketEventKind kind;

  /// Server event name — `round.start`, `round.end`, `match.finished`, …
  final String type;
  final Map<String, dynamic> data;
}

enum MatchSocketEventKind { connected, disconnected, message }

/// Event names the server publishes. Kept as constants so a typo in a switch
/// is a compile error rather than a branch that silently never runs.
abstract final class MatchEvents {
  static const state = 'match.state';
  static const participant = 'participant.update';
  static const countdown = 'match.countdown';
  static const roundStart = 'round.start';
  static const roundProgress = 'round.progress';
  static const roundEnd = 'round.end';
  static const finished = 'match.finished';
  static const cancelled = 'match.cancelled';

  /// Player channel only — a new inbox row was written for you.
  static const notification = 'notification.new';
}
