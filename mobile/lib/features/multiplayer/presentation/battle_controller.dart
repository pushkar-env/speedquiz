import 'dart:async';

import 'package:flutter/foundation.dart';
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
    _bootstrap();
  }

  final MultiplayerRepository _repository;
  final String matchId;

  MatchSocket? _socket;
  StreamSubscription<MatchSocketEvent>? _socketEvents;
  Timer? _poll;
  Stopwatch? _roundClock;

  Future<void> _bootstrap() async {
    await refresh();
    await _openSocket();
    _startPolling();
  }

  Future<void> refresh() async {
    try {
      final match = await _repository.fetchMatch(matchId);
      state = state.copyWith(match: match, isLoading: false, clearError: true);

      if (match.isOver) {
        await _loadResult();
      } else if (match.isMyTurn) {
        await _loadRound();
      }
    } catch (error) {
      state = state.copyWith(isLoading: false, error: _message(error));
    }
  }

  Future<void> _openSocket() async {
    final match = state.match;
    // An async match has no shared clock and no opponent watching, so a socket
    // would carry nothing worth the connection.
    if (match == null || match.delivery != MatchDelivery.live || match.isOver) return;

    final socket = MatchSocket(_repository, matchId: matchId);
    _socket = socket;
    _socketEvents = socket.events.listen(_onSocketEvent);
    await socket.connect();
  }

  void _onSocketEvent(MatchSocketEvent event) {
    switch (event.kind) {
      case MatchSocketEventKind.connected:
        state = state.copyWith(isConnected: true);
      case MatchSocketEventKind.disconnected:
        state = state.copyWith(isConnected: false);
      case MatchSocketEventKind.message:
        _onServerEvent(event.type, event.data);
    }
  }

  void _onServerEvent(String type, Map<String, dynamic> data) {
    switch (type) {
      case MatchEvents.roundStart:
        // Clear the previous verdict and pull the new question. The event
        // carries the round index but not the prompt — the question comes over
        // HTTP so the socket never has to be trusted with game content.
        state = state.copyWith(
          clearFeedback: true,
          clearSelection: true,
          clearRound: true,
        );
        unawaited(_loadRound());
        unawaited(_refreshMatchOnly());
      case MatchEvents.roundEnd:
      case MatchEvents.participant:
      case MatchEvents.roundProgress:
        unawaited(_refreshMatchOnly());
      case MatchEvents.finished:
      case MatchEvents.cancelled:
        unawaited(refresh());
    }
  }

  Future<void> _refreshMatchOnly() async {
    try {
      final match = await _repository.fetchMatch(matchId);
      state = state.copyWith(match: match);
      if (match.isOver) await _loadResult();
    } catch (_) {
      // A failed background refresh is not worth surfacing; the next poll or
      // event will correct it.
    }
  }

  Future<void> _loadRound() async {
    final match = state.match;
    if (match == null || !match.isMyTurn) return;
    try {
      final round = await _repository.fetchRound(matchId);
      _roundClock = Stopwatch()..start();
      state = state.copyWith(round: round, clearSelection: true, clearError: true);
    } catch (error) {
      // 409 here is normal: the round closed between the event and the fetch.
      if (!_isConflict(error)) {
        state = state.copyWith(error: _message(error));
      }
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
    _poll = Timer.periodic(const Duration(seconds: 3), (_) {
      final match = state.match;
      if (match == null || match.isOver) return;
      // While the socket is healthy it is already reporting every transition,
      // so polling would be pure duplicate load. This is the fallback path.
      if (state.isConnected && match.delivery == MatchDelivery.live) return;
      unawaited(_refreshMatchOnly());
    });
  }

  Future<void> submit(int? optionIndex) async {
    final round = state.round;
    if (round == null || state.isSubmitting || state.isAnswered) return;

    final elapsed = _roundClock?.elapsedMilliseconds ?? round.timeLimitMs;
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
      await _refreshMatchOnly();

      if (feedback.matchFinished) {
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
      state = state.copyWith(match: match, clearError: true);
      if (match.status == MatchStatus.live) await _loadRound();
    } catch (error) {
      state = state.copyWith(error: _message(error));
    }
  }

  Future<void> start() async {
    try {
      final match = await _repository.start(matchId);
      state = state.copyWith(match: match, clearError: true);
      await _loadRound();
    } catch (error) {
      state = state.copyWith(error: _message(error));
    }
  }

  Future<void> accept() async {
    try {
      final match = await _repository.respond(matchId, accept: true);
      state = state.copyWith(match: match, clearError: true);
      if (match.isMyTurn) await _loadRound();
    } catch (error) {
      state = state.copyWith(error: _message(error));
    }
  }

  Future<void> decline() async {
    try {
      final match = await _repository.respond(matchId, accept: false);
      state = state.copyWith(match: match, clearError: true);
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
    _socketEvents?.cancel();
    unawaited(_socket?.dispose());
    super.dispose();
  }
}

final battleControllerProvider = StateNotifierProvider.autoDispose
    .family<BattleController, BattleState, String>((ref, matchId) {
  return BattleController(ref.watch(multiplayerRepositoryProvider), matchId);
});
