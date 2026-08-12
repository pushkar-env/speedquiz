import 'package:equatable/equatable.dart';

/// Lifetime play statistics from `GET /api/v1/users/me`.
class ProfileStats extends Equatable {
  const ProfileStats({
    required this.totalQuizzes,
    required this.totalQuestions,
    required this.totalCorrect,
    required this.totalIncorrect,
    required this.accuracy,
    required this.bestScore,
    required this.bestStreak,
    required this.averageAnswerMs,
    this.topicMastery = const {},
    this.skillRatings = const {},
  });

  final int totalQuizzes;
  final int totalQuestions;
  final int totalCorrect;
  final int totalIncorrect;
  final double accuracy;
  final int bestScore;
  final int bestStreak;
  final int averageAnswerMs;
  final Map<String, dynamic> topicMastery;
  final Map<String, dynamic> skillRatings;

  static const empty = ProfileStats(
    totalQuizzes: 0,
    totalQuestions: 0,
    totalCorrect: 0,
    totalIncorrect: 0,
    accuracy: 0,
    bestScore: 0,
    bestStreak: 0,
    averageAnswerMs: 0,
  );

  factory ProfileStats.fromJson(Map<String, dynamic> json) {
    return ProfileStats(
      totalQuizzes: json['total_quizzes'] as int? ?? 0,
      totalQuestions: json['total_questions'] as int? ?? 0,
      totalCorrect: json['total_correct'] as int? ?? 0,
      totalIncorrect: json['total_incorrect'] as int? ?? 0,
      accuracy: (json['accuracy'] as num?)?.toDouble() ?? 0,
      bestScore: json['best_score'] as int? ?? 0,
      bestStreak: json['best_streak'] as int? ?? 0,
      averageAnswerMs: json['average_answer_ms'] as int? ?? 0,
      topicMastery: Map<String, dynamic>.from(
        json['topic_mastery'] as Map? ?? const {},
      ),
      skillRatings: Map<String, dynamic>.from(
        json['skill_ratings'] as Map? ?? const {},
      ),
    );
  }

  @override
  List<Object?> get props => [
        totalQuizzes,
        totalQuestions,
        totalCorrect,
        accuracy,
        bestScore,
        bestStreak,
      ];
}

class UserProfile extends Equatable {
  const UserProfile({
    required this.userId,
    required this.username,
    required this.avatarId,
    required this.level,
    required this.xp,
    required this.coins,
    required this.currentStreak,
    required this.bestStreak,
    required this.dailyStreak,
    required this.isPremium,
    required this.statistics,
    this.displayName,
    this.favoriteTopicIds = const [],
    this.appLanguage,
    this.quizLanguage,
  });

  final String userId;
  final String username;
  final String? displayName;
  final String avatarId;
  final int level;
  final int xp;
  final int coins;
  final int currentStreak;
  final int bestStreak;
  final int dailyStreak;
  final bool isPremium;
  final List<String> favoriteTopicIds;
  final ProfileStats statistics;

  /// Account-level language preferences, mirrored from the device so a
  /// reinstall opens in the right language. Null on a server that predates
  /// them — the device's own stored choice is the primary source.
  final String? appLanguage;
  final String? quizLanguage;

  String get name => displayName?.trim().isNotEmpty == true
      ? displayName!.trim()
      : username;

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      userId: json['user_id'] as String,
      username: json['username'] as String,
      displayName: json['display_name'] as String?,
      avatarId: json['avatar_id'] as String? ?? 'avatar_01',
      level: json['level'] as int? ?? 1,
      xp: json['xp'] as int? ?? 0,
      coins: json['coins'] as int? ?? 0,
      currentStreak: json['current_streak'] as int? ?? 0,
      bestStreak: json['best_streak'] as int? ?? 0,
      dailyStreak: json['daily_streak'] as int? ?? 0,
      isPremium: json['is_premium'] as bool? ?? false,
      appLanguage: json['app_language'] as String?,
      quizLanguage: json['quiz_language'] as String?,
      favoriteTopicIds: (json['favorite_topic_ids'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      statistics: json['statistics'] is Map<String, dynamic>
          ? ProfileStats.fromJson(json['statistics'] as Map<String, dynamic>)
          : ProfileStats.empty,
    );
  }

  @override
  List<Object?> get props => [
        userId,
        displayName,
        avatarId,
        level,
        xp,
        coins,
        statistics,
      ];
}
