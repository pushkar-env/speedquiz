import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/multiplayer/domain/multiplayer_models.dart';
import 'package:speedquiz/features/multiplayer/presentation/multiplayer_providers.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// The last ten matches, each as a readable summary.
///
/// Ten is the whole history, not the first page. The server does not serve an
/// eleventh, so there is nothing here to scroll toward — which is why this has
/// no pagination and no "load more" that would sit there doing nothing.
///
/// Rows are summaries rather than links: who, what it was about, how it ended
/// and by how much, all without opening anything. Tapping still opens the full
/// result for the round-by-round breakdown.
class MatchHistoryScreen extends ConsumerWidget {
  const MatchHistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final matches = ref.watch(matchListProvider);

    return Scaffold(
      backgroundColor: context.sq.background,
      appBar: AppBar(title: Text(l10n.battleHistoryTitle)),
      body: SqBackdrop(
        child: SafeArea(
          child: RefreshIndicator(
            onRefresh: () async => ref.invalidate(matchListProvider),
            child: matches.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => ListView(
                padding: const EdgeInsets.all(AppSpacing.md),
                children: [
                  SqErrorState(
                    message: l10n.matchError(errorCodeOf(error)),
                    onRetry: () => ref.invalidate(matchListProvider),
                  ),
                ],
              ),
              data: (data) {
                if (data.recent.isEmpty) {
                  return ListView(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    children: [
                      SqEmptyState(
                        icon: '🏁',
                        title: l10n.battleHistoryEmpty,
                        message: l10n.battleHistoryEmptyBody,
                      ),
                    ],
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  itemCount: data.recent.length,
                  itemBuilder: (context, index) =>
                      MatchSummaryCard(match: data.recent[index]),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// One finished match, told in a card.
///
/// Shared with the Battle hub's preview so a match reads identically in both
/// places — the hub shows the top few, this screen shows all ten.
class MatchSummaryCard extends StatelessWidget {
  const MatchSummaryCard({super.key, required this.match});

  final MatchState match;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final l10n = context.l10n;

    final me = match.me;
    final opponent = match.primaryOpponent;
    final (label, tint) = switch (match.myOutcome) {
      MatchOutcome.win => (l10n.resultWin, AppColors.success),
      MatchOutcome.loss => (l10n.resultLoss, AppColors.danger),
      MatchOutcome.draw => (l10n.resultDraw, AppColors.warning),
      null => (l10n.battleView, p.textSecondary),
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: SqPressable(
        onTap: () => context.push(Routes.matchPath(match.id)),
        pressedScale: 0.985,
        child: SqSurface(
          padding: const EdgeInsets.all(AppSpacing.md),
          accent: tint,
          highlighted: match.myOutcome == MatchOutcome.win,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SqAvatar(
                    name: opponent?.player.label ?? match.topicName,
                    seed: opponent?.userId ?? match.id,
                    avatarId: opponent?.player.avatarId,
                    size: 40,
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          opponent?.player.label ?? l10n.battlePrivateRoom,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${match.topicName} · '
                          '${DateFormat.MMMd().format((match.finishedAt ?? match.createdAt).toLocal())}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  SqBadge(label: label, dense: true, color: tint),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              // The scoreline, which is the part someone actually came for.
              Row(
                children: [
                  _Side(
                    label: l10n.resultYou,
                    // A finished match has nothing left to withhold, but the
                    // model is honest about not knowing and so is this.
                    score: me?.scoreLabel ?? '—',
                    detail: me == null
                        ? null
                        : l10n.battleCorrectOf(
                            me.correctCount,
                            match.questionCount,
                          ),
                    emphasis: match.myOutcome == MatchOutcome.win,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                    ),
                    child: Text(
                      l10n.resultVersus,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: p.textFaint,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  _Side(
                    label: opponent?.player.label ?? l10n.player,
                    score: opponent?.scoreLabel ?? '—',
                    detail: opponent == null
                        ? null
                        : l10n.battleCorrectOf(
                            opponent.correctCount,
                            match.questionCount,
                          ),
                    emphasis: match.myOutcome == MatchOutcome.loss,
                    alignEnd: true,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One half of the scoreline.
class _Side extends StatelessWidget {
  const _Side({
    required this.label,
    required this.score,
    required this.emphasis,
    this.detail,
    this.alignEnd = false,
  });

  final String label;
  final String score;
  final String? detail;
  final bool emphasis;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return Expanded(
      child: Column(
        crossAxisAlignment:
            alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: p.textFaint,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            score,
            style: theme.textTheme.headlineSmall?.copyWith(
              color: emphasis ? p.accent : p.textPrimary,
              fontWeight: FontWeight.w900,
            ),
          ),
          if (detail != null)
            Text(
              detail!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: p.textFaint),
            ),
        ],
      ),
    );
  }
}
