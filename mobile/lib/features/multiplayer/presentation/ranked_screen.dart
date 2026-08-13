import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/multiplayer/domain/multiplayer_models.dart';
import 'package:speedquiz/features/multiplayer/presentation/multiplayer_providers.dart';
import 'package:speedquiz/features/multiplayer/presentation/widgets/battle_widgets.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// The ranked queue and the season ladder.
///
/// Leaving this screen leaves the queue — the controller's dispose does it —
/// so a player cannot end up paired into a match they walked away from.
class RankedScreen extends ConsumerStatefulWidget {
  const RankedScreen({super.key});

  @override
  ConsumerState<RankedScreen> createState() => _RankedScreenState();
}

class _RankedScreenState extends ConsumerState<RankedScreen> {
  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final queue = ref.watch(rankedQueueProvider);
    final rank = ref.watch(rankedProfileProvider);

    // A pairing sends both sides here. Navigate on the state change rather
    // than inside build, which would fire on every rebuild.
    ref.listen(rankedQueueProvider, (previous, next) {
      final ticket = next.valueOrNull;
      if (ticket?.state == QueueState.matched && ticket?.matchId != null) {
        context.pushReplacement(Routes.matchPath(ticket!.matchId!));
      }
    });

    final ticket = queue.valueOrNull;
    final searching = ticket?.state == QueueState.searching;

    return Scaffold(
      backgroundColor: context.sq.background,
      appBar: AppBar(title: Text(l10n.rankedTitle)),
      body: SqBackdrop(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              rank.when(
                loading: () => const SqShimmer(
                  child: SizedBox(height: 150, width: double.infinity),
                ),
                error: (error, _) => SqErrorState(
                  message: l10n.matchError(errorCodeOf(error)),
                  onRetry: () => ref.invalidate(rankedProfileProvider),
                ),
                data: (profile) => _RankCard(profile: profile),
              ),
              const SizedBox(height: AppSpacing.md),
              if (searching)
                _SearchingCard(ticket: ticket!)
              else if (ticket?.state == QueueState.timeout)
                _TimeoutCard(onRetry: _startSearch)
              else
                SqButton(
                  label: l10n.battleQuickMatch,
                  loading: queue.isLoading,
                  onPressed: _startSearch,
                ),
              const SizedBox(height: AppSpacing.lg),
              const _Ladder(),
            ],
          ),
        ),
      ),
    );
  }

  void _startSearch() {
    ref.read(rankedQueueProvider.notifier).search();
  }
}

class _RankCard extends StatelessWidget {
  const _RankCard({required this.profile});

  final RankedProfile profile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    return SqSurface(
      highlighted: true,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        children: [
          TierChip(
            tier: profile.tier,
            label: profile.isProvisional ? l10n.rankedUnranked : profile.tierName,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '${profile.rating}',
            style: theme.textTheme.displaySmall?.copyWith(
              fontWeight: FontWeight.w900,
              color: theme.sq.accent,
            ),
          ),
          Text(
            '${l10n.rankedSeason} ${profile.seasonKey}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: AppSpacing.md),
          if (profile.isProvisional)
            Text(
              l10n.rankedPlacementsRemaining(profile.placementsRemaining),
              style: theme.textTheme.bodyMedium,
            )
          else ...[
            SqProgressTrack(value: profile.tierProgress),
            const SizedBox(height: 6),
            if (profile.nextTier != null && profile.nextTierAt != null)
              Text(
                l10n.rankedNextTier(
                  profile.nextTier!,
                  profile.nextTierAt! - profile.rating,
                ),
                style: theme.textTheme.bodySmall,
              ),
          ],
          const SizedBox(height: AppSpacing.md),
          Text(
            l10n.rankedRecord(profile.wins, profile.losses, profile.draws),
            style: theme.textTheme.titleSmall,
          ),
          if (profile.rank != null) ...[
            const SizedBox(height: 4),
            Text('${l10n.rankedYourRank}: #${profile.rank}',
                style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

class _SearchingCard extends ConsumerWidget {
  const _SearchingCard({required this.ticket});

  final QueueTicket ticket;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    return SqSurface(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        children: [
          const SizedBox(
            width: 46,
            height: 46,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(l10n.rankedSearching, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            l10n.rankedSearchingBody,
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SqBadge(
                label: l10n.rankedSearchingFor(ticket.waitedSeconds),
                dense: true,
              ),
              if (ticket.playersSearching != null) ...[
                const SizedBox(width: 6),
                SqBadge(
                  label: l10n.rankedPlayersSearching(ticket.playersSearching!),
                  dense: true,
                ),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          SqGhostButton(
            label: l10n.rankedCancelSearch,
            onPressed: () => ref.read(rankedQueueProvider.notifier).cancel(),
          ),
        ],
      ),
    );
  }
}

class _TimeoutCard extends StatelessWidget {
  const _TimeoutCard({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SqSurface(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        children: [
          SqEmptyState(
            icon: '🕑',
            title: l10n.rankedNoOpponent,
            message: l10n.rankedNoOpponentBody,
          ),
          SqButton(label: l10n.rankedTryAgain, onPressed: onRetry),
        ],
      ),
    );
  }
}

class _Ladder extends ConsumerWidget {
  const _Ladder();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final board = ref.watch(rankedLeaderboardProvider);

    return board.when(
      loading: () => const SqShimmer(
        child: SizedBox(height: 200, width: double.infinity),
      ),
      error: (error, _) => SqErrorState(
        message: l10n.matchError(errorCodeOf(error)),
        onRetry: () => ref.invalidate(rankedLeaderboardProvider),
      ),
      data: (data) {
        if (data.items.isEmpty) {
          return SqEmptyState(
            icon: '🪜',
            title: l10n.rankedLadder,
            message: l10n.rankedNoRankYet,
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SqSectionHeader(title: l10n.rankedLadder, subtitle: data.seasonKey),
            const SizedBox(height: AppSpacing.sm),
            SqSurface(
              child: Column(
                children: [
                  for (final entry in data.items)
                    Container(
                      color: entry.isMe
                          ? theme.sq.accentWash(0.08)
                          : Colors.transparent,
                      child: PlayerTile(
                        player: entry.player,
                        subtitle: l10n.friendsHeadToHead(entry.wins, entry.losses),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('#${entry.rank}',
                                style: theme.textTheme.labelMedium),
                            const SizedBox(width: 8),
                            SqBadge(label: '${entry.rating}', dense: true),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
