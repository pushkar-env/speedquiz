import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/features/multiplayer/data/match_socket.dart';
import 'package:speedquiz/features/multiplayer/data/multiplayer_repository.dart';
import 'package:speedquiz/features/multiplayer/domain/multiplayer_models.dart';

/// Everything one battle screen needs to render, in one object.
@immutable
class BattleState {
  const BattleState({
    this.match,
    this.round,
    this.feedback,
    this.result,
    this.isLoading = true,
    this.isConnected = false,
    this.isSubmitting = false,
    this.selectedOptionIndex,
    this.error,
  });

  final MatchState? match;
  final MatchRound? round;

  /// Set between answering and the next round opening — this is what the
  /// screen shows during the reveal pause.
  final MatchAnswerFeedback? feedback;
  final MatchResult? result;

  final bool isLoading;

  /// Live socket held. False does not mean broken: an async match never opens
  /// one, and a live match that dropped is still playable over HTTP.
  final bool isConnected;
  final bool isSubmitting;
  final int? selectedOptionIndex;
  final String? error;

  bool get isAnswered => feedback != null;
  bool get isFinished => result != null || (match?.isOver ?? false);

  BattleState copyWith({
    MatchState? match,
    MatchRound? round,
    MatchAnswerFeedback? feedback,
    MatchResult? result,
    bool? isLoading,
    bool? isConnected,
    bool? isSubmitting,
    int? selectedOptionIndex,
    String? error,
    bool clearRound = false,
    bool clearFeedback = false,
    bool clearError = false,
    bool clearSelection = false,
  }) {
    return BattleState(
      match: match ?? this.match,
      round: clearRound ? null : (round ?? this.round),
      feedback: clearFeedback ? null : (feedback ?? this.feedback),
      result: result ?? this.result,
      isLoading: isLoading ?? this.isLoading,
      isConnected: isConnected ?? this.isConnected,
      isSubmitting: isSubmitting ?? this.isSubmitting,
      selectedOptionIndex:
          clearSelection ? null : (selectedOptionIndex ?? this.selectedOptionIndex),
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Drives one match from lobby to result.
///
/// The socket is an accelerator, not a dependency. Every transition it reports
/// can also be discovered by refetching, and the controller falls back to
/// polling whenever the socket is not connected — so a match stays playable on
/// a network too hostile to hold a WebSocket, which is the network a good
/// share of these players are on.
class BattleController extends StateNotifier<BattleState> {
  BattleController(this._repository, this.matchId) : super(const BattleState()) {
    // A socket almost never survives being backgrounded, and the player is
    // looking at the screen the instant they come back — so that is the moment
    // to reconnect and resync rather than waiting out a backoff.
    _lifecycle = AppLifecycleListener(onResume: _onResume);
    _bootstrap();
  }

  final MultiplayerRepository _repository;
  final String matchId;

  late final AppLifecycleListener _lifecycle;
  MatchSocket? _socket;
  StreamSubscription<MatchSocketEvent>? _socketEvents;
  Timer? _poll;

  /// When the round in play opened, on this device's clock, corrected for skew.
  ///
  /// A Stopwatch started at fetch time would measure from whenever the question
  /// happened to arrive, which on a slow connection is meaningfully later than
  /// when the server started counting — and the difference is scored as
  /// thinking time.
  DateTime? _roundStartedAt;

  /// Poll ticks since the last reconciling refetch while the socket is healthy.
  int _ticksSinceReconcile = 0;

  /// A round fetch is in flight.
  bool _loadingRound = false;

  Future<void> _bootstrap() async {
    await refresh();
    _startPolling();
  }

  void _onResume() {
    _socket?.reconnectNow();
    unawaited(_refreshMatchOnly());
  }

  Future<void> refresh() async {
    try {
      final match = await _repository.fetchMatch(matchId);
      _applyMatch(match);

      if (match.isOver) {
        await _loadResult();
      } else if (_needsRound(match)) {
        await _loadRound();
      }
    } catch (error) {
      state = state.copyWith(isLoading: false, error: _message(error));
    }
  }

  void _applyMatch(MatchState match) {
    state = state.copyWith(match: match, isLoading: false, clearError: true);
    _ensureSocket(match);
  }

  /// Whether the board should be on screen but isn't.
  ///
  /// This is the question the old code asked against whatever match it happened
  /// to be holding, which during the lobby-to-live transition was the stale
  /// lobby — so the player who readied first never fetched a round and sat on a
  /// spinner for the whole match. It is now only ever asked about a match that
  /// has just come back from the server.
  bool _needsRound(MatchState match) {
    if (!match.isMyTurn) return false;
    if (state.isAnswered || state.isSubmitting) return false;
    final round = state.round;
    if (round == null) return true;
    // A round left over from a previous index — a reconnect that missed the
    // reveal, most often.
    return match.delivery == MatchDelivery.live &&
        round.roundIndex != match.currentRoundIndex;
  }

  /// Hold a socket whenever this match could produce events, and rebuild it if
  /// it was never opened — the first attempt used to be the only attempt, so a
  /// blip at open left the screen showing "Reconnecting" until it was closed.
  void _ensureSocket(MatchState match) {
    if (_socket != null) return;
    // An async match has no shared clock and no opponent watching, so a socket
    // would carry nothing worth the connection.
    if (match.delivery != MatchDelivery.live || match.isOver) return;

    final socket = MatchSocket(_repository, matchId: matchId);
    _socket = socket;
    _socketEvents = socket.events.listen(_onSocketEvent);
    unawaited(socket.connect());
  }

  void _onSocketEvent(MatchSocketEvent event) {
    switch (event.kind) {
      case MatchSocketEventKind.connected:
        state = state.copyWith(isConnected: true);
        // Reconnected after a gap. Whatever the replay missed, this catches.
        unawaited(_refreshMatchOnly());
      case MatchSocketEventKind.disconnected:
        state = state.copyWith(isConnected: false);
      case MatchSocketEventKind.message:
        _onServerEvent(event.type, event.data);
    }
  }

  void _onServerEvent(String type, Map<String, dynamic> data) {
    switch (type) {
      case MatchEvents.roundStart:
        _onRoundStart(data);
      case MatchEvents.roundEnd:
        _applyScores(data['scores']);
      case MatchEvents.roundProgress:
        _applyScores(data['scores']);
        final who = data['user_id'];
        final match = state.match;
        if (who is String && match != null) {
          state = state.copyWith(match: match.withAnswered(who));
        }
      case MatchEvents.participant:
        unawaited(_refreshMatchOnly());
      case MatchEvents.finished:
      case MatchEvents.cancelled:
        unawaited(refresh());
    }
  }

  /// A new round opened.
  ///
  /// The event carries the prompt, so the board is rendered from it directly
  /// and the round starts with nothing on the network. Only an event without a
  /// question payload falls back to fetching it.
  void _onRoundStart(Map<String, dynamic> data) {
    final match = state.match;
    state = state.copyWith(
      clearFeedback: true,
      clearSelection: true,
      clearRound: true,
      match: match?.withRoundReset(),
    );

    final round = MatchRound.fromEvent(data);
    if (round != null) {
      _startRoundClock(round);
      state = state.copyWith(round: round);
    } else {
      unawaited(_loadRound());
    }
    // Reconciles scores and status behind the already-rendered question.
    unawaited(_refreshMatchOnly());
  }

  void _applyScores(Object? raw) {
    final match = state.match;
    if (match == null || raw is! Map) return;
    final scores = <String, int>{
      for (final entry in raw.entries)
        if (entry.value is int) entry.key.toString(): entry.value as int,
    };
    if (scores.isEmpty) return;
    state = state.copyWith(match: match.withScores(scores));
  }

  /// Anchor the answer clock to when the *server* opened the round.
  void _startRoundClock(MatchRound round) {
    _roundStartedAt = round.servedAt.add(
      DateTime.now().toUtc().difference(round.serverTime),
    );
  }

  int _elapsedMs(MatchRound round) {
    final startedAt = _roundStartedAt;
    if (startedAt == null) return round.timeLimitMs;
    final elapsed = DateTime.now().difference(startedAt).inMilliseconds;
    return elapsed.clamp(0, round.timeLimitMs);
  }

  Future<void> _refreshMatchOnly() async {
    try {
      final match = await _repository.fetchMatch(matchId);
      _applyMatch(match);
      _dropStaleRound(match);
      if (match.isOver) {
        await _loadResult();
      } else if (_needsRound(match)) {
        // The lobby-to-live transition, and every recovery path back into it.
        await _loadRound();
      }
    } catch (_) {
      // A failed background refresh is not worth surfacing; the next poll or
      // event will correct it.
    }
  }

  /// Let go of a verdict the match has already moved past.
  ///
  /// `round.start` normally does this. Without a socket there is no
  /// `round.start`, and a player who answered would hold their own reveal on
  /// screen for the rest of the match — [_needsRound] declines to fetch
  /// anything while an answer is being shown, which is correct during the
  /// reveal pause and wrong once the shared clock has moved on.
  void _dropStaleRound(MatchState match) {
    if (match.delivery != MatchDelivery.live) return;
    final round = state.round;
    if (round == null || match.currentRoundIndex <= round.roundIndex) return;

    state = state.copyWith(
      clearFeedback: true,
      clearSelection: true,
      clearRound: true,
      match: match.withRoundReset(),
    );
  }

  Future<void> _loadRound() async {
    // The poll and the event path can both decide a round is needed within the
    // same tick. One request, not two.
    if (_loadingRound) return;
    _loadingRound = true;
    try {
      final round = await _repository.fetchRound(matchId);
      _startRoundClock(round);
      state = state.copyWith(round: round, clearSelection: true, clearError: true);
    } catch (error) {
      // 409 here is normal: the round closed between the event and the fetch,
      // or this player has already played their whole board.
      if (!_isConflict(error)) {
        state = state.copyWith(error: _message(error));
      }
    } finally {
      _loadingRound = false;
    }
  }

  Future<void> _loadResult() async {
    if (state.result != null) return;
    try {
      final result = await _repository.fetchResult(matchId);
      state = state.copyWith(result: result, clearRound: true);
    } catch (_) {
      // Non-fatal: the result screen refetches on open.
    }
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) {
      final match = state.match;
      if (match == null) {
        // The opening fetch failed. Keep trying, or the screen is an error
        // state that never recovers on its own.
        unawaited(refresh());
        return;
      }
      if (match.isOver) return;
      _ensureSocket(match);

      if (state.isConnected && match.delivery == MatchDelivery.live) {
        // The socket reports every transition, so this is not the mechanism —
        // but it is not skipped entirely either. A feed that looks alive and
        // has quietly stopped delivering used to switch polling off and strand
        // the match; a slow reconcile costs one request per ten seconds and
        // removes that failure mode altogether.
        _ticksSinceReconcile++;
        if (_ticksSinceReconcile < 5) return;
      }
      _ticksSinceReconcile = 0;
      unawaited(_refreshMatchOnly());
    });
  }

  Future<void> submit(int? optionIndex) async {
    final round = state.round;
    if (round == null || state.isSubmitting || state.isAnswered) return;

    final elapsed = _elapsedMs(round);
    state = state.copyWith(
      isSubmitting: true,
      selectedOptionIndex: optionIndex,
      clearError: true,
    );

    try {
      final feedback = await _repository.answer(
        matchId,
        roundIndex: round.roundIndex,
        selectedOptionIndex: optionIndex,
        clientElapsedMs: elapsed,
      );
      state = state.copyWith(feedback: feedback, isSubmitting: false);

      if (feedback.matchFinished) {
        await _refreshMatchOnly();
        await _loadResult();
      } else if (state.match?.delivery == MatchDelivery.asynchronous) {
        // No shared clock to wait on. Give the verdict a beat to read, then
        // advance this player's own board.
        await Future<void>.delayed(const Duration(milliseconds: 1600));
        if (!mounted) return;
        state = state.copyWith(
          clearFeedback: true,
          clearSelection: true,
          clearRound: true,
        );
        await _loadRound();
      } else if (!state.isConnected) {
        // With a socket, `round.progress` and `round.end` carry the standings
        // and this refetch is dead weight on the one screen where a round trip
        // shows. Without one, it is how the score moves at all.
        await _refreshMatchOnly();
      }
    } catch (error) {
      state = state.copyWith(isSubmitting: false, error: _message(error));
      if (_isConflict(error)) await refresh();
    }
  }

  /// Time ran out with nothing chosen. Submitted explicitly so the round
  /// closes on this player's own action rather than waiting for the sweep.
  Future<void> timeout() => submit(null);

  Future<void> setReady({required bool ready}) async {
    try {
      final match = await _repository.setReady(matchId, ready: ready);
      _applyMatch(match);
      if (_needsRound(match)) await _loadRound();
    } catch (error) {
      state = state.copyWith(error: _message(error));
    }
  }

  Future<void> start() async {
    try {
      final match = await _repository.start(matchId);
      _applyMatch(match);
      if (_needsRound(match)) await _loadRound();
    } catch (error) {
      state = state.copyWith(error: _message(error));
    }
  }

  Future<void> accept() async {
    try {
      final match = await _repository.respond(matchId, accept: true);
      _applyMatch(match);
      if (_needsRound(match)) await _loadRound();
    } catch (error) {
      state = state.copyWith(error: _message(error));
    }
  }

  Future<void> decline() async {
    try {
      final match = await _repository.respond(matchId, accept: false);
      _applyMatch(match);
    } catch (error) {
      state = state.copyWith(error: _message(error));
    }
  }

  Future<void> leave() async {
    try {
      final match = await _repository.leave(matchId);
      state = state.copyWith(match: match);
    } catch (_) {
      // Leaving is best-effort — the server forfeits an absent player anyway.
    }
  }

  bool _isConflict(Object error) => _statusOf(error) == 409;

  int? _statusOf(Object error) {
    final dynamic dynamicError = error;
    try {
      return dynamicError.response?.statusCode as int?;
    } catch (_) {
      return null;
    }
  }

  /// The server's machine-readable `detail.code`, for the UI to localize.
  String _message(Object error) {
    final dynamic dynamicError = error;
    try {
      final detail = dynamicError.response?.data?['detail'];
      if (detail is Map && detail['code'] is String) return detail['code'] as String;
      if (detail is String) return detail;
    } catch (_) {
      // Fall through to the generic code.
    }
    return 'network_error';
  }

  @override
  void dispose() {
    _poll?.cancel();
    _lifecycle.dispose();
    _socketEvents?.cancel();
    unawaited(_socket?.dispose());
    super.dispose();
  }
}

final battleControllerProvider = StateNotifierProvider.autoDispose
    .family<BattleController, BattleState, String>((ref, matchId) {
  return BattleController(ref.watch(multiplayerRepositoryProvider), matchId);
});
