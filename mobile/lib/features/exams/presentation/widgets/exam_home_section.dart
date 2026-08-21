import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/exams/data/exam_repository.dart';
import 'package:speedquiz/features/exams/domain/exam_models.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// Mock tests on the home screen: the exams, then the mistake notebook.
///
/// A horizontal rail rather than a single card because the answer to "which
/// exam are you preparing for" is one choice a student makes once and then
/// lives in — putting the exams themselves on the home screen makes that
/// choice one tap instead of three.
///
/// Renders nothing at all when no exam is published. An empty section on the
/// home screen is worse than no section: it takes the same vertical space and
/// tells the player nothing.
class ExamHomeSection extends ConsumerWidget {
  const ExamHomeSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final exams = ref.watch(examListProvider);

    return exams.when(
      loading: () => const _RailSkeleton(),
      error: (_, _) => const SizedBox.shrink(),
      data: (list) {
        if (list.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SqSectionHeader(
              title: 'Mock Tests',
              subtitle: 'Past papers, timed and scored',
              actionLabel: 'ALL',
              onAction: () => context.push(Routes.exams),
            ),
            const SizedBox(height: AppSpacing.md),
            SizedBox(
              height: 116,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                itemCount: list.length,
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (context, index) => _ExamTile(exam: list[index]),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: NotebookCard(),
            ),
          ],
        );
      },
    );
  }
}

class _ExamTile extends StatelessWidget {
  const _ExamTile({required this.exam});

  final ExamSummary exam;

  @override
  Widget build(BuildContext context) {
    final p = context.sq;
    final theme = Theme.of(context);

    return SizedBox(
      width: 160,
      child: SqSurface(
        padding: const EdgeInsets.all(14),
        onTap: () {
          Haptics.tap();
          context.push(Routes.examPapersPath(exam.slug));
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: p.accentWash(),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.school_outlined, size: 18, color: p.accent),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  exam.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 2),
                Text(
                  '${exam.paperCount} paper${exam.paperCount == 1 ? '' : 's'}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: p.textSecondary,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Entry to the mistake notebook, with the count of what is waiting.
///
/// The count is the point: "Mistake notebook" is a feature, "12 to revise" is
/// a reason to open it. It hides itself entirely at zero rather than showing an
/// encouraging empty state — a student who has made no mistakes yet has not
/// taken a test yet, and this is not where that gets explained.
class NotebookCard extends ConsumerWidget {
  const NotebookCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(notebookCountProvider).valueOrNull ?? 0;
    if (count == 0) return const SizedBox.shrink();

    final p = context.sq;
    final theme = Theme.of(context);

    return SqSurface(
      onTap: () {
        Haptics.tap();
        context.push(Routes.notebook);
      },
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: const Color(0xFFC0392B).withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(11),
            ),
            child: const Icon(
              Icons.menu_book_outlined,
              size: 20,
              color: Color(0xFFC0392B),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Mistake notebook', style: theme.textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(
                  '$count question${count == 1 ? '' : 's'} to revise',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: p.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right, color: p.textFaint),
        ],
      ),
    );
  }
}

class _RailSkeleton extends StatelessWidget {
  const _RailSkeleton();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 116,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        itemCount: 2,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, _) =>
            const SqShimmer(child: SizedBox(width: 160, height: 116)),
      ),
    );
  }
}
