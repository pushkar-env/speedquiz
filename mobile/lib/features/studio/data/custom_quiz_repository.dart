import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/config/app_config.dart';
import 'package:speedquiz/core/network/dio_client.dart';
import 'package:speedquiz/features/multiplayer/domain/multiplayer_models.dart';
import 'package:speedquiz/features/studio/domain/custom_quiz_models.dart';

/// HTTP surface for player-authored quizzes.
///
/// Every mutation returns the **whole** quiz rather than a patch. The editor is
/// a screen where one action changes several derived things at once — adding a
/// question moves the count, can clear a publish blocker, and can flip the
/// publish button from disabled to enabled — and re-rendering from one
/// authoritative payload is how those stay consistent without the client
/// re-deriving server rules it would inevitably get subtly wrong.
class CustomQuizRepository {
  CustomQuizRepository(this._dio);

  final Dio _dio;

  static const _base = '${AppConfig.apiPrefix}/custom-quizzes';

  Future<CustomQuizLibrary> fetchLibrary() async {
    final response = await _dio.get(_base);
    return CustomQuizLibrary.fromJson(response.data as Map<String, dynamic>);
  }

  Future<CustomQuiz> fetchQuiz(String quizId) async {
    final response = await _dio.get('$_base/$quizId');
    return CustomQuiz.fromJson(response.data as Map<String, dynamic>);
  }

  /// Redeem a share code. Also grants standing access, so the code is needed
  /// exactly once — a friend who played yesterday just opens it from their
  /// library.
  Future<CustomQuiz> openByCode(String code) async {
    final response = await _dio.get('$_base/code/${code.toUpperCase()}');
    return CustomQuiz.fromJson(response.data as Map<String, dynamic>);
  }

  Future<CustomQuiz> create({
    required String title,
    String? description,
    String? icon,
    String? language,
    QuizVisibility visibility = QuizVisibility.private,
    String defaultMode = 'casual',
    String defaultDifficulty = 'medium',
    List<CustomQuizQuestion> questions = const [],
  }) async {
    final response = await _dio.post(
      _base,
      data: {
        'title': title,
        'description': ?description,
        'icon': ?icon,
        'language': ?language,
        'visibility': visibility.wire,
        'default_mode': defaultMode,
        'default_difficulty': defaultDifficulty,
        if (questions.isNotEmpty)
          'questions': questions.map((q) => q.toJson()).toList(),
      },
    );
    return CustomQuiz.fromJson(response.data as Map<String, dynamic>);
  }

  Future<CustomQuiz> update(
    String quizId, {
    String? title,
    String? description,
    String? icon,
    QuizVisibility? visibility,
    String? defaultMode,
    String? defaultDifficulty,
  }) async {
    final response = await _dio.patch(
      '$_base/$quizId',
      data: {
        'title': ?title,
        // Pass an empty string to clear the description; the server turns it
        // into NULL. Passing null instead leaves it untouched.
        'description': ?description,
        'icon': ?icon,
        if (visibility != null) 'visibility': visibility.wire,
        'default_mode': ?defaultMode,
        'default_difficulty': ?defaultDifficulty,
      },
    );
    return CustomQuiz.fromJson(response.data as Map<String, dynamic>);
  }

  /// Permanent. Fails with `quiz_has_plays` once anyone has played it — the
  /// author is meant to [archive] that one instead.
  Future<void> delete(String quizId) => _dio.delete('$_base/$quizId');

  Future<CustomQuiz> publish(String quizId) => _lifecycle(quizId, 'publish');

  Future<CustomQuiz> unpublish(String quizId) => _lifecycle(quizId, 'unpublish');

  Future<CustomQuiz> archive(String quizId) => _lifecycle(quizId, 'archive');

  Future<CustomQuiz> restore(String quizId) => _lifecycle(quizId, 'restore');

  Future<CustomQuiz> _lifecycle(String quizId, String action) async {
    final response = await _dio.post('$_base/$quizId/$action');
    return CustomQuiz.fromJson(response.data as Map<String, dynamic>);
  }

  Future<CustomQuiz> addQuestion(
    String quizId,
    CustomQuizQuestion question,
  ) async {
    final response = await _dio.post(
      '$_base/$quizId/questions',
      data: question.toJson(),
    );
    return CustomQuiz.fromJson(response.data as Map<String, dynamic>);
  }

  Future<CustomQuiz> updateQuestion(
    String quizId,
    String questionId,
    CustomQuizQuestion question,
  ) async {
    final response = await _dio.put(
      '$_base/$quizId/questions/$questionId',
      data: question.toJson(),
    );
    return CustomQuiz.fromJson(response.data as Map<String, dynamic>);
  }

  Future<CustomQuiz> deleteQuestion(String quizId, String questionId) async {
    final response = await _dio.delete('$_base/$quizId/questions/$questionId');
    return CustomQuiz.fromJson(response.data as Map<String, dynamic>);
  }

  Future<CustomQuiz> reorderQuestions(
    String quizId,
    List<String> questionIds,
  ) async {
    final response = await _dio.post(
      '$_base/$quizId/questions/reorder',
      data: {'question_ids': questionIds},
    );
    return CustomQuiz.fromJson(response.data as Map<String, dynamic>);
  }

  /// Starter questions for the author to edit. Saves nothing on its own.
  Future<QuizDraftBatch> aiDraft({
    required String prompt,
    int count = 5,
    String difficulty = 'medium',
  }) async {
    final response = await _dio.post(
      '$_base/ai-draft',
      data: {'prompt': prompt, 'count': count, 'difficulty': difficulty},
    );
    return QuizDraftBatch.fromJson(response.data as Map<String, dynamic>);
  }

  /// Start a solo run. Mode and difficulty are the player's choice, exactly as
  /// on any other topic.
  Future<StartedQuizRun> start(
    String quizId, {
    required String mode,
    String? difficulty,
    int? questionTimeLimitMs,
  }) async {
    final response = await _dio.post(
      '$_base/$quizId/start',
      data: {
        'mode': mode,
        'difficulty': ?difficulty,
        'question_time_limit_ms': ?questionTimeLimitMs,
      },
    );
    return StartedQuizRun.fromJson(response.data as Map<String, dynamic>);
  }

  /// Challenge one friend, or open a room anyone with the code can join.
  Future<MatchState> challenge(
    String quizId, {
    String? opponentUserId,
    bool isRoom = false,
    int? maxPlayers,
    int? questionCount,
  }) async {
    final response = await _dio.post(
      '$_base/$quizId/challenge',
      data: {
        'opponent_user_id': ?opponentUserId,
        'is_room': isRoom,
        'max_players': ?maxPlayers,
        'question_count': ?questionCount,
      },
    );
    return MatchState.fromJson(response.data as Map<String, dynamic>);
  }

  Future<QuizLeaderboard> fetchLeaderboard(String quizId) async {
    final response = await _dio.get('$_base/$quizId/leaderboard');
    return QuizLeaderboard.fromJson(response.data as Map<String, dynamic>);
  }

  Future<void> report(
    String quizId, {
    required String reason,
    String? details,
  }) => _dio.post(
    '$_base/$quizId/report',
    data: {'reason': reason, 'details': ?details},
  );
}

final customQuizRepositoryProvider = Provider<CustomQuizRepository>((ref) {
  return CustomQuizRepository(ref.watch(dioProvider));
});

/// The library, for the studio hub and the home-tab card.
final customQuizLibraryProvider = FutureProvider<CustomQuizLibrary>((ref) {
  return ref.watch(customQuizRepositoryProvider).fetchLibrary();
});

/// One quiz, refetched whenever the id changes.
///
/// The editor keeps its own local copy on top of this: every mutation returns
/// the whole quiz, so the screen renders that response directly rather than
/// invalidating and waiting for a second round trip on each keystroke-sized
/// action.
final customQuizProvider = FutureProvider.family<CustomQuiz, String>((
  ref,
  quizId,
) {
  return ref.watch(customQuizRepositoryProvider).fetchQuiz(quizId);
});

final quizLeaderboardProvider =
    FutureProvider.family<QuizLeaderboard, String>((ref, quizId) {
      return ref.watch(customQuizRepositoryProvider).fetchLeaderboard(quizId);
    });
