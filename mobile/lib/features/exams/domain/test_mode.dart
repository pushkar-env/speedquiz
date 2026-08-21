import 'package:equatable/equatable.dart';

/// How a mock test is paced and scored.
///
/// Two independent axes rather than one list, because they genuinely are
/// independent: practice can be timed, and a full mock can be casual. Flattening
/// them into a single enum would mean six names for four real choices and no way
/// to add a third pacing later without renaming everything.
enum TestMode {
  /// Sit the paper as printed. Scored, ranked, no answers until you submit.
  full('full', 'Full Mock'),

  /// One section only, with a proportional slice of the clock.
  sectional('sectional', 'Sectional'),

  /// Answers and worked solutions revealed as you go. Kept out of the ladder,
  /// because a score earned with the key visible is not comparable to one
  /// earned without it.
  practice('practice', 'Practice');

  const TestMode(this.wire, this.label);

  final String wire;
  final String label;

  static TestMode parse(String? raw) => TestMode.values.firstWhere(
    (m) => m.wire == raw,
    orElse: () => TestMode.full,
  );

  bool get revealsAnswers => this == TestMode.practice;

  bool get countsForRank => this != TestMode.practice;

  String get blurb => switch (this) {
    TestMode.full =>
      'The whole paper, one clock. Scored and ranked against everyone else.',
    TestMode.sectional =>
      'One subject at a time, with a proportional share of the clock.',
    TestMode.practice =>
      'See whether each answer is right straight away, with the worked '
          'solution. Not ranked.',
  };
}

/// Whether individual questions carry their own clock.
enum TestPacing {
  /// Only the paper clock. Spend your time however you like.
  casual('casual', 'Casual'),

  /// Each question gets a limit; running out moves you on and locks it.
  timed('timed', 'Timed');

  const TestPacing(this.wire, this.label);

  final String wire;
  final String label;

  static TestPacing parse(String? raw) => TestPacing.values.firstWhere(
    (p) => p.wire == raw,
    orElse: () => TestPacing.casual,
  );

  String get blurb => switch (this) {
    TestPacing.casual =>
      'No per-question limit — the paper clock is the only one.',
    TestPacing.timed =>
      'Each question gets its own timer. When it runs out you move on and '
          'that question locks.',
  };
}

/// The choices made on the setup sheet, ready to send.
class TestSetup extends Equatable {
  const TestSetup({
    required this.mode,
    required this.pacing,
    required this.durationMinutes,
    this.perQuestionSeconds,
    this.sectionId,
  });

  /// Defaults for a paper: sit it exactly as it was set.
  factory TestSetup.defaults({required int paperDurationMinutes}) => TestSetup(
    mode: TestMode.full,
    pacing: TestPacing.casual,
    durationMinutes: paperDurationMinutes,
  );

  final TestMode mode;
  final TestPacing pacing;
  final int durationMinutes;

  /// Null lets the server derive an even split of the overall budget.
  final int? perQuestionSeconds;
  final String? sectionId;

  TestSetup copyWith({
    TestMode? mode,
    TestPacing? pacing,
    int? durationMinutes,
    int? perQuestionSeconds,
    String? sectionId,
    bool clearSection = false,
    bool clearPerQuestion = false,
  }) => TestSetup(
    mode: mode ?? this.mode,
    pacing: pacing ?? this.pacing,
    durationMinutes: durationMinutes ?? this.durationMinutes,
    perQuestionSeconds: clearPerQuestion
        ? null
        : (perQuestionSeconds ?? this.perQuestionSeconds),
    sectionId: clearSection ? null : (sectionId ?? this.sectionId),
  );

  /// The per-question limit the server will apply, for the preview line on the
  /// setup sheet. Mirrors `exam_service.start_attempt`; the server still has
  /// the final say.
  int derivedPerQuestionSeconds(int questionCount) {
    if (perQuestionSeconds != null) return perQuestionSeconds!;
    if (questionCount <= 0) return 60;
    final derived = (durationMinutes * 60 / questionCount).round();
    return derived.clamp(10, 1800);
  }

  @override
  List<Object?> get props => [
    mode,
    pacing,
    durationMinutes,
    perQuestionSeconds,
    sectionId,
  ];
}
