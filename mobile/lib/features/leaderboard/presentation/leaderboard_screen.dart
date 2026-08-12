import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
import 'package:speedquiz/core/network/api_errors.dart';
import 'package:speedquiz/core/theme/app_motion.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/leaderboard/data/leaderboard_repository.dart';
import 'package:speedquiz/features/leaderboard/domain/leaderboard_models.dart';
import 'package:speedquiz/features/shell/presentation/main_shell.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

class LeaderboardScreen extends ConsumerStatefulWidget {
  const LeaderboardScreen({super.key});

  @override
  ConsumerState<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends ConsumerState<LeaderboardScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this)
    ..addListener(() {
      if (!_tabs.indexIsChanging) Haptics.tap();
    });

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SqBackdrop(
        intensity: 0.6,
        colors: const [AppColors.gold, AppColors.accent, AppColors.violet],
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.md,
                  AppSpacing.lg,
                  0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Leaderboard', style: theme.textTheme.displaySmall),
                    const SizedBox(height: 4),
                    Text(
                      'Climb the weekly ranks and today’s daily board',
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: p.surface.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(AppRadii.pill),
                        border: Border.all(color: p.border),
                      ),
                      child: TabBar(
                        controller: _tabs,
                        dividerColor: Colors.transparent,
                        indicatorSize: TabBarIndicatorSize.tab,
                        // The indicator is the bright brand gradient in both
                        // themes, so the label is always ink.
                        labelColor: const Color(0xFF04110C),
                        unselectedLabelColor: p.textSecondary,
                        indicator: BoxDecoration(
                          gradient: AppColors.brandGradient,
                          borderRadius: BorderRadius.circular(AppRadii.pill),
                        ),
                        tabs: const [
                          Tab(height: 38, text: 'Weekly'),
                          Tab(height: 38, text: 'Daily'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabs,
                  children: const [
                    _BoardTab(scope: 'weekly'),
                    _BoardTab(scope: 'daily'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BoardTab extends ConsumerWidget {
  const _BoardTab({required this.scope});

  final String scope;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(leaderboardProvider(scope));
    final p = context.sq;

    return async.when(
      loading: () => const _BoardSkeleton(),
      error: (error, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: SqErrorState(
            title: 'Could not load ranks',
            message: apiErrorMessage(
              error,
              fallback: 'The board is not reachable right now.',
            ),
            onRetry: () => ref.invalidate(leaderboardProvider(scope)),
          ),
        ),
      ),
      data: (board) {
        final podium = board.items.take(3).toList();
        final rest = board.items.skip(3).toList();

        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(leaderboardProvider(scope));
            await ref.read(leaderboardProvider(scope).future);
          },
          color: p.accent,
          backgroundColor: p.surfaceElevated,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.md,
              AppSpacing.lg,
              MainShell.contentBottomPadding(context),
            ),
            children: [
              if (board.items.isEmpty)
                SqEmptyState(
                  icon: scope == 'daily' ? '📅' : '🏁',
                  title: 'No ranks yet',
                  message: scope == 'daily'
                      ? 'Finish today’s challenge to claim the board first.'
                      : 'Play a run this week and your name lands here.',
                )
              else ...[
                if (podium.isNotEmpty) ...[
                  SqStagger(child: _Podium(entries: podium)),
                  const SizedBox(height: AppSpacing.lg),
                ],
                if (board.me.score != null) ...[
                  SqStagger(
                    index: 1,
                    child: _MeCard(me: board.me, periodKey: board.periodKey),
                  ),
                  const SizedBox(height: AppSpacing.md),
                ],
                for (var i = 0; i < rest.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: SqStagger(
                      index: 2 + i,
                      child: _RankRow(entry: rest[i]),
                    ),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Top three, rendered as a real podium — 1st centre and tallest.
class _Podium extends StatelessWidget {
  const _Podium({required this.entries});

  final List<LeaderboardEntry> entries;

  @override
  Widget build(BuildContext context) {
    LeaderboardEntry? at(int rankIndex) =>
        rankIndex < entries.length ? entries[rankIndex] : null;

    final first = at(0);
    final second = at(1);
    final third = at(2);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(child: _PodiumSlot(entry: second, place: 2, height: 96)),
        const SizedBox(width: 8),
        Expanded(child: _PodiumSlot(entry: first, place: 1, height: 126)),
        const SizedBox(width: 8),
        Expanded(child: _PodiumSlot(entry: third, place: 3, height: 78)),
      ],
    );
  }
}

class _PodiumSlot extends StatelessWidget {
  const _PodiumSlot({
    required this.entry,
    required this.place,
    required this.height,
  });

  final LeaderboardEntry? entry;
  final int place;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    if (entry == null) {
      return SizedBox(
        height: height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: p.surface.withValues(alpha: 0.4),
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(AppRadii.md),
            ),
            border: Border.all(color: p.border),
          ),
        ),
      );
    }

    final tint = AppColors.podium[place - 1];
    final medal = ['🥇', '🥈', '🥉'][place - 1];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SqAvatar(
          name: entry!.username,
          seed: entry!.username,
          avatarId: entry!.avatarId,
          size: place == 1 ? 52 : 42,
          ring: true,
          premium: entry!.isPremium,
        ),
        const SizedBox(height: 6),
        Text(
          entry!.username,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: theme.textTheme.labelMedium?.copyWith(
            fontWeight: entry!.isMe ? FontWeight.w800 : FontWeight.w600,
            color: entry!.isMe ? p.accent : p.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          height: height,
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                tint.withValues(alpha: 0.28),
                tint.withValues(alpha: 0.05),
              ],
            ),
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(AppRadii.md),
            ),
            border: Border.all(color: tint.withValues(alpha: 0.4)),
          ),
          child: Column(
            children: [
              Text(medal, style: TextStyle(fontSize: place == 1 ? 26 : 21)),
              const Spacer(),
              Text(
                formatCompact(entry!.score),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontFamily: 'SpaceGrotesk',
                  fontWeight: FontWeight.w700,
                  color: tint,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MeCard extends StatelessWidget {
  const _MeCard({required this.me, required this.periodKey});

  final LeaderboardMe me;
  final String periodKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadii.md),
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [p.accentWash(0.18), p.accentWash(0.05)],
        ),
        border: Border.all(color: p.accentWash(0.4)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 46,
            child: Text(
              me.rank != null ? '#${me.rank}' : '—',
              style: theme.textTheme.titleLarge?.copyWith(color: p.accent),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  me.username ?? 'You',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
                Text(
                  'Your best · $periodKey',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          SqAnimatedCounter(
            value: me.score ?? 0,
            style: theme.textTheme.titleLarge,
          ),
        ],
      ),
    );
  }
}

class _RankRow extends StatelessWidget {
  const _RankRow({required this.entry});

  final LeaderboardEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return AnimatedContainer(
      duration: AppMotion.fast,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadii.md),
        color: entry.isMe ? p.accentWash(0.1) : p.surface,
        border: Border.all(
          color: entry.isMe ? p.accentWash(0.4) : p.border,
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 34,
            child: Text(
              '${entry.rank}',
              style: theme.textTheme.titleSmall?.copyWith(
                fontFamily: 'SpaceGrotesk',
                color: p.textFaint,
              ),
            ),
          ),
          SqAvatar(
            name: entry.username,
            seed: entry.username,
            avatarId: entry.avatarId,
            size: 32,
            premium: entry.isPremium,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    entry.username,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: entry.isMe ? p.accent : p.textPrimary,
                      fontWeight:
                          entry.isMe ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                ),
                if (entry.isPremium) ...[
                  const SizedBox(width: 5),
                  const Icon(
                    Icons.workspace_premium_rounded,
                    size: 14,
                    color: AppColors.gold,
                  ),
                ],
              ],
            ),
          ),
          Text(
            formatScore(entry.score),
            style: theme.textTheme.titleSmall?.copyWith(
              fontFamily: 'SpaceGrotesk',
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _BoardSkeleton extends StatelessWidget {
  const _BoardSkeleton();

  @override
  Widget build(BuildContext context) {
    return SqShimmer(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.md,
          AppSpacing.lg,
          AppSpacing.lg,
        ),
        physics: const NeverScrollableScrollPhysics(),
        children: [
          const Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(child: SqSkeleton(height: 120, radius: AppRadii.md)),
              SizedBox(width: 8),
              Expanded(child: SqSkeleton(height: 150, radius: AppRadii.md)),
              SizedBox(width: 8),
              Expanded(child: SqSkeleton(height: 100, radius: AppRadii.md)),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          for (var i = 0; i < 5; i++) ...[
            const SqSkeletonCard(height: 58, lines: 1),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}
