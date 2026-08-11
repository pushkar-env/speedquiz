import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
import 'package:speedquiz/core/network/api_errors.dart';
import 'package:speedquiz/core/theme/app_motion.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/achievements/data/achievements_repository.dart';
import 'package:speedquiz/features/achievements/domain/achievement_models.dart';
import 'package:speedquiz/features/profile/presentation/widgets/profile_widgets.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

enum _Filter { all, unlocked, locked }

class AchievementsScreen extends ConsumerStatefulWidget {
  const AchievementsScreen({super.key});

  @override
  ConsumerState<AchievementsScreen> createState() => _AchievementsScreenState();
}

class _AchievementsScreenState extends ConsumerState<AchievementsScreen> {
  _Filter _filter = _Filter.all;

  List<AchievementItem> _apply(List<AchievementItem> items) {
    return switch (_filter) {
      _Filter.all => items,
      _Filter.unlocked => items.where((a) => a.unlocked).toList(),
      _Filter.locked => items.where((a) => !a.unlocked).toList(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final async = ref.watch(achievementsProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SqBackdrop(
        intensity: 0.5,
        colors: const [AppColors.gold, AppColors.accent, AppColors.violet],
        child: SafeArea(
          child: Column(
            children: [
              const SubScreenHeader(
                title: 'Achievements',
                subtitle: 'Every milestone worth chasing',
              ),
              Expanded(
                child: async.when(
                  loading: () => const SqShimmer(
                    child: Padding(
                      padding: EdgeInsets.all(AppSpacing.lg),
                      child: Column(
                        children: [
                          SqSkeletonCard(),
                          SizedBox(height: 10),
                          SqSkeletonCard(),
                          SizedBox(height: 10),
                          SqSkeletonCard(),
                          SizedBox(height: 10),
                          SqSkeletonCard(),
                        ],
                      ),
                    ),
                  ),
                  error: (error, _) => Center(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      child: SqErrorState(
                        title: 'Achievements unavailable',
                        message: apiErrorMessage(
                          error,
                          fallback: 'Could not load your achievements.',
                        ),
                        onRetry: () => ref.invalidate(achievementsProvider),
                      ),
                    ),
                  ),
                  data: (list) {
                    final visible = _apply(list.items);

                    return RefreshIndicator(
                      color: p.accent,
                      backgroundColor: p.surfaceElevated,
                      onRefresh: () async {
                        ref.invalidate(achievementsProvider);
                        await ref.read(achievementsProvider.future);
                      },
                      child: ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(
                          AppSpacing.lg,
                          AppSpacing.sm,
                          AppSpacing.lg,
                          AppSpacing.xxl,
                        ),
                        children: [
                          _ProgressHeader(
                            unlocked: list.unlockedCount,
                            total: list.total,
                          ),
                          const SizedBox(height: AppSpacing.md),
                          _FilterRow(
                            filter: _filter,
                            unlocked: list.unlockedCount,
                            locked: list.total - list.unlockedCount,
                            onChanged: (value) {
                              Haptics.tap();
                              setState(() => _filter = value);
                            },
                          ),
                          const SizedBox(height: AppSpacing.md),
                          if (visible.isEmpty)
                            SqEmptyState(
                              icon: _filter == _Filter.unlocked ? '🔓' : '🎉',
                              title: _filter == _Filter.unlocked
                                  ? 'Nothing unlocked yet'
                                  : 'All unlocked',
                              message: _filter == _Filter.unlocked
                                  ? 'Finish a run to claim your first one.'
                                  : 'You have claimed every achievement. '
                                      'Respect.',
                            )
                          else
                            for (var i = 0; i < visible.length; i++)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: SqStagger(
                                  index: i,
                                  child: _AchievementCard(item: visible[i]),
                                ),
                              ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProgressHeader extends StatelessWidget {
  const _ProgressHeader({required this.unlocked, required this.total});

  final int unlocked;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final ratio = total == 0 ? 0.0 : unlocked / total;

    return SqSurface(
      padding: const EdgeInsets.all(AppSpacing.lg),
      highlighted: true,
      accent: AppColors.gold,
      child: Row(
        children: [
          SqProgressRing(
            value: ratio,
            size: 64,
            stroke: 6,
            gradient: AppColors.premiumGradient,
            child: Text(
              '${(ratio * 100).round()}%',
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: p.textPrimary,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$unlocked of $total unlocked',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  unlocked == total && total > 0
                      ? 'Completionist. Nothing left to chase.'
                      : '${total - unlocked} still out there.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterRow extends StatelessWidget {
  const _FilterRow({
    required this.filter,
    required this.unlocked,
    required this.locked,
    required this.onChanged,
  });

  final _Filter filter;
  final int unlocked;
  final int locked;
  final ValueChanged<_Filter> onChanged;

  @override
  Widget build(BuildContext context) {
    final options = [
      (_Filter.all, 'All', unlocked + locked),
      (_Filter.unlocked, 'Unlocked', unlocked),
      (_Filter.locked, 'Locked', locked),
    ];

    return Row(
      children: [
        for (final (value, label, count) in options) ...[
          if (value != _Filter.all) const SizedBox(width: 8),
          Expanded(
            child: _FilterChip(
              label: '$label · $count',
              selected: filter == value,
              onTap: () => onChanged(value),
            ),
          ),
        ],
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return SqPressable(
      onTap: onTap,
      haptic: false,
      pressedScale: 0.95,
      child: AnimatedContainer(
        duration: AppMotion.fast,
        padding: const EdgeInsets.symmetric(vertical: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? p.accentWash(0.16) : p.surface,
          borderRadius: BorderRadius.circular(AppRadii.pill),
          border: Border.all(
            color: selected ? p.accent : p.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall?.copyWith(
            color: selected ? p.accent : p.textSecondary,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _AchievementCard extends StatelessWidget {
  const _AchievementCard({required this.item});

  final AchievementItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final locked = !item.unlocked;

    final rewards = [
      if (item.xpReward > 0) '+${item.xpReward} XP',
      if (item.coinsReward > 0) '+${item.coinsReward} coins',
    ].join(' · ');

    return AnimatedOpacity(
      duration: AppMotion.fast,
      opacity: locked ? 0.62 : 1,
      child: SqSurface(
        highlighted: item.unlocked,
        accent: AppColors.gold,
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: item.unlocked ? AppColors.premiumGradient : null,
                color: item.unlocked ? null : p.border.withValues(alpha: 0.5),
              ),
              child: Text(
                locked ? '🔒' : achievementGlyph(item.icon),
                style: const TextStyle(fontSize: 20),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.name, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 1),
                  Text(item.description, style: theme.textTheme.bodySmall),
                  if (rewards.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      rewards,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: item.unlocked ? AppColors.gold : p.textFaint,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (item.unlocked)
              const Icon(
                Icons.verified_rounded,
                color: AppColors.success,
                size: 20,
              ),
          ],
        ),
      ),
    );
  }
}
