import 'package:equatable/equatable.dart';
import 'package:speedquiz/features/quiz/domain/quiz_models.dart';

/// Who can open a quiz.
///
/// Mirrors `CustomQuizVisibility` on the server. Parsed leniently so a build
/// that predates a new tier shows the safest thing it knows rather than
/// throwing on a string it has never seen.
enum QuizVisibility {
  private('private'),
  friends('friends'),
  link('link');

  const QuizVisibility(this.wire);

  final String wire;

  static QuizVisibility parse(String? raw) => values.firstWhere(
    (v) => v.wire == raw,
    orElse: () => QuizVisibility.private,
  );
}

enum QuizStatus {
  draft('draft'),
  published('published'),
  archived('archived'),

  /// Pulled by moderation. Only the author sees it, and only to read why.
  hidden('hidden');

  const QuizStatus(this.wire);

  final String wire;

  static QuizStatus parse(String? raw) => values.firstWhere(
    (v) => v.wire == raw,
    orElse: () => QuizStatus.draft,
  );

  bool get isLive => this == QuizStatus.published;
}

/// One question, as its **author** sees it — answer key included.
///
/// Never populated for a player: the server returns an empty question list to
/// anyone who is not the owner, because this class is the answer sheet.
class CustomQuizQuestion extends Equatable {
  const CustomQuizQuestion({
    required this.id,
    required this.position,
    required this.prompt,
    required this.options,
    required this.correctOptionIndex,
    required this.difficulty,
    this.explanation,
    this.aiDrafted = false,
    this.timesServed = 0,
  });

  final String id;
  final int position;
  final String prompt;
  final List<String> options;
  final int correctOptionIndex;
  final String? explanation;
  final String difficulty;

  /// Came back from the AI drafter. Cosmetic — a badge in the editor.
  final bool aiDrafted;

  /// How many times it has been dealt. Non-zero means deleting it retires the
  /// row rather than removing it, so somebody's answer history stays intact.
  final int timesServed;

  String get correctOption =>
      correctOptionIndex < options.length ? options[correctOptionIndex] : '';

  factory CustomQuizQuestion.fromJson(Map<String, dynamic> json) {
    return CustomQuizQuestion(
      id: json['id'] as String,
      position: json['position'] as int? ?? 0,
      prompt: json['prompt'] as String? ?? '',
      options: (json['options'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(growable: false),
      correctOptionIndex: json['correct_option_index'] as int? ?? 0,
      explanation: json['explanation'] as String?,
      difficulty: json['difficulty'] as String? ?? 'medium',
      aiDrafted: json['ai_drafted'] as bool? ?? false,
      timesServed: json['times_served'] as int? ?? 0,
    );
  }

  /// The shape `POST/PUT .../questions` expects.
  Map<String, dynamic> toJson() => {
    'prompt': prompt,
    'options': options,
    'correct_option_index': correctOptionIndex,
    if (explanation != null && explanation!.trim().isNotEmpty)
      'explanation': explanation!.trim(),
    'difficulty': difficulty,
  };

  CustomQuizQuestion copyWith({
    String? prompt,
    List<String>? options,
    int? correctOptionIndex,
    String? explanation,
    String? difficulty,
  }) {
    return CustomQuizQuestion(
      id: id,
      position: position,
      prompt: prompt ?? this.prompt,
      options: options ?? this.options,
      correctOptionIndex: correctOptionIndex ?? this.correctOptionIndex,
      explanation: explanation ?? this.explanation,
      difficulty: difficulty ?? this.difficulty,
      aiDrafted: aiDrafted,
      timesServed: timesServed,
    );
  }

  /// A blank question for the editor to fill in. Not a server id — the sheet
  /// distinguishes "new" from "existing" on [id] being empty.
  static CustomQuizQuestion blank() => const CustomQuizQuestion(
    id: '',
    position: 0,
    prompt: '',
    options: ['', '', '', ''],
    correctOptionIndex: 0,
    difficulty: 'medium',
  );

  bool get isNew => id.isEmpty;

  @override
  List<Object?> get props => [id, prompt, options, correctOptionIndex, difficulty];
}

class QuizAuthor extends Equatable {
  const QuizAuthor({
    required this.userId,
    required this.username,
    this.displayName,
    this.avatarId = 'avatar_01',
    this.isPremium = false,
  });

  final String userId;
  final String username;
  final String? displayName;
  final String avatarId;
  final bool isPremium;

  String get name => (displayName?.trim().isNotEmpty ?? false)
      ? displayName!.trim()
      : username;

  factory QuizAuthor.fromJson(Map<String, dynamic> json) {
    return QuizAuthor(
      userId: json['user_id'] as String,
      username: json['username'] as String? ?? 'player',
      displayName: json['display_name'] as String?,
      avatarId: json['avatar_id'] as String? ?? 'avatar_01',
      isPremium: json['is_premium'] as bool? ?? false,
    );
  }

  @override
  List<Object?> get props => [userId];
}

class CustomQuiz extends Equatable {
  const CustomQuiz({
    required this.id,
    required this.topicId,
    required this.title,
    required this.icon,
    required this.language,
    required this.visibility,
    required this.status,
    required this.questionCount,
    required this.defaultMode,
    required this.defaultDifficulty,
    required this.playCount,
    required this.playerCount,
    required this.topScore,
    required this.author,
    required this.isOwner,
    required this.createdAt,
    required this.updatedAt,
    this.description,
    this.code,
    this.myBestScore,
    this.publishBlockers = const [],
    this.maxQuestions = 20,
    this.minQuestions = 3,
    this.moderationNote,
    this.publishedAt,
    this.questions = const [],
  });

  final String id;

  /// The hidden topic the questions live under. This is what every gameplay
  /// endpoint speaks — quiz sessions, matches and results all key off it.
  final String topicId;

  final String title;
  final String? description;
  final String icon;
  final String language;
  final QuizVisibility visibility;
  final QuizStatus status;

  /// The share code. Present once published; it is the key to the quiz, so it
  /// only ever reaches someone who already has access.
  final String? code;

  final int questionCount;
  final String defaultMode;
  final String defaultDifficulty;
  final int playCount;
  final int playerCount;
  final int topScore;
  final QuizAuthor author;
  final bool isOwner;
  final int? myBestScore;

  /// Why this cannot be published yet, as codes the client localizes:
  /// `too_few_questions`, `quiz_limit_reached`, `question_limit_exceeded`.
  final List<String> publishBlockers;

  /// How many questions *this viewer's* plan lets this quiz hold. Carried on
  /// the quiz so the editor never has to reach into the library provider —
  /// which may not have loaded when the editor is opened directly.
  final int maxQuestions;

  /// The publish floor, from the server, so the editor states the real number.
  final int minQuestions;

  final String? moderationNote;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? publishedAt;

  /// Only ever non-empty for the author.
  final List<CustomQuizQuestion> questions;

  bool get canPublish => publishBlockers.isEmpty && !status.isLive;
  bool get isPlayable => status.isLive && questionCount > 0;
  bool get isHidden => status == QuizStatus.hidden;

  /// Whether deleting is allowed, or the author must archive instead. Mirrors
  /// the server rule: a played quiz cannot be erased without rewriting other
  /// players' history.
  bool get canHardDelete => playCount == 0;

  factory CustomQuiz.fromJson(Map<String, dynamic> json) {
    return CustomQuiz(
      id: json['id'] as String,
      topicId: json['topic_id'] as String,
      title: json['title'] as String? ?? '',
      description: json['description'] as String?,
      icon: json['icon'] as String? ?? '🧠',
      language: json['language'] as String? ?? 'en',
      visibility: QuizVisibility.parse(json['visibility'] as String?),
      status: QuizStatus.parse(json['status'] as String?),
      code: json['code'] as String?,
      questionCount: json['question_count'] as int? ?? 0,
      defaultMode: json['default_mode'] as String? ?? 'casual',
      defaultDifficulty: json['default_difficulty'] as String? ?? 'medium',
      playCount: json['play_count'] as int? ?? 0,
      playerCount: json['player_count'] as int? ?? 0,
      topScore: json['top_score'] as int? ?? 0,
      author: QuizAuthor.fromJson(
        (json['author'] as Map<String, dynamic>?) ?? const {'user_id': ''},
      ),
      isOwner: json['is_owner'] as bool? ?? false,
      myBestScore: json['my_best_score'] as int?,
      publishBlockers: (json['publish_blockers'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(growable: false),
      maxQuestions: json['max_questions'] as int? ?? 20,
      minQuestions: json['min_questions'] as int? ?? 3,
      moderationNote: json['moderation_note'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      publishedAt: json['published_at'] == null
          ? null
          : DateTime.parse(json['published_at'] as String),
      questions: (json['questions'] as List<dynamic>? ?? const [])
          .map((e) => CustomQuizQuestion.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
    );
  }

  @override
  List<Object?> get props => [id, updatedAt, status, questionCount, questions];
}

/// The library: what you wrote, and what has been shared with you.
class CustomQuizLibrary extends Equatable {
  const CustomQuizLibrary({
    required this.mine,
    required this.shared,
    required this.maxQuestions,
    this.remainingSlots,
  });

  final List<CustomQuiz> mine;
  final List<CustomQuiz> shared;

  /// Published quizzes this account may still create. `null` is unlimited.
  final int? remainingSlots;

  final int maxQuestions;

  bool get isEmpty => mine.isEmpty && shared.isEmpty;
  bool get atLimit => remainingSlots != null && remainingSlots! <= 0;

  factory CustomQuizLibrary.fromJson(Map<String, dynamic> json) {
    List<CustomQuiz> parse(String key) =>
        (json[key] as List<dynamic>? ?? const [])
            .map((e) => CustomQuiz.fromJson(e as Map<String, dynamic>))
            .toList(growable: false);
    return CustomQuizLibrary(
      mine: parse('mine'),
      shared: parse('shared'),
      remainingSlots: json['remaining_slots'] as int?,
      maxQuestions: json['max_questions'] as int? ?? 50,
    );
  }

  @override
  List<Object?> get props => [mine, shared, remainingSlots];
}

class QuizLeaderboardEntry extends Equatable {
  const QuizLeaderboardEntry({
    required this.rank,
    required this.userId,
    required this.username,
    required this.bestScore,
    required this.accuracy,
    required this.playedAt,
    this.displayName,
    this.avatarId = 'avatar_01',
    this.isPremium = false,
    this.isMe = false,
  });

  final int rank;
  final String userId;
  final String username;
  final String? displayName;
  final String avatarId;
  final bool isPremium;
  final int bestScore;
  final double accuracy;
  final DateTime playedAt;
  final bool isMe;

  String get name => (displayName?.trim().isNotEmpty ?? false)
      ? displayName!.trim()
      : username;

  factory QuizLeaderboardEntry.fromJson(Map<String, dynamic> json) {
    return QuizLeaderboardEntry(
      rank: json['rank'] as int? ?? 0,
      userId: json['user_id'] as String,
      username: json['username'] as String? ?? 'player',
      displayName: json['display_name'] as String?,
      avatarId: json['avatar_id'] as String? ?? 'avatar_01',
      isPremium: json['is_premium'] as bool? ?? false,
      bestScore: json['best_score'] as int? ?? 0,
      accuracy: (json['accuracy'] as num?)?.toDouble() ?? 0,
      playedAt: DateTime.parse(json['played_at'] as String),
      isMe: json['is_me'] as bool? ?? false,
    );
  }

  @override
  List<Object?> get props => [userId, rank, bestScore];
}

class QuizLeaderboard extends Equatable {
  const QuizLeaderboard({
    required this.quizId,
    required this.entries,
    required this.totalPlayers,
    this.me,
  });

  final String quizId;
  final List<QuizLeaderboardEntry> entries;

  /// The viewer's own row, even when it falls outside the returned page.
  final QuizLeaderboardEntry? me;

  final int totalPlayers;

  /// True when the viewer's row is already in [entries], so the pinned footer
  /// would be a duplicate.
  bool get meIsListed => entries.any((e) => e.isMe);

  factory QuizLeaderboard.fromJson(Map<String, dynamic> json) {
    return QuizLeaderboard(
      quizId: json['quiz_id'] as String,
      entries: (json['entries'] as List<dynamic>? ?? const [])
          .map((e) => QuizLeaderboardEntry.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
      me: json['me'] == null
          ? null
          : QuizLeaderboardEntry.fromJson(json['me'] as Map<String, dynamic>),
      totalPlayers: json['total_players'] as int? ?? 0,
    );
  }

  @override
  List<Object?> get props => [quizId, entries, me];
}

/// AI drafts waiting for the author to accept or edit. Nothing is saved until
/// they do.
class QuizDraftBatch extends Equatable {
  const QuizDraftBatch({required this.questions, this.remainingToday});

  final List<CustomQuizQuestion> questions;

  /// Drafting runs left today. `null` is unlimited (Premium).
  final int? remainingToday;

  factory QuizDraftBatch.fromJson(Map<String, dynamic> json) {
    final raw = json['questions'] as List<dynamic>? ?? const [];
    return QuizDraftBatch(
      questions: [
        for (var i = 0; i < raw.length; i++)
          CustomQuizQuestion(
            // Drafts have no server id yet — they are proposals, and the
            // editor keys "new" off exactly that.
            id: '',
            position: i,
            prompt: (raw[i] as Map<String, dynamic>)['prompt'] as String? ?? '',
            options:
                ((raw[i] as Map<String, dynamic>)['options'] as List<dynamic>? ??
                        const [])
                    .map((e) => e.toString())
                    .toList(growable: false),
            correctOptionIndex:
                (raw[i] as Map<String, dynamic>)['correct_option_index'] as int? ??
                0,
            explanation:
                (raw[i] as Map<String, dynamic>)['explanation'] as String?,
            difficulty:
                (raw[i] as Map<String, dynamic>)['difficulty'] as String? ??
                'medium',
            aiDrafted: true,
          ),
      ],
      remainingToday: json['remaining_today'] as int?,
    );
  }

  @override
  List<Object?> get props => [questions, remainingToday];
}

/// What `POST /custom-quizzes/{id}/start` returns: the quiz, and a live run.
class StartedQuizRun extends Equatable {
  const StartedQuizRun({required this.quizId, required this.session});

  final String quizId;
  final QuizSession session;

  factory StartedQuizRun.fromJson(Map<String, dynamic> json) {
    return StartedQuizRun(
      quizId: json['quiz_id'] as String,
      session: QuizSession.fromJson(json['session'] as Map<String, dynamic>),
    );
  }

  @override
  List<Object?> get props => [quizId, session.id];
}
