import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:speedquiz/core/config/app_config.dart';
import 'package:speedquiz/features/multiplayer/data/multiplayer_repository.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// One match's live event feed, with reconnection.
///
/// Why this is more than `WebSocketChannel.connect`
/// ------------------------------------------------
/// The target audience plays on Indian mobile data, where a two-second dropout
/// mid-round is ordinary. Three things follow, and all of them live here:
///
/// * **Resume, don't restart.** Every event carries a Redis stream id. The last
///   one seen is replayed back to the server on reconnect, which returns the
///   backlog — so a round that started during the gap still arrives.
/// * **Backoff with a ceiling.** Reconnect attempts grow to a few seconds, so a
///   genuinely offline phone does not spin the radio flat retrying.
/// * **A ticket per attempt.** Tickets are single-use, so each reconnect
///   fetches a fresh one rather than replaying a spent credential.
///
/// The socket never carries an answer. Answers are HTTP writes, so a dropped
/// connection can lose a notification but never a scored move.
class MatchSocket {
  // Positional rather than named: Dart forbids a named parameter whose name
  // starts with an underscore, so an initializing formal for a private field
  // has to be positional.
  MatchSocket(this._repository, {required this.matchId});

  final MultiplayerRepository _repository;
  final String matchId;

  final _events = StreamController<MatchSocketEvent>.broadcast();
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeat;
  Timer? _reconnect;

  String? _lastEventId;
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

  Uri _socketUri(String path, String ticket) {
    // The API base is http(s); the socket shares its host, so swap the scheme
    // rather than making the caller configure a second URL that can drift.
    final base = Uri.parse(AppConfig.apiBaseUrl);
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: path,
      queryParameters: {
        'match_id': matchId,
        'ticket': ticket,
        'last_event_id': ?_lastEventId,
      },
    );
  }

  void _onMessage(dynamic raw) {
    if (raw is! String) return;
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
    _heartbeat?.cancel();
    // Also what keeps the server-side presence key alive, so the friends list
    // and the opponent's "connected" dot stay truthful.
    _heartbeat = Timer.periodic(const Duration(seconds: 20), (_) {
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
    // 1s, 2s, 4s, 8s, capped. Long enough to be polite to a struggling
    // network, short enough that a brief tunnel does not cost a round.
    final seconds = [1, 2, 4, 8, 8, 10][_attempt.clamp(0, 5)];
    _attempt++;
    _reconnect = Timer(Duration(seconds: seconds), connect);
  }

  void _teardownConnection() {
    _heartbeat?.cancel();
    _heartbeat = null;
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
}
