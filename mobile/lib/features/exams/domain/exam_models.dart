import 'package:equatable/equatable.dart';

/// One piece of a question's content.
///
/// Question text is a list of blocks rather than a string because a real exam
/// question interleaves prose, mathematics and figures, and each needs a
/// different renderer. Text blocks carry LaTeX inline between `$` delimiters;
/// figure blocks carry a `ref` that resolves against the paper's assets.
sealed class ContentBlock extends Equatable {
  const ContentBlock();

  static ContentBlock fromJson(Map<String, dynamic> json) {
    return switch (json['t'] as String?) {
      'figure' => FigureBlock(ref: json['ref'] as String? ?? ''),
      _ => TextBlock(text: json['v'] as String? ?? ''),
    };
  }

  static List<ContentBlock> listFrom(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => ContentBlock.fromJson(e.cast<String, dynamic>()))
        .toList(growable: false);
  }
}

class TextBlock extends ContentBlock {
  const TextBlock({required this.text});

  final String text;

  @override
  List<Object?> get props => [text];
}

class FigureBlock extends ContentBlock {
  const FigureBlock({required this.ref});

  final String ref;

  @override
  List<Object?> get props => [ref];
}

/// A figure, in both themes.
///
/// Two baked variants rather than a runtime filter: a black-on-white circuit
/// diagram is illegible on a dark ground, and inverting at display time turns
/// a red vector arrow cyan.
class ExamAsset extends Equatable {
  const ExamAsset({
    required this.checksum,
    required this.width,
    required this.height,
    required this.lightUrl,
    required this.darkUrl,
    this.altText,
  });

  factory ExamAsset.fromJson(Map<String, dynamic> json) {
    final variants =
        (json['variants'] as Map?)?.cast<String, dynamic>() ?? const {};
    String urlFor(String name) {
      final entry = (variants[name] as Map?)?.cast<String, dynamic>();
      return entry?['url'] as String? ?? '';
    }

    final light = urlFor('light');
    final dark = urlFor('dark');
    return ExamAsset(
      checksum: json['checksum'] as String? ?? '',
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
      lightUrl: light,
      // Fall back to the light variant rather than showing nothing: a figure
      // that is hard to read still lets the question be answered.
      darkUrl: dark.isEmpty ? light : dark,
      altText: json['alt_text'] as String?,
    );
  }

  final String checksum;
  final int width;
  final int height;
  final String lightUrl;
  final String darkUrl;
  final String? altText;

  double get aspectRatio => (width > 0 && height > 0) ? width / height : 16 / 9;

  @override
  List<Object?> get props => [checksum, lightUrl, darkUrl];
}

enum ExamAnswerType {
  single,
  multi,
  numeric;

  static ExamAnswerType parse(String? raw) => switch (raw) {
    'multi' => ExamAnswerType.multi,
    'numeric' => ExamAnswerType.numeric,
    _ => ExamAnswerType.single,
  };

  bool get isNumeric => this == ExamAnswerType.numeric;
}

class ExamQuestion extends Equatable {
  const ExamQuestion({
    required this.id,
    required this.number,
    required this.answerType,
    required this.marks,
    required this.negativeMarks,
    required this.stem,
    required this.options,
    required this.optionText,
    required this.figures,
    this.sectionId,
    this.unit,
  });

  factory ExamQuestion.fromJson(Map<String, dynamic> json) {
    final rawOptions = (json['options'] as List?) ?? const [];
    return ExamQuestion(
      id: json['id'] as String,
      number: (json['number'] as num).toInt(),
      sectionId: json['section_id'] as String?,
      answerType: ExamAnswerType.parse(json['answer_type'] as String?),
      marks: (json['marks'] as num?)?.toDouble() ?? 0,
      negativeMarks: (json['negative_marks'] as num?)?.toDouble() ?? 0,
      stem: ContentBlock.listFrom(json['stem']),
      options: rawOptions.map(ContentBlock.listFrom).toList(growable: false),
      optionText: ((json['option_text'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(growable: false),
      figures: ((json['figures'] as Map?) ?? const {}).map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      ),
      unit: json['unit'] as String?,
    );
  }

  final String id;
  final int number;
  final String? sectionId;
  final ExamAnswerType answerType;
  final double marks;
  final double negativeMarks;
  final List<ContentBlock> stem;
  final List<List<ContentBlock>> options;
  final List<String> optionText;

  /// `ref` -> asset checksum, resolving figure blocks against the paper.
  final Map<String, String> figures;
  final String? unit;

  int get optionCount =>
      options.isNotEmpty ? options.length : optionText.length;

  @override
  List<Object?> get props => [id, number];
}

class ExamSection extends Equatable {
  const ExamSection({
    required this.id,
    required this.name,
    required this.subject,
    required this.position,
    required this.firstQuestion,
    required this.lastQuestion,
    required this.questionCount,
  });

  factory ExamSection.fromJson(Map<String, dynamic> json) => ExamSection(
    id: json['id'] as String,
    name: json['name'] as String,
    subject: json['subject'] as String? ?? '',
    position: (json['position'] as num?)?.toInt() ?? 0,
    firstQuestion: (json['first_question'] as num?)?.toInt() ?? 0,
    lastQuestion: (json['last_question'] as num?)?.toInt() ?? 0,
    questionCount: (json['question_count'] as num?)?.toInt() ?? 0,
  );

  final String id;
  final String name;
  final String subject;
  final int position;
  final int firstQuestion;
  final int lastQuestion;
  final int questionCount;

  @override
  List<Object?> get props => [id];
}

class ExamSummary extends Equatable {
  const ExamSummary({
    required this.id,
    required this.slug,
    required this.name,
    required this.paperCount,
    this.authority,
  });

  factory ExamSummary.fromJson(Map<String, dynamic> json) => ExamSummary(
    id: json['id'] as String,
    slug: json['slug'] as String,
    name: json['name'] as String,
    paperCount: (json['paper_count'] as num?)?.toInt() ?? 0,
    authority: json['authority'] as String?,
  );

  final String id;
  final String slug;
  final String name;
  final int paperCount;
  final String? authority;

  @override
  List<Object?> get props => [id];
}

class ExamPaper extends Equatable {
  const ExamPaper({
    required this.id,
    required this.key,
    required this.title,
    required this.year,
    required this.durationMinutes,
    required this.totalMarks,
    required this.questionCount,
    required this.isFree,
    required this.isLocked,
    this.session = '',
    this.shift = 0,
    this.attemptCount = 0,
    this.bestScore,
    this.lastAttemptId,
    this.lastAttemptStatus,
  });

  factory ExamPaper.fromJson(Map<String, dynamic> json) => ExamPaper(
    id: json['id'] as String,
    key: json['key'] as String,
    title: json['title'] as String,
    year: (json['year'] as num?)?.toInt() ?? 0,
    session: json['session'] as String? ?? '',
    shift: (json['shift'] as num?)?.toInt() ?? 0,
    durationMinutes: (json['duration_minutes'] as num?)?.toInt() ?? 180,
    totalMarks: (json['total_marks'] as num?)?.toDouble() ?? 0,
    questionCount: (json['question_count'] as num?)?.toInt() ?? 0,
    isFree: json['is_free'] as bool? ?? false,
    isLocked: json['is_locked'] as bool? ?? false,
    attemptCount: (json['attempt_count'] as num?)?.toInt() ?? 0,
    bestScore: (json['best_score'] as num?)?.toDouble(),
    lastAttemptId: json['last_attempt_id'] as String?,
    lastAttemptStatus: json['last_attempt_status'] as String?,
  );

  final String id;
  final String key;
  final String title;
  final int year;
  final String session;
  final int shift;
  final int durationMinutes;
  final double totalMarks;
  final int questionCount;
  final bool isFree;
  final bool isLocked;
  final int attemptCount;
  final double? bestScore;
  final String? lastAttemptId;
  final String? lastAttemptStatus;

  bool get hasLiveAttempt => lastAttemptStatus == 'in_progress';

  String get subtitle {
    final bits = <String>[
      if (session.isNotEmpty)
        '${session[0].toUpperCase()}${session.substring(1)}',
      if (shift > 0) 'Shift $shift',
    ];
    return bits.join(' · ');
  }

  @override
  List<Object?> get props => [id, lastAttemptId, bestScore];
}

/// A whole paper, ready to run offline.
class PaperManifest extends Equatable {
  const PaperManifest({
    required this.paper,
    required this.exam,
    required this.sections,
    required this.questions,
    required this.assets,
    required this.etag,
    this.totalAssetBytes = 0,
  });

  factory PaperManifest.fromJson(Map<String, dynamic> json) {
    final assets = <String, ExamAsset>{};
    for (final raw in (json['assets'] as List?) ?? const []) {
      final asset = ExamAsset.fromJson((raw as Map).cast<String, dynamic>());
      assets[asset.checksum] = asset;
    }
    return PaperManifest(
      paper: ExamPaper.fromJson((json['paper'] as Map).cast<String, dynamic>()),
      exam: ExamSummary.fromJson((json['exam'] as Map).cast<String, dynamic>()),
      sections: ((json['sections'] as List?) ?? const [])
          .map((e) => ExamSection.fromJson((e as Map).cast<String, dynamic>()))
          .toList(growable: false),
      questions: ((json['questions'] as List?) ?? const [])
          .map((e) => ExamQuestion.fromJson((e as Map).cast<String, dynamic>()))
          .toList(growable: false),
      assets: assets,
      totalAssetBytes: (json['total_asset_bytes'] as num?)?.toInt() ?? 0,
      etag: json['etag'] as String? ?? '',
    );
  }

  final ExamPaper paper;
  final ExamSummary exam;
  final List<ExamSection> sections;
  final List<ExamQuestion> questions;
  final Map<String, ExamAsset> assets;
  final int totalAssetBytes;
  final String etag;

  ExamSection? sectionOf(ExamQuestion question) {
    for (final section in sections) {
      if (section.id == question.sectionId) return section;
    }
    return null;
  }

  /// Every image URL the paper needs, for the pre-download before the clock
  /// starts. Both variants, because the candidate can switch theme mid-test.
  List<String> allAssetUrls() => [
    for (final asset in assets.values) ...[
      if (asset.lightUrl.isNotEmpty) asset.lightUrl,
      if (asset.darkUrl.isNotEmpty && asset.darkUrl != asset.lightUrl)
        asset.darkUrl,
    ],
  ];

  @override
  List<Object?> get props => [paper.id, etag];
}

/// The five states of the official CBT answer palette.
///
/// Mirrored exactly, colours included: candidates have drilled on this palette
/// for two years, and inventing a different one is a usability cost with no
/// upside.
enum ResponseState {
  notVisited('not_visited'),
  notAnswered('not_answered'),
  answered('answered'),
  marked('marked'),
  answeredAndMarked('answered_and_marked');

  const ResponseState(this.wire);

  final String wire;

  static ResponseState parse(String? raw) => ResponseState.values.firstWhere(
    (e) => e.wire == raw,
    orElse: () => ResponseState.notVisited,
  );

  bool get isAnswered =>
      this == ResponseState.answered || this == ResponseState.answeredAndMarked;

  bool get isMarked =>
      this == ResponseState.marked || this == ResponseState.answeredAndMarked;
}

/// The candidate's state on one question, as held on the device.
class QuestionResponse extends Equatable {
  const QuestionResponse({
    required this.examQuestionId,
    this.state = ResponseState.notVisited,
    this.selected = const [],
    this.numericValue,
    this.numericRaw,
    this.timeSpentMs = 0,
    this.visitCount = 0,
    this.clientRevision = 0,
  });

  factory QuestionResponse.fromJson(Map<String, dynamic> json) =>
      QuestionResponse(
        examQuestionId: json['exam_question_id'] as String,
        state: ResponseState.parse(json['state'] as String?),
        selected: ((json['selected'] as List?) ?? const [])
            .map((e) => (e as num).toInt())
            .toList(growable: false),
        numericValue: (json['numeric_value'] as num?)?.toDouble(),
        numericRaw: json['numeric_raw'] as String?,
        timeSpentMs: (json['time_spent_ms'] as num?)?.toInt() ?? 0,
        visitCount: (json['visit_count'] as num?)?.toInt() ?? 0,
        clientRevision: (json['client_revision'] as num?)?.toInt() ?? 0,
      );

  final String examQuestionId;
  final ResponseState state;
  final List<int> selected;
  final double? numericValue;
  final String? numericRaw;
  final int timeSpentMs;
  final int visitCount;
  final int clientRevision;

  bool get hasAnswer => selected.isNotEmpty || numericValue != null;

  Map<String, dynamic> toJson() => {
    'exam_question_id': examQuestionId,
    'state': state.wire,
    'selected': selected,
    'numeric_value': numericValue,
    'numeric_raw': numericRaw,
    'time_spent_ms': timeSpentMs,
    'visit_count': visitCount,
    'client_revision': clientRevision,
  };

  QuestionResponse copyWith({
    ResponseState? state,
    List<int>? selected,
    double? numericValue,
    String? numericRaw,
    int? timeSpentMs,
    int? visitCount,
    int? clientRevision,
    bool clearNumeric = false,
  }) => QuestionResponse(
    examQuestionId: examQuestionId,
    state: state ?? this.state,
    selected: selected ?? this.selected,
    numericValue: clearNumeric ? null : (numericValue ?? this.numericValue),
    numericRaw: clearNumeric ? null : (numericRaw ?? this.numericRaw),
    timeSpentMs: timeSpentMs ?? this.timeSpentMs,
    visitCount: visitCount ?? this.visitCount,
    clientRevision: clientRevision ?? this.clientRevision,
  );

  @override
  List<Object?> get props => [
    examQuestionId,
    state,
    selected,
    numericValue,
    timeSpentMs,
    clientRevision,
  ];
}

class MockAttempt extends Equatable {
  const MockAttempt({
    required this.id,
    required this.paperId,
    required this.mode,
    required this.status,
    required this.startedAt,
    required this.serverDeadlineAt,
    required this.remainingMs,
    required this.serverNow,
    required this.responses,
    this.submittedAt,
  });

  factory MockAttempt.fromJson(Map<String, dynamic> json) => MockAttempt(
    id: json['id'] as String,
    paperId: json['paper_id'] as String,
    mode: json['mode'] as String? ?? 'full',
    status: json['status'] as String? ?? 'in_progress',
    startedAt: DateTime.parse(json['started_at'] as String),
    serverDeadlineAt: DateTime.parse(json['server_deadline_at'] as String),
    remainingMs: (json['remaining_ms'] as num?)?.toInt() ?? 0,
    serverNow: DateTime.parse(json['server_now'] as String),
    submittedAt: json['submitted_at'] == null
        ? null
        : DateTime.parse(json['submitted_at'] as String),
    responses: ((json['responses'] as List?) ?? const [])
        .map(
          (e) => QuestionResponse.fromJson((e as Map).cast<String, dynamic>()),
        )
        .toList(growable: false),
  );

  final String id;
  final String paperId;
  final String mode;
  final String status;
  final DateTime startedAt;
  final DateTime serverDeadlineAt;
  final int remainingMs;
  final DateTime serverNow;
  final DateTime? submittedAt;
  final List<QuestionResponse> responses;

  bool get isLive => status == 'in_progress';

  @override
  List<Object?> get props => [id, status, remainingMs];
}

class QuestionResult extends Equatable {
  const QuestionResult({
    required this.examQuestionId,
    required this.number,
    required this.marksAwarded,
    required this.counted,
    required this.timeSpentMs,
    required this.selected,
    this.isCorrect,
    this.sectionId,
    this.correctOptionIndex,
    this.correctValue,
    this.numericValue,
    this.solution = '',
    this.chapter,
  });

  factory QuestionResult.fromJson(Map<String, dynamic> json) => QuestionResult(
    examQuestionId: json['exam_question_id'] as String,
    number: (json['number'] as num).toInt(),
    sectionId: json['section_id'] as String?,
    isCorrect: json['is_correct'] as bool?,
    marksAwarded: (json['marks_awarded'] as num?)?.toDouble() ?? 0,
    counted: json['counted'] as bool? ?? true,
    timeSpentMs: (json['time_spent_ms'] as num?)?.toInt() ?? 0,
    correctOptionIndex: (json['correct_option_index'] as num?)?.toInt(),
    correctValue: (json['correct_value'] as num?)?.toDouble(),
    selected: ((json['selected'] as List?) ?? const [])
        .map((e) => (e as num).toInt())
        .toList(growable: false),
    numericValue: (json['numeric_value'] as num?)?.toDouble(),
    solution: json['solution'] as String? ?? '',
    chapter: json['chapter'] as String?,
  );

  final String examQuestionId;
  final int number;
  final String? sectionId;
  final bool? isCorrect;
  final double marksAwarded;
  final bool counted;
  final int timeSpentMs;
  final int? correctOptionIndex;
  final double? correctValue;
  final List<int> selected;
  final double? numericValue;
  final String solution;
  final String? chapter;

  bool get attempted => isCorrect != null;

  @override
  List<Object?> get props => [examQuestionId, isCorrect, marksAwarded];
}

class ChapterBreakdown extends Equatable {
  const ChapterBreakdown({
    required this.name,
    required this.correct,
    required this.total,
    required this.marks,
  });

  final String name;
  final int correct;
  final int total;
  final double marks;

  double get accuracy => total == 0 ? 0 : correct / total;

  @override
  List<Object?> get props => [name, correct, total, marks];
}

class AttemptResult extends Equatable {
  const AttemptResult({
    required this.attempt,
    required this.score,
    required this.maxScore,
    required this.correct,
    required this.incorrect,
    required this.unattempted,
    required this.questions,
    required this.sections,
    required this.chapters,
    this.percentile,
    this.rank,
    this.totalAttempts = 0,
  });

  factory AttemptResult.fromJson(Map<String, dynamic> json) {
    final chapters = <ChapterBreakdown>[];
    ((json['chapters'] as Map?) ?? const {}).forEach((key, value) {
      final entry = (value as Map).cast<String, dynamic>();
      chapters.add(
        ChapterBreakdown(
          name: key.toString(),
          correct: (entry['correct'] as num?)?.toInt() ?? 0,
          total: (entry['total'] as num?)?.toInt() ?? 0,
          marks: (entry['marks'] as num?)?.toDouble() ?? 0,
        ),
      );
    });
    chapters.sort((a, b) => a.accuracy.compareTo(b.accuracy));

    return AttemptResult(
      attempt: MockAttempt.fromJson(
        (json['attempt'] as Map).cast<String, dynamic>(),
      ),
      score: (json['score'] as num?)?.toDouble() ?? 0,
      maxScore: (json['max_score'] as num?)?.toDouble() ?? 0,
      correct: (json['correct'] as num?)?.toInt() ?? 0,
      incorrect: (json['incorrect'] as num?)?.toInt() ?? 0,
      unattempted: (json['unattempted'] as num?)?.toInt() ?? 0,
      percentile: (json['percentile'] as num?)?.toDouble(),
      rank: (json['rank'] as num?)?.toInt(),
      totalAttempts: (json['total_attempts'] as num?)?.toInt() ?? 0,
      sections: ((json['sections'] as Map?) ?? const {})
          .cast<String, dynamic>(),
      questions: ((json['questions'] as List?) ?? const [])
          .map(
            (e) => QuestionResult.fromJson((e as Map).cast<String, dynamic>()),
          )
          .toList(growable: false),
      chapters: chapters,
    );
  }

  final MockAttempt attempt;
  final double score;
  final double maxScore;
  final int correct;
  final int incorrect;
  final int unattempted;
  final double? percentile;
  final int? rank;
  final int totalAttempts;
  final Map<String, dynamic> sections;
  final List<QuestionResult> questions;

  /// Weakest first — this list is the input to "practise this chapter".
  final List<ChapterBreakdown> chapters;

  @override
  List<Object?> get props => [attempt.id, score];
}
