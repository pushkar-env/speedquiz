import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/exams/data/exam_repository.dart';
import 'package:speedquiz/features/exams/domain/exam_models.dart';
import 'package:speedquiz/features/exams/presentation/mock_test_screen.dart'
    show PaletteColors;
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// What the candidate came for.
///
/// Rank before score, and the diagnosis before the question list: a student
/// already knows how the paper felt, and what they cannot work out alone is
/// which chapters cost them the marks.
class MockResultScreen extends ConsumerWidget {
  const MockResultScreen({super.key, required this.attemptId});

  final String attemptId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(attemptResultProvider(attemptId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Result'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => context.go('/home'),
        ),
      ),
      body: result.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Could not load the result.',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                SqButton(
                  label: 'Try again',
                  expand: false,
                  onPressed: () =>
                      ref.invalidate(attemptResultProvider(attemptId)),
                ),
              ],
            ),
          ),
        ),
        data: (data) => _ResultBody(result: data),
      ),
    );
  }
}

class _ResultBody extends StatelessWidget {
  const _ResultBody({required this.result});

  final AttemptResult result;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        _ScoreCard(result: result),
        const SizedBox(height: 16),
        _TallyRow(result: result),
        if (result.sections.isNotEmpty) ...[
          const SizedBox(height: 24),
          _SectionHeading(text: 'By section'),
          const SizedBox(height: 8),
          ...result.sections.entries.map(
            (entry) =>
                _SectionRow(data: (entry.value as Map).cast<String, dynamic>()),
          ),
        ],
        if (result.chapters.isNotEmpty) ...[
          const SizedBox(height: 24),
          _SectionHeading(text: 'Weakest chapters'),
          const SizedBox(height: 8),
          // Sorted weakest-first by the model layer: this list is the answer to
          // "what do I do next", so the worst has to be at the top.
          ...result.chapters.take(6).map((c) => _ChapterRow(chapter: c)),
        ],
        const SizedBox(height: 24),
        _SectionHeading(text: 'Every question'),
        const SizedBox(height: 8),
        _QuestionGrid(result: result),
      ],
    );
  }
}

class _ScoreCard extends StatelessWidget {
  const _ScoreCard({required this.result});

  final AttemptResult result;

  @override
  Widget build(BuildContext context) {
    final palette = context.sq;
    final theme = Theme.of(context);
    final auto = result.attempt.status == 'auto_submitted';

    return SqSurface(
      child: Column(
        children: [
          if (result.percentile != null) ...[
            Text(
              '${result.percentile!.toStringAsFixed(1)}th percentile',
              style: theme.textTheme.titleMedium?.copyWith(
                color: palette.accent,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (result.rank != null)
              Text(
                'Rank ${result.rank} of ${result.totalAttempts}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: palette.textSecondary,
                ),
              ),
            const SizedBox(height: 12),
          ],
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                result.score.toStringAsFixed(0),
                style: theme.textTheme.displaySmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                ' / ${result.maxScore.toStringAsFixed(0)}',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: palette.textSecondary,
                ),
              ),
            ],
          ),
          if (auto) ...[
            const SizedBox(height: 8),
            Text(
              'Submitted automatically when time ran out.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: palette.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TallyRow extends StatelessWidget {
  const _TallyRow({required this.result});

  final AttemptResult result;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _Tally(
            label: 'Correct',
            value: result.correct,
            color: PaletteColors.answered,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _Tally(
            label: 'Wrong',
            value: result.incorrect,
            color: PaletteColors.notAnswered,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _Tally(
            label: 'Skipped',
            value: result.unattempted,
            color: PaletteColors.notVisited,
          ),
        ),
      ],
    );
  }
}

class _Tally extends StatelessWidget {
  const _Tally({required this.label, required this.value, required this.color});

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SqSurface(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
      child: Column(
        children: [
          Text(
            '$value',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
    );
  }
}

class _SectionRow extends StatelessWidget {
  const _SectionRow({required this.data});

  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final palette = context.sq;
    final score = (data['score'] as num?)?.toDouble() ?? 0;
    final maxScore = (data['max_score'] as num?)?.toDouble() ?? 0;
    final excluded = (data['excluded'] as num?)?.toInt() ?? 0;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SqSurface(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${data['name']}'),
                  Text(
                    '${data['correct']} right · ${data['incorrect']} wrong · '
                    '${data['unattempted']} skipped'
                    // A "best N of M" section drops the surplus rather than
                    // penalising it; saying so avoids a support ticket.
                    '${excluded > 0 ? ' · $excluded not counted' : ''}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: palette.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              '${score.toStringAsFixed(0)}/${maxScore.toStringAsFixed(0)}',
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChapterRow extends StatelessWidget {
  const _ChapterRow({required this.chapter});

  final ChapterBreakdown chapter;

  @override
  Widget build(BuildContext context) {
    final palette = context.sq;
    final accuracy = chapter.accuracy;
    final color = accuracy >= 0.7
        ? PaletteColors.answered
        : accuracy >= 0.4
        ? const Color(0xFF9A6410)
        : PaletteColors.notAnswered;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SqSurface(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(chapter.name),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: accuracy,
                      minHeight: 5,
                      backgroundColor: palette.surfaceElevated,
                      valueColor: AlwaysStoppedAnimation(color),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '${chapter.correct}/${chapter.total}',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: palette.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuestionGrid extends StatelessWidget {
  const _QuestionGrid({required this.result});

  final AttemptResult result;

  @override
  Widget build(BuildContext context) {
    final palette = context.sq;
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 52,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: result.questions.length,
      itemBuilder: (context, index) {
        final question = result.questions[index];
        final color = switch (question.isCorrect) {
          true => PaletteColors.answered,
          false => PaletteColors.notAnswered,
          null => palette.surfaceElevated,
        };
        return Material(
          color: color,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _showSolution(context, question),
            child: Center(
              child: Text(
                '${question.number}',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: question.attempted
                      ? Colors.white
                      : palette.textSecondary,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _showSolution(BuildContext context, QuestionResult question) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        final palette = sheetContext.sq;
        final answer = question.correctValue != null
            ? question.correctValue!.toString()
            : question.correctOptionIndex != null
            ? 'Option ${question.correctOptionIndex! + 1}'
            : 'unavailable';

        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.55,
          builder: (context, scrollController) => ListView(
            controller: scrollController,
            padding: const EdgeInsets.all(20),
            children: [
              Row(
                children: [
                  Text(
                    'Question ${question.number}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  Text(
                    '${question.marksAwarded > 0 ? '+' : ''}'
                    '${question.marksAwarded.toStringAsFixed(0)}',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: question.marksAwarded > 0
                          ? PaletteColors.answered
                          : question.marksAwarded < 0
                          ? PaletteColors.notAnswered
                          : palette.textSecondary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Correct answer: $answer',
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: palette.textSecondary),
              ),
              if (!question.counted)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Not counted — this section scores only your best answers.',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: palette.textFaint),
                  ),
                ),
              const Divider(height: 28),
              if (question.solution.isNotEmpty)
                Text(
                  question.solution,
                  style: Theme.of(context).textTheme.bodyMedium,
                )
              else
                // Solutions that failed verification are withheld rather than
                // shown: a plausible wrong method teaches the wrong thing.
                Row(
                  children: [
                    Icon(
                      Icons.hourglass_empty,
                      size: 16,
                      color: palette.textFaint,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'A worked solution for this question is still being '
                        'checked by our team.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: palette.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }
}
