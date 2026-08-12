import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/config/app_config.dart';
import 'package:speedquiz/core/network/dio_client.dart';
import 'package:speedquiz/features/quiz/domain/quiz_models.dart';

class QuizRepository {
  QuizRepository(this._dio);

  final Dio _dio;

  /// Starts a run.
  ///
  /// [language] is the content language for the whole session. Omitted, the
  /// server falls back to the language this player last used — which is what
  /// keeps a client that predates languages working unchanged.
  Future<QuizSession> createSession({
    required String topicId,
    required String mode,
    required String difficulty,
    bool adaptive = false,
    String? language,
  }) async {
    final response = await _dio.post(
      '${AppConfig.apiPrefix}/quiz/sessions',
      data: {
        'topic_id': topicId,
        'mode': mode,
        'difficulty': adaptive ? 'medium' : difficulty,
        'adaptive': adaptive,
        'language': ?language,
      },
    );
    return QuizSession.fromJson(response.data as Map<String, dynamic>);
  }

  Future<AnswerFeedback> submitAnswer({
    required String sessionId,
    required String quizQuestionId,
    int? selectedOptionIndex,
    int? clientElapsedMs,
    bool timedOut = false,
  }) async {
    final response = await _dio.post(
      '${AppConfig.apiPrefix}/quiz/sessions/$sessionId/answer',
      data: {
        'quiz_question_id': quizQuestionId,
        'selected_option_index': selectedOptionIndex,
        'client_elapsed_ms': clientElapsedMs,
        'timed_out': timedOut,
      },
    );
    return AnswerFeedback.fromJson(response.data as Map<String, dynamic>);
  }

  Future<QuizResult> finishSession(String sessionId) async {
    final response = await _dio.post(
      '${AppConfig.apiPrefix}/quiz/sessions/$sessionId/finish',
    );
    return QuizResult.fromJson(response.data as Map<String, dynamic>);
  }

  Future<QuizResult> getResult(String sessionId) async {
    final response = await _dio.get(
      '${AppConfig.apiPrefix}/quiz/sessions/$sessionId/result',
    );
    return QuizResult.fromJson(response.data as Map<String, dynamic>);
  }
}

final quizRepositoryProvider = Provider<QuizRepository>((ref) {
  return QuizRepository(ref.watch(dioProvider));
});
