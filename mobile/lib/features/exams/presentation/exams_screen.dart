import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/exams/data/exam_repository.dart';
import 'package:speedquiz/features/exams/domain/exam_models.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// Browse exams and their past papers.
///
/// Deliberately quieter than the rest of the app. A three-hour JEE mock is a
/// different register from a fifteen-second Survival round, and a candidate
/// about to sit one does not want confetti.
class ExamsScreen extends ConsumerWidget {
  const ExamsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final exams = ref.watch(examListProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Mock Tests')),
      body: exams.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _ErrorState(
          message: 'Could not load exams.',
          onRetry: () => ref.invalidate(examListProvider),
        ),
        data: (list) {
          if (list.isEmpty) {
            return const _EmptyState(
              title: 'No exams yet',
              message: 'Past-year papers will appear here once published.',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: list.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, index) => _ExamCard(exam: list[index]),
          );
        },
      ),
    );
  }
}

class _ExamCard extends StatelessWidget {
  const _ExamCard({required this.exam});

  final ExamSummary exam;

  @override
  Widget build(BuildContext context) {
    final palette = context.sq;
    final subtitle = [
      if (exam.authority != null) exam.authority!,
      '${exam.paperCount} paper${exam.paperCount == 1 ? '' : 's'}',
    ].join(' · ');

    return SqSurface(
      onTap: () => context.push(Routes.examPapersPath(exam.slug)),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: palette.accentWash(),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.school_outlined, color: palette.accent),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(exam.name, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: palette.textSecondary),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right, color: palette.textFaint),
        ],
      ),
    );
  }
}

/// Papers for one exam, newest first.
class ExamPapersScreen extends ConsumerWidget {
  const ExamPapersScreen({super.key, required this.examSlug});

  final String examSlug;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final papers = ref.watch(examPapersProvider(examSlug));

    return Scaffold(
      appBar: AppBar(title: const Text('Past Papers')),
      body: papers.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _ErrorState(
          message: 'Could not load papers.',
          onRetry: () => ref.invalidate(examPapersProvider(examSlug)),
        ),
        data: (list) {
          if (list.isEmpty) {
            return const _EmptyState(
              title: 'No papers yet',
              message: 'Papers appear here as they are published.',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: list.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, index) => _PaperCard(paper: list[index]),
          );
        },
      ),
    );
  }
}

class _PaperCard extends StatelessWidget {
  const _PaperCard({required this.paper});

  final ExamPaper paper;

  @override
  Widget build(BuildContext context) {
    final palette = context.sq;
    final theme = Theme.of(context);

    return SqSurface(
      onTap: paper.isLocked
          ? () => context.push(Routes.premium)
          : () => context.push(Routes.mockTestPath(paper.id)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(paper.title, style: theme.textTheme.titleMedium),
              ),
              if (paper.isLocked)
                Icon(Icons.lock_outline, size: 18, color: palette.textFaint)
              else if (paper.hasLiveAttempt)
                _Pill(label: 'In progress', color: palette.accent),
            ],
          ),
          if (paper.subtitle.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              paper.subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: palette.textSecondary,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 6,
            children: [
              _Fact(
                icon: Icons.timer_outlined,
                label: '${paper.durationMinutes} min',
              ),
              _Fact(
                icon: Icons.help_outline,
                label: '${paper.questionCount} questions',
              ),
              _Fact(
                icon: Icons.emoji_events_outlined,
                label: '${paper.totalMarks.toStringAsFixed(0)} marks',
              ),
            ],
          ),
          if (paper.bestScore != null) ...[
            const SizedBox(height: 12),
            Text(
              'Best: ${paper.bestScore!.toStringAsFixed(0)} / '
              '${paper.totalMarks.toStringAsFixed(0)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: palette.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = context.sq;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: palette.textFaint),
        const SizedBox(width: 5),
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: palette.textSecondary),
        ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final palette = context.sq;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inbox_outlined, size: 40, color: palette.textFaint),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
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

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            SqButton(label: 'Try again', onPressed: onRetry, expand: false),
          ],
        ),
      ),
    );
  }
}
