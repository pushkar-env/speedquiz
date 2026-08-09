import 'package:equatable/equatable.dart';

class QuizOption extends Equatable {
  const QuizOption({required this.index, required this.text});

  final int index;
  final String text;

  factory QuizOption.fromJson(Map<String, dynamic> json) {
    return QuizOption(
      index: json['index'] as int,
      text: json['text'] as String,
    );
  }

  @override
  List<Object?> get props => [index, text];
}

class PlayableQuestion extends Equatable {
  const PlayableQuestion({
    required this.quizQuestionId,
    required this.questionId,
    required this.sequenceIndex,
    required this.prompt,
    required this.options,
    required this.timeLimitMs,
    required this.servedAt,
  });

  final String quizQuestionId;
  final String questionId;
  final int sequenceIndex;
  final String prompt;
  final List<QuizOption> options;
  final int timeLimitMs;
  final DateTime servedAt;

  factory PlayableQuestion.fromJson(Map<String, dynamic> json) {
    return PlayableQuestion(
      quizQuestionId: json['quiz_question_id'] as String,
      questionId: json['question_id'] as String,
      sequenceIndex: json['sequence_index'] as int,
      prompt: json['prompt'] as String,
      options: (json['options'] as List<dynamic>)
          .map((e) => QuizOption.fromJson(e as Map<String, dynamic>))
          .toList(),
      timeLimitMs: json['time_limit_ms'] as int,
      servedAt: DateTime.parse(json['served_at'] as String),
    );
  }

  @override
  List<Object?> get props => [quizQuestionId, sequenceIndex];
}

class QuizSession extends Equatable {
  const QuizSession({
    required this.id,
    required this.topicId,
    required this.topicName,
    required this.mode,
    required this.difficulty,
    required this.status,
    required this.score,
    required this.streak,
    required this.bestStreak,
    required this.questionTimeLimitMs,
    required this.currentQuestionIndex,
    required this.correctCount,
    required this.incorrectCount,
    required this.questionNumber,
    this.lives,
    this.timeBudgetMs,
    this.timeRemainingMs,
    this.currentQuestion,
  });

  final String id;
  final String topicId;
  final String topicName;
  final String mode;
  final String difficulty;
  final String status;
  final int score;
  final int streak;
  final int bestStreak;
  final int? lives;
  final int? timeBudgetMs;
  final int? timeRemainingMs;
  final int questionTimeLimitMs;
  final int currentQuestionIndex;
  final int correctCount;
  final int incorrectCount;
  final int questionNumber;
  final PlayableQuestion? currentQuestion;

  factory QuizSession.fromJson(Map<String, dynamic> json) {
    return QuizSession(
      id: json['id'] as String,
      topicId: json['topic_id'] as String,
      topicName: json['topic_name'] as String,
      mode: json['mode'] as String,
      difficulty: json['difficulty'] as String,
      status: json['status'] as String,
      score: json['score'] as int,
      streak: json['streak'] as int,
      bestStreak: json['best_streak'] as int,
      lives: json['lives'] as int?,
      timeBudgetMs: json['time_budget_ms'] as int?,
      timeRemainingMs: json['time_remaining_ms'] as int?,
      questionTimeLimitMs: json['question_time_limit_ms'] as int,
      currentQuestionIndex: json['current_question_index'] as int,
      correctCount: json['correct_count'] as int,
      incorrectCount: json['incorrect_count'] as int,
      questionNumber: json['question_number'] as int,
      currentQuestion: json['current_question'] == null
          ? null
          : PlayableQuestion.fromJson(
              json['current_question'] as Map<String, dynamic>,
            ),
    );
  }

  QuizSession copyWith({
    int? score,
    int? streak,
    int? bestStreak,
    int? lives,
    int? timeRemainingMs,
    String? status,
    int? questionNumber,
    PlayableQuestion? currentQuestion,
    bool clearQuestion = false,
  }) {
    return QuizSession(
      id: id,
      topicId: topicId,
      topicName: topicName,
      mode: mode,
      difficulty: difficulty,
      status: status ?? this.status,
      score: score ?? this.score,
      streak: streak ?? this.streak,
      bestStreak: bestStreak ?? this.bestStreak,
      lives: lives ?? this.lives,
      timeBudgetMs: timeBudgetMs,
      timeRemainingMs: timeRemainingMs ?? this.timeRemainingMs,
      questionTimeLimitMs: questionTimeLimitMs,
      currentQuestionIndex: currentQuestionIndex,
      correctCount: correctCount,
      incorrectCount: incorrectCount,
      questionNumber: questionNumber ?? this.questionNumber,
      currentQuestion:
          clearQuestion ? null : (currentQuestion ?? this.currentQuestion),
    );
  }

  @override
  List<Object?> get props => [id, score, streak, questionNumber, status];
}

class AnswerFeedback extends Equatable {
  const AnswerFeedback({
    required this.isCorrect,
    required this.correctOptionIndex,
    required this.correctOptionText,
    required this.explanation,
    required this.basePoints,
    required this.speedBonus,
    required this.streakMultiplier,
    required this.pointsAwarded,
    required this.score,
    required this.streak,
    required this.bestStreak,
    required this.sessionStatus,
    required this.runEnded,
    this.selectedOptionIndex,
    this.lives,
    this.timeRemainingMs,
    this.nextQuestion,
  });

  final bool isCorrect;
  final int? selectedOptionIndex;
  final int correctOptionIndex;
  final String correctOptionText;
  final String explanation;
  final int basePoints;
  final int speedBonus;
  final double streakMultiplier;
  final int pointsAwarded;
  final int score;
  final int streak;
  final int bestStreak;
  final int? lives;
  final int? timeRemainingMs;
  final String sessionStatus;
  final bool runEnded;
  final PlayableQuestion? nextQuestion;

  factory AnswerFeedback.fromJson(Map<String, dynamic> json) {
    return AnswerFeedback(
      isCorrect: json['is_correct'] as bool,
      selectedOptionIndex: json['selected_option_index'] as int?,
      correctOptionIndex: json['correct_option_index'] as int,
      correctOptionText: json['correct_option_text'] as String,
      explanation: json['explanation'] as String,
      basePoints: json['base_points'] as int,
      speedBonus: json['speed_bonus'] as int,
      streakMultiplier: (json['streak_multiplier'] as num).toDouble(),
      pointsAwarded: json['points_awarded'] as int,
      score: json['score'] as int,
      streak: json['streak'] as int,
      bestStreak: json['best_streak'] as int,
      lives: json['lives'] as int?,
      timeRemainingMs: json['time_remaining_ms'] as int?,
      sessionStatus: json['session_status'] as String,
      runEnded: json['run_ended'] as bool,
      nextQuestion: json['next_question'] == null
          ? null
          : PlayableQuestion.fromJson(
              json['next_question'] as Map<String, dynamic>,
            ),
    );
  }

  @override
  List<Object?> get props => [isCorrect, score, runEnded];
}

class QuizResult extends Equatable {
  const QuizResult({
    required this.sessionId,
    required this.topicName,
    required this.mode,
    required this.difficulty,
    required this.finalScore,
    required this.accuracy,
    required this.bestStreak,
    required this.questionsAnswered,
    required this.correctCount,
    required this.incorrectCount,
    required this.averageAnswerMs,
    required this.xpEarned,
    required this.isPersonalBest,
    required this.previousBest,
    required this.shareText,
    this.newAchievements = const [],
    this.level,
    this.xp,
    this.coins,
    this.dailyStreak,
    this.currentStreak,
  });

  final String sessionId;
  final String topicName;
  final String mode;
  final String difficulty;
  final int finalScore;
  final double accuracy;
  final int bestStreak;
  final int questionsAnswered;
  final int correctCount;
  final int incorrectCount;
  final int averageAnswerMs;
  final int xpEarned;
  final bool isPersonalBest;
  final int previousBest;
  final String shareText;
  final List<AchievementUnlock> newAchievements;
  final int? level;
  final int? xp;
  final int? coins;
  final int? dailyStreak;
  final int? currentStreak;

  factory QuizResult.fromJson(Map<String, dynamic> json) {
    final unlocks = (json['new_achievements'] as List<dynamic>? ?? [])
        .map((e) => AchievementUnlock.fromJson(e as Map<String, dynamic>))
        .toList();
    return QuizResult(
      sessionId: json['session_id'] as String,
      topicName: json['topic_name'] as String,
      mode: json['mode'] as String,
      difficulty: json['difficulty'] as String,
      finalScore: json['final_score'] as int,
      accuracy: (json['accuracy'] as num).toDouble(),
      bestStreak: json['best_streak'] as int,
      questionsAnswered: json['questions_answered'] as int,
      correctCount: json['correct_count'] as int,
      incorrectCount: json['incorrect_count'] as int,
      averageAnswerMs: json['average_answer_ms'] as int,
      xpEarned: json['xp_earned'] as int,
      isPersonalBest: json['is_personal_best'] as bool,
      previousBest: json['previous_best'] as int,
      shareText: json['share_text'] as String? ?? '',
      newAchievements: unlocks,
      level: json['level'] as int?,
      xp: json['xp'] as int?,
      coins: json['coins'] as int?,
      dailyStreak: json['daily_streak'] as int?,
      currentStreak: json['current_streak'] as int?,
    );
  }

  @override
  List<Object?> get props => [sessionId, finalScore, newAchievements.length];
}

class AchievementUnlock extends Equatable {
  const AchievementUnlock({
    required this.id,
    required this.code,
    required this.name,
    required this.description,
    required this.icon,
    required this.category,
    required this.xpReward,
    required this.coinsReward,
  });

  final String id;
  final String code;
  final String name;
  final String description;
  final String icon;
  final String category;
  final int xpReward;
  final int coinsReward;

  factory AchievementUnlock.fromJson(Map<String, dynamic> json) {
    return AchievementUnlock(
      id: json['id'] as String,
      code: json['code'] as String,
      name: json['name'] as String,
      description: json['description'] as String,
      icon: json['icon'] as String? ?? 'trophy',
      category: json['category'] as String? ?? 'general',
      xpReward: json['xp_reward'] as int? ?? 0,
      coinsReward: json['coins_reward'] as int? ?? 0,
    );
  }

  @override
  List<Object?> get props => [id, code];
}
