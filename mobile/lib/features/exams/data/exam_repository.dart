import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/config/app_config.dart';
import 'package:speedquiz/core/network/dio_client.dart';
import 'package:speedquiz/features/exams/domain/exam_models.dart';

/// HTTP surface for exam mode.
class ExamRepository {
  ExamRepository(this._dio);

  final Dio _dio;

  static const _base = '${AppConfig.apiPrefix}/exams';

  Future<List<ExamSummary>> fetchExams() async {
    final response = await _dio.get(_base);
    return (response.data as List)
        .map((e) => ExamSummary.fromJson((e as Map).cast<String, dynamic>()))
        .toList(growable: false);
  }

  Future<List<ExamPaper>> fetchPapers(String examSlug) async {
    final response = await _dio.get('$_base/$examSlug/papers');
    return (response.data as List)
        .map((e) => ExamPaper.fromJson((e as Map).cast<String, dynamic>()))
        .toList(growable: false);
  }

  /// The whole paper, fetched once before the clock starts.
  Future<PaperManifest> fetchManifest(String paperId) async {
    final response = await _dio.get('$_base/papers/$paperId/manifest');
    return PaperManifest.fromJson(
      (response.data as Map).cast<String, dynamic>(),
    );
  }

  Future<MockAttempt> startAttempt(
    String paperId, {
    String mode = 'full',
    String? sectionId,
  }) async {
    final response = await _dio.post(
      '$_base/papers/$paperId/attempts',
      data: {'mode': mode, 'section_id': ?sectionId},
    );
    return MockAttempt.fromJson((response.data as Map).cast<String, dynamic>());
  }

  Future<MockAttempt> fetchAttempt(String attemptId) async {
    final response = await _dio.get('$_base/attempts/$attemptId');
    return MockAttempt.fromJson((response.data as Map).cast<String, dynamic>());
  }

  /// Push a delta batch. Idempotent, so a retry after a dropped connection is
  /// always safe — the server keeps whichever revision is newer.
  Future<SyncOutcome> syncResponses(
    String attemptId,
    List<QuestionResponse> responses,
  ) async {
    final response = await _dio.put(
      '$_base/attempts/$attemptId/responses',
      data: {'responses': responses.map((r) => r.toJson()).toList()},
    );
    final json = (response.data as Map).cast<String, dynamic>();
    return SyncOutcome(
      accepted: (json['accepted'] as num?)?.toInt() ?? 0,
      rejected: (json['rejected'] as num?)?.toInt() ?? 0,
      remainingMs: (json['remaining_ms'] as num?)?.toInt() ?? 0,
      status: json['status'] as String? ?? 'in_progress',
    );
  }

  Future<AttemptResult> submit(String attemptId) async {
    final response = await _dio.post('$_base/attempts/$attemptId/submit');
    return AttemptResult.fromJson(
      (response.data as Map).cast<String, dynamic>(),
    );
  }

  Future<AttemptResult> fetchResult(String attemptId) async {
    final response = await _dio.get('$_base/attempts/$attemptId/result');
    return AttemptResult.fromJson(
      (response.data as Map).cast<String, dynamic>(),
    );
  }
}

class SyncOutcome {
  const SyncOutcome({
    required this.accepted,
    required this.rejected,
    required this.remainingMs,
    required this.status,
  });

  final int accepted;
  final int rejected;
  final int remainingMs;
  final String status;

  bool get attemptClosed => status != 'in_progress';
}

final examRepositoryProvider = Provider<ExamRepository>(
  (ref) => ExamRepository(ref.watch(dioProvider)),
);

final examListProvider = FutureProvider<List<ExamSummary>>(
  (ref) => ref.watch(examRepositoryProvider).fetchExams(),
);

final examPapersProvider = FutureProvider.family<List<ExamPaper>, String>((
  ref,
  slug,
) {
  return ref.watch(examRepositoryProvider).fetchPapers(slug);
});

final paperManifestProvider = FutureProvider.family<PaperManifest, String>((
  ref,
  paperId,
) {
  return ref.watch(examRepositoryProvider).fetchManifest(paperId);
});

final attemptResultProvider = FutureProvider.family<AttemptResult, String>((
  ref,
  attemptId,
) {
  return ref.watch(examRepositoryProvider).fetchResult(attemptId);
});
