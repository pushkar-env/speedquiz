import 'package:equatable/equatable.dart';

class SharedResult extends Equatable {
  const SharedResult({
    required this.sessionId,
    required this.topicName,
    required this.mode,
    required this.difficulty,
    required this.finalScore,
    required this.accuracy,
    required this.bestStreak,
    required this.questionsAnswered,
    required this.deepLink,
  });

  final String sessionId;
  final String topicName;
  final String mode;
  final String difficulty;
  final int finalScore;
  final double accuracy;
  final int bestStreak;
  final int questionsAnswered;
  final String deepLink;

  factory SharedResult.fromJson(Map<String, dynamic> json) {
    return SharedResult(
      sessionId: json['session_id'] as String,
      topicName: json['topic_name'] as String? ?? 'QuizVerse',
      mode: json['mode'] as String? ?? 'casual',
      difficulty: json['difficulty'] as String? ?? 'medium',
      finalScore: json['final_score'] as int? ?? 0,
      accuracy: (json['accuracy'] as num?)?.toDouble() ?? 0,
      bestStreak: json['best_streak'] as int? ?? 0,
      questionsAnswered: json['questions_answered'] as int? ?? 0,
      deepLink: json['deep_link'] as String? ?? '',
    );
  }

  @override
  List<Object?> get props => [sessionId, finalScore];
}
