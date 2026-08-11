import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/config/app_config.dart';
import 'package:speedquiz/core/network/dio_client.dart';
import 'package:speedquiz/features/leaderboard/domain/leaderboard_models.dart';

class LeaderboardRepository {
  LeaderboardRepository(this._dio);

  final Dio _dio;

  Future<LeaderboardBoard> fetch({
    required String scope,
    int limit = 50,
  }) async {
    final response = await _dio.get(
      '${AppConfig.apiPrefix}/leaderboards',
      queryParameters: {'scope': scope, 'limit': limit},
    );
    return LeaderboardBoard.fromJson(response.data as Map<String, dynamic>);
  }
}

final leaderboardRepositoryProvider = Provider<LeaderboardRepository>((ref) {
  return LeaderboardRepository(ref.watch(dioProvider));
});

final leaderboardProvider =
    FutureProvider.autoDispose.family<LeaderboardBoard, String>((ref, scope) {
  return ref.watch(leaderboardRepositoryProvider).fetch(scope: scope);
});
