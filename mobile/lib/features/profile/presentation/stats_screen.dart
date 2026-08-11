import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/network/api_errors.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/profile/data/profile_repository.dart';
import 'package:speedquiz/features/profile/domain/profile_models.dart';
import 'package:speedquiz/features/profile/presentation/widgets/profile_widgets.dart';
import 'package:speedquiz/features/topics/data/topics_repository.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// Lifetime statistics, backed by `GET /api/v1/users/me`.
class StatsScreen extends ConsumerWidget {
  const StatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.sq;
    final async = ref.watch(profileProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SqBackdrop(
        intensity: 0.5,
        colors: const [AppColors.cyan, AppColors.accent, AppColors.violet],
        child: SafeArea(
          child: Column(
            children: [
              const SubScreenHeader(
                title: 'Statistics',
                subtitle: 'Everything you have played so far',
              ),
              Expanded(
                child: async.when(
                  loading: () => const SqShimmer(
                    child: Padding(
                      padding: EdgeInsets.all(AppSpacing.lg),
                      child: Column(
                        children: [
                          SqSkeletonCard(height: 96),
                          SizedBox(height: 12),
                          SqSkeletonCard(height: 96),
                          SizedBox(height: 12),
                          SqSkeletonCard(height: 140, lines: 3),
                        ],
                      ),
                    ),
                  ),
                  error: (error, _) => Center(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      child: SqErrorState(
                        title: 'Statistics unavailable',
                        message: apiErrorMessage(
                          error,
                          fallback: 'Could not load your statistics.',
                        ),
                        onRetry: () => ref.invalidate(profileProvider),
                      ),
                    ),
                  ),
                  data: (profile) => RefreshIndicator(
                    color: p.accent,
                    backgroundColor: p.surfaceElevated,
                    onRefresh: () async {
                      ref.invalidate(profileProvider);
                      await ref.read(profileProvider.future);
                    },
                    child: _StatsBody(profile: profile),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatsBody extends ConsumerWidget {
  const _StatsBody({required this.profile});

  final UserProfile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final stats = profile.statistics;
    final topics = ref.watch(topicsProvider).valueOrNull ?? const [];
    final mastery = _mastery(stats, topics);
    final avgSeconds = (stats.averageAnswerMs / 1000).toStringAsFixed(1);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.xxl,
      ),
      children: [
        if (stats.totalQuizzes == 0)
          const SqEmptyState(
            icon: '📊',
            title: 'No runs yet',
            message: 'Play your first quiz and your numbers land here.',
          )
        else ...[
          SqStagger(
            child: SqSurface(
              padding: const EdgeInsets.all(AppSpacing.lg),
              highlighted: true,
              child: Row(
                children: [
                  SqProgressRing(
                    value: (stats.accuracy / 100).clamp(0.0, 1.0),
                    size: 76,
                    stroke: 7,
                    child: Text(
                      '${stats.accuracy.toStringAsFixed(0)}%',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontFamily: 'SpaceGrotesk',
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.lg),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Lifetime accuracy',
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${stats.totalCorrect} correct of '
                          '${stats.totalQuestions} answered',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          SqStagger(
            index: 1,
            child: Row(
              children: [
                Expanded(
                  child: ProfileMetric(
                    label: 'Runs played',
                    value: formatCompact(stats.totalQuizzes),
                    glyph: '🎮',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ProfileMetric(
                    label: 'Best score',
                    value: formatCompact(stats.bestScore),
                    glyph: '🏆',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ProfileMetric(
                    label: 'Best streak',
                    value: '${stats.bestStreak}',
                    glyph: '🔥',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          SqStagger(
            index: 2,
            child: Row(
              children: [
                Expanded(
                  child: ProfileMetric(
                    label: 'Avg answer',
                    value: '${avgSeconds}s',
                    glyph: '⚡',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ProfileMetric(
                    label: 'Questions',
                    value: formatCompact(stats.totalQuestions),
                    glyph: '📘',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ProfileMetric(
                    label: 'Missed',
                    value: formatCompact(stats.totalIncorrect),
                    glyph: '🙈',
                  ),
                ),
              ],
            ),
          ),
          if (mastery.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xl),
            SqStagger(
              index: 3,
              child: const SqSectionHeader(
                title: 'Topic mastery',
                subtitle: 'Where you are strongest',
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            for (var i = 0; i < mastery.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: SqStagger(
                  index: 4 + i,
                  child: _MasteryRow(entry: mastery[i]),
                ),
              ),
          ],
        ],
      ],
    );
  }

  /// Joins server mastery percentages to topic names, best first.
  List<_MasteryEntry> _mastery(ProfileStats stats, List<TopicItem> topics) {
    final byId = {for (final topic in topics) topic.id: topic};
    final bySlug = {for (final topic in topics) topic.slug: topic};

    final entries = <_MasteryEntry>[];
    stats.topicMastery.forEach((key, value) {
      final score = value is num ? value.toDouble() : null;
      if (score == null) return;
      final topic = byId[key] ?? bySlug[key];
      entries.add(
        _MasteryEntry(
          name: topic?.name ?? key,
          icon: topic?.icon ?? '📗',
          percent: score.clamp(0, 100).toDouble(),
        ),
      );
    });

    entries.sort((a, b) => b.percent.compareTo(a.percent));
    return entries.take(8).toList();
  }
}

class _MasteryEntry {
  const _MasteryEntry({
    required this.name,
    required this.icon,
    required this.percent,
  });

  final String name;
  final String icon;
  final double percent;
}

class _MasteryRow extends StatelessWidget {
  const _MasteryRow({required this.entry});

  final _MasteryEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return SqSurface(
      child: Row(
        children: [
          Text(entry.icon, style: const TextStyle(fontSize: 20)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        entry.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    Text(
                      '${entry.percent.toStringAsFixed(0)}%',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: p.accent,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                SqProgressTrack(value: entry.percent / 100, height: 6),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
