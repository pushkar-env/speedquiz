import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/config/app_config.dart';
import 'package:speedquiz/core/network/dio_client.dart';
import 'package:speedquiz/features/multiplayer/domain/multiplayer_models.dart';

/// HTTP surface for matches and the ranked ladder.
///
/// Answers go over HTTP even during a live match, deliberately: the socket is
/// a notification channel, and routing a scored write through it would put the
/// one operation that must not be lost on the one transport that drops.
class MultiplayerRepository {
  MultiplayerRepository(this._dio);

  final Dio _dio;

  static const _base = '${AppConfig.apiPrefix}/multiplayer';

  Future<MatchState> createChallenge({
    required String topicId,
    String? opponentUserId,
    String difficulty = 'medium',
    String? language,
    int? questionCount,
    bool isRoom = false,
    int? maxPlayers,
  }) async {
    final response = await _dio.post(
      '$_base/matches',
      data: {
        'topic_id': topicId,
        'difficulty': difficulty,
        'format': isRoom ? 'room' : 'duel',
        'opponent_user_id': ?opponentUserId,
        'language': ?language,
        'question_count': ?questionCount,
        'max_players': ?maxPlayers,
      },
    );
    return MatchState.fromJson(response.data as Map<String, dynamic>);
  }

  Future<MatchState> joinByCode(String code) async {
    final response = await _dio.post('$_base/matches/join', data: {'code': code});
    return MatchState.fromJson(response.data as Map<String, dynamic>);
  }

  Future<MatchState> fetchMatch(String matchId) async {
    final response = await _dio.get('$_base/matches/$matchId');
    return MatchState.fromJson(response.data as Map<String, dynamic>);
  }

  Future<({List<MatchState> active, List<MatchState> recent})> fetchMatches() async {
    final response = await _dio.get('$_base/matches');
    final data = response.data as Map<String, dynamic>;
    List<MatchState> parse(String key) =>
        (data[key] as List<dynamic>? ?? const [])
            .map((e) => MatchState.fromJson(e as Map<String, dynamic>))
            .toList(growable: false);
    return (active: parse('active'), recent: parse('recent'));
  }

  Future<MatchState> respond(String matchId, {required bool accept}) async {
    final response = await _dio.post(
      '$_base/matches/$matchId/${accept ? 'accept' : 'decline'}',
    );
    return MatchState.fromJson(response.data as Map<String, dynamic>);
  }

  Future<MatchState> setReady(String matchId, {required bool ready}) async {
    final response = await _dio.post(
      '$_base/matches/$matchId/ready',
      queryParameters: {'ready': ready},
    );
    return MatchState.fromJson(response.data as Map<String, dynamic>);
  }

  Future<MatchState> start(String matchId) async {
    final response = await _dio.post('$_base/matches/$matchId/start');
    return MatchState.fromJson(response.data as Map<String, dynamic>);
  }

  Future<MatchRound> fetchRound(String matchId) async {
    final response = await _dio.get('$_base/matches/$matchId/round');
    return MatchRound.fromJson(response.data as Map<String, dynamic>);
  }

  Future<MatchAnswerFeedback> answer(
    String matchId, {
    required int roundIndex,
    required int? selectedOptionIndex,
    required int clientElapsedMs,
  }) async {
    final response = await _dio.post(
      '$_base/matches/$matchId/answer',
      data: {
        'round_index': roundIndex,
        'selected_option_index': selectedOptionIndex,
        'client_elapsed_ms': clientElapsedMs,
      },
    );
    return MatchAnswerFeedback.fromJson(response.data as Map<String, dynamic>);
  }

  Future<MatchState> leave(String matchId) async {
    final response = await _dio.post('$_base/matches/$matchId/leave');
    return MatchState.fromJson(response.data as Map<String, dynamic>);
  }

  Future<MatchResult> fetchResult(String matchId) async {
    final response = await _dio.get('$_base/matches/$matchId/result');
    return MatchResult.fromJson(response.data as Map<String, dynamic>);
  }

  // --- Ranked --------------------------------------------------------------

  Future<RankedProfile> fetchRank() async {
    final response = await _dio.get('$_base/ranked/me');
    return RankedProfile.fromJson(response.data as Map<String, dynamic>);
  }

  Future<({String seasonKey, List<RankedLeaderboardEntry> items, RankedLeaderboardEntry? me})>
      fetchRankedLeaderboard({int limit = 50}) async {
    final response = await _dio.get(
      '$_base/ranked/leaderboard',
      queryParameters: {'limit': limit},
    );
    final data = response.data as Map<String, dynamic>;
    return (
      seasonKey: data['season_key'] as String? ?? '',
      items: (data['items'] as List<dynamic>? ?? const [])
          .map((e) => RankedLeaderboardEntry.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
      me: data['me'] == null
          ? null
          : RankedLeaderboardEntry.fromJson(data['me'] as Map<String, dynamic>),
    );
  }

  Future<QueueTicket> joinQueue({String? language}) async {
    final response = await _dio.post(
      '$_base/ranked/queue',
      data: {'language': ?language},
    );
    return QueueTicket.fromJson(response.data as Map<String, dynamic>);
  }

  Future<QueueTicket> pollQueue() async {
    final response = await _dio.get('$_base/ranked/queue');
    return QueueTicket.fromJson(response.data as Map<String, dynamic>);
  }

  Future<void> leaveQueue() => _dio.delete('$_base/ranked/queue');

  // --- Realtime ------------------------------------------------------------

  /// A single-use ticket to open the match socket with.
  ///
  /// Short-lived and exchanged for exactly one connection, because a WebSocket
  /// URL's query string ends up in proxy logs — an access token there would
  /// outlive the connection by an hour.
  Future<({String ticket, String path})> realtimeTicket() async {
    final response = await _dio.post('$_base/realtime/ticket');
    final data = response.data as Map<String, dynamic>;
    return (ticket: data['ticket'] as String, path: data['url'] as String);
  }
}

final multiplayerRepositoryProvider = Provider<MultiplayerRepository>((ref) {
  return MultiplayerRepository(ref.watch(dioProvider));
});
