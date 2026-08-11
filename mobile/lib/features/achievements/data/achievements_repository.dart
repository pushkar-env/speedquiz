import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/config/app_config.dart';
import 'package:speedquiz/core/network/dio_client.dart';
import 'package:speedquiz/features/achievements/domain/achievement_models.dart';

class AchievementsRepository {
  AchievementsRepository(this._dio);

  final Dio _dio;

  Future<AchievementList> listAchievements() async {
    final response = await _dio.get('${AppConfig.apiPrefix}/achievements');
    return AchievementList.fromJson(response.data as Map<String, dynamic>);
  }
}

final achievementsRepositoryProvider = Provider<AchievementsRepository>((ref) {
  return AchievementsRepository(ref.watch(dioProvider));
});

final achievementsProvider = FutureProvider.autoDispose<AchievementList>((ref) {
  return ref.watch(achievementsRepositoryProvider).listAchievements();
});
