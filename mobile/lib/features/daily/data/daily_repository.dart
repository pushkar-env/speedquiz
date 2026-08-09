import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:quizverse/core/config/app_config.dart';
import 'package:quizverse/core/network/dio_client.dart';
import 'package:quizverse/features/daily/domain/daily_models.dart';
import 'package:quizverse/features/quiz/domain/quiz_models.dart';

class DailyRepository {
  DailyRepository(this._dio);

  final Dio _dio;

  Future<DailyChallengeInfo> fetchToday() async {
    final response = await _dio.get('${AppConfig.apiPrefix}/daily-challenge');
    return DailyChallengeInfo.fromJson(response.data as Map<String, dynamic>);
  }

  Future<QuizSession> start() async {
    final response =
        await _dio.post('${AppConfig.apiPrefix}/daily-challenge/start');
    return QuizSession.fromJson(response.data as Map<String, dynamic>);
  }
}

final dailyRepositoryProvider = Provider<DailyRepository>((ref) {
  return DailyRepository(ref.watch(dioProvider));
});

final dailyChallengeProvider =
    FutureProvider.autoDispose<DailyChallengeInfo>((ref) {
  return ref.watch(dailyRepositoryProvider).fetchToday();
});
