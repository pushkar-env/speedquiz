import 'package:equatable/equatable.dart';

class DailyChallengeInfo extends Equatable {
  const DailyChallengeInfo({
    required this.id,
    required this.challengeDate,
    required this.title,
    required this.topicId,
    required this.topicName,
    required this.difficulty,
    required this.questionCount,
    required this.status,
    this.topicIcon = '📅',
    this.bestScore,
    this.sessionId,
  });

  final String id;
  final String challengeDate;
  final String title;
  final String topicId;
  final String topicName;
  final String topicIcon;
  final String difficulty;
  final int questionCount;
  final String status; // available | in_progress | completed
  final int? bestScore;
  final String? sessionId;

  bool get isCompleted => status == 'completed';
  bool get isInProgress => status == 'in_progress';

  factory DailyChallengeInfo.fromJson(Map<String, dynamic> json) {
    return DailyChallengeInfo(
      id: json['id'] as String,
      challengeDate: json['challenge_date'] as String,
      title: json['title'] as String,
      topicId: json['topic_id'] as String,
      topicName: json['topic_name'] as String,
      topicIcon: json['topic_icon'] as String? ?? '📅',
      difficulty: json['difficulty'] as String,
      questionCount: json['question_count'] as int? ?? 0,
      status: json['status'] as String? ?? 'available',
      bestScore: json['best_score'] as int?,
      sessionId: json['session_id'] as String?,
    );
  }

  @override
  List<Object?> get props => [id, status, bestScore, sessionId];
}
