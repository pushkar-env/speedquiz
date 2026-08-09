import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:quizverse/core/config/app_config.dart';
import 'package:quizverse/core/network/dio_client.dart';
import 'package:quizverse/features/quiz/domain/quiz_models.dart';

class CustomTopicResult {
  const CustomTopicResult({
    required this.id,
    required this.status,
    required this.cacheHit,
    required this.approvedCount,
    this.classifiedSubject,
    this.topicId,
    this.topicName,
    this.session,
  });

  final String id;
  final String status;
  final bool cacheHit;
  final int approvedCount;
  final String? classifiedSubject;
  final String? topicId;
  final String? topicName;
  final QuizSession? session;

  factory CustomTopicResult.fromJson(Map<String, dynamic> json) {
    return CustomTopicResult(
      id: json['id'] as String,
      status: json['status'] as String,
      cacheHit: json['cache_hit'] as bool? ?? false,
      approvedCount: json['approved_count'] as int? ?? 0,
      classifiedSubject: json['classified_subject'] as String?,
      topicId: json['topic_id'] as String?,
      topicName: json['topic_name'] as String?,
      session: json['session'] == null
          ? null
          : QuizSession.fromJson(json['session'] as Map<String, dynamic>),
    );
  }
}

class TeachMeResult {
  const TeachMeResult({
    required this.questionId,
    required this.whyCorrect,
    required this.whyWrong,
    required this.keyConcept,
    required this.memorableFact,
  });

  final String questionId;
  final String whyCorrect;
  final String whyWrong;
  final String keyConcept;
  final String memorableFact;

  factory TeachMeResult.fromJson(Map<String, dynamic> json) {
    return TeachMeResult(
      questionId: json['question_id'] as String,
      whyCorrect: json['why_correct'] as String? ?? '',
      whyWrong: json['why_wrong'] as String? ?? '',
      keyConcept: json['key_concept'] as String? ?? '',
      memorableFact: json['memorable_fact'] as String? ?? '',
    );
  }
}

class CustomTopicsRepository {
  CustomTopicsRepository(this._dio);

  final Dio _dio;

  Future<CustomTopicResult> create({
    required String prompt,
    required String difficulty,
    required String mode,
    String? style,
    int requestedCount = 10,
  }) async {
    final response = await _dio.post(
      '${AppConfig.apiPrefix}/custom-topics',
      data: {
        'prompt': prompt,
        'difficulty': difficulty,
        'mode': mode,
        if (style != null && style.trim().isNotEmpty) 'style': style.trim(),
        'requested_count': requestedCount,
      },
    );
    return CustomTopicResult.fromJson(response.data as Map<String, dynamic>);
  }

  Future<TeachMeResult> teachMe({
    required String questionId,
    String? userOptionText,
  }) async {
    final response = await _dio.post(
      '${AppConfig.apiPrefix}/questions/$questionId/teach',
      data: {
        'user_option_text': ?userOptionText,
      },
    );
    return TeachMeResult.fromJson(response.data as Map<String, dynamic>);
  }

  Future<void> reportQuestion({
    required String questionId,
    required String reason,
    String? details,
  }) async {
    await _dio.post(
      '${AppConfig.apiPrefix}/questions/$questionId/report',
      data: {
        'reason': reason,
        'details': ?details,
      },
    );
  }
}

final customTopicsRepositoryProvider = Provider<CustomTopicsRepository>((ref) {
  return CustomTopicsRepository(ref.watch(dioProvider));
});
