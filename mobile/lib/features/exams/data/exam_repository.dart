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
    String pacing = 'casual',
    int? durationMinutes,
    int? perQuestionSeconds,
  }) async {
    final response = await _dio.post(
      '$_base/papers/$paperId/attempts',
      data: {
        'mode': mode,
        'pacing': pacing,
        'section_id': ?sectionId,
        'duration_minutes': ?durationMinutes,
        'per_question_seconds': ?perQuestionSeconds,
      },
    );
    return MockAttempt.fromJson((response.data as Map).cast<String, dynamic>());
  }

  /// Practice mode only: grade one question now and reveal the solution.
  Future<AnswerCheck> checkAnswer(
    String attemptId, {
    required String examQuestionId,
    List<int> selected = const [],
    double? numericValue,
  }) async {
    final response = await _dio.post(
      '$_base/attempts/$attemptId/check',
      data: {
        'exam_question_id': examQuestionId,
        'selected': selected,
        'numeric_value': ?numericValue,
      },
    );
    return AnswerCheck.fromJson((response.data as Map).cast<String, dynamic>());
  }

  Future<Notebook> fetchNotebook({
    String status = 'open',
    String? chapter,
    int limit = 50,
    int offset = 0,
  }) async {
    final response = await _dio.get(
      '$_base/notebook',
      queryParameters: {
        'status': status,
        'chapter': ?chapter,
        'limit': limit,
        'offset': offset,
      },
    );
    return Notebook.fromJson((response.data as Map).cast<String, dynamic>());
  }

  Future<void> setNotebookStatus(String entryId, String status) async {
    await _dio.patch('$_base/notebook/$entryId', data: {'status': status});
  }

  Future<void> deleteNotebookEntry(String entryId) async {
    await _dio.delete('$_base/notebook/$entryId');
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

/// The mistake notebook, filtered by status.
final notebookProvider = FutureProvider.family<Notebook, String>((ref, status) {
  return ref.watch(examRepositoryProvider).fetchNotebook(status: status);
});

/// Just the open-mistake count, for the badge on the Home entry.
///
/// A separate provider rather than reading `notebookProvider`'s length: Home
/// only needs the number, and pulling fifty entries with their content blocks
/// and figures to render "12" would be a wasteful request on every visit.
final notebookCountProvider = FutureProvider<int>((ref) async {
  final notebook = await ref
      .watch(examRepositoryProvider)
      .fetchNotebook(status: 'open', limit: 1);
  return notebook.openCount;
});
