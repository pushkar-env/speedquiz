import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/multiplayer/domain/multiplayer_models.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// Shared pieces for the battle screens.

/// A player's face, name and optional rank, used in every list of people.
class PlayerTile extends StatelessWidget {
  const PlayerTile({
    super.key,
    required this.player,
    this.subtitle,
    this.trailing,
    this.isOnline = false,
    this.onTap,
    this.dimmed = false,
  });

  final PlayerBrief player;
  final String? subtitle;
  final Widget? trailing;
  final bool isOnline;
  final VoidCallback? onTap;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return Opacity(
      opacity: dimmed ? 0.55 : 1,
      child: SqPressable(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: Row(
            children: [
              Stack(
                children: [
                  SqAvatar(
                    name: player.label,
                    seed: player.userId,
                    avatarId: player.avatarId,
                    premium: player.isPremium,
                    size: 46,
                  ),
                  if (isOnline)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 13,
                        height: 13,
                        decoration: BoxDecoration(
                          color: AppColors.success,
                          shape: BoxShape.circle,
                          // Ringed in the page background so the dot reads as
                          // sitting on top of the avatar, not inside it.
                          border: Border.all(color: p.background, width: 2),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      player.label,
                      style: theme.textTheme.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: AppSpacing.sm),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The two-sided score header shown throughout a duel.
class VersusHeader extends StatelessWidget {
  const VersusHeader({
    super.key,
    required this.me,
    required this.opponent,
    this.showScores = true,
  });

  final MatchParticipant? me;
  final MatchParticipant? opponent;
  final bool showScores;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    return Row(
      children: [
        Expanded(
          child: _Side(
            participant: me,
            label: l10n.battleYou,
            alignment: CrossAxisAlignment.start,
            showScore: showScores,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          child: Text(
            'VS',
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.sq.textSecondary,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.5,
            ),
          ),
        ),
        Expanded(
          child: _Side(
            participant: opponent,
            label: l10n.battleOpponent,
            alignment: CrossAxisAlignment.end,
            showScore: showScores,
          ),
        ),
      ],
    );
  }
}

class _Side extends StatelessWidget {
  const _Side({
    required this.participant,
    required this.label,
    required this.alignment,
    required this.showScore,
  });

  final MatchParticipant? participant;
  final String label;
  final CrossAxisAlignment alignment;
  final bool showScore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final l10n = context.l10n;
    final player = participant?.player;
    final isEnd = alignment == CrossAxisAlignment.end;

    final avatar = SqAvatar(
      name: player?.label ?? label,
      seed: player?.userId,
      avatarId: player?.avatarId,
      premium: player?.isPremium ?? false,
      size: 40,
    );

    return Column(
      crossAxisAlignment: alignment,
      children: [
        Row(
          mainAxisAlignment: isEnd ? MainAxisAlignment.end : MainAxisAlignment.start,
          children: [
            if (!isEnd) avatar,
            if (!isEnd) const SizedBox(width: 8),
            Flexible(
              child: Text(
                player?.label ?? label,
                style: theme.textTheme.titleSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: isEnd ? TextAlign.right : TextAlign.left,
              ),
            ),
            if (isEnd) const SizedBox(width: 8),
            if (isEnd) avatar,
          ],
        ),
        const SizedBox(height: 4),
        if (showScore)
          SqAnimatedCounter(
            value: participant?.score ?? 0,
            style: theme.textTheme.headlineSmall?.copyWith(
              color: p.accent,
              fontWeight: FontWeight.w900,
            ),
          )
        else
          Text(
            // Before the first round there is no score to show, so the slot
            // carries whether they are actually here instead.
            participant?.isConnected ?? false
                ? l10n.friendsOnline
                : l10n.battleOpponentThinking,
            style: theme.textTheme.bodySmall,
          ),
      ],
    );
  }
}

/// The countdown ring over a live round.
///
/// Ticks locally off a server-supplied absolute deadline rather than counting
/// down a duration, so a stalled frame or a backgrounded app resumes showing
/// the truth instead of however much time it failed to subtract.
class RoundTimer extends StatefulWidget {
  const RoundTimer({
    super.key,
    required this.deadline,
    required this.totalMs,
    required this.onExpired,
  });

  final DateTime deadline;
  final int totalMs;
  final VoidCallback onExpired;

  @override
  State<RoundTimer> createState() => _RoundTimerState();
}

class _RoundTimerState extends State<RoundTimer>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);

  Duration _remaining = Duration.zero;
  bool _fired = false;

  @override
  void initState() {
    super.initState();
    _remaining = _compute();
    _ticker.start();
  }

  @override
  void didUpdateWidget(RoundTimer old) {
    super.didUpdateWidget(old);
    if (old.deadline != widget.deadline) {
      _fired = false;
      _remaining = _compute();
    }
  }

  Duration _compute() {
    final left = widget.deadline.difference(DateTime.now().toUtc());
    return left.isNegative ? Duration.zero : left;
  }

  void _onTick(Duration _) {
    final next = _compute();
    if (next.inMilliseconds ~/ 100 != _remaining.inMilliseconds ~/ 100) {
      setState(() => _remaining = next);
    }
    if (next == Duration.zero && !_fired) {
      _fired = true;
      widget.onExpired();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = widget.totalMs <= 0 ? 1 : widget.totalMs;
    final fraction = (_remaining.inMilliseconds / total).clamp(0.0, 1.0);
    final seconds = (_remaining.inMilliseconds / 1000).ceil();
    final urgent = seconds <= 5;

    return SizedBox(
      width: 58,
      height: 58,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.expand(
            child: CircularProgressIndicator(
              value: fraction,
              strokeWidth: 4,
              backgroundColor: theme.sq.border,
              valueColor: AlwaysStoppedAnimation(
                urgent ? AppColors.danger : theme.sq.accent,
              ),
            ),
          ),
          Text(
            '$seconds',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w900,
              color: urgent ? AppColors.danger : theme.sq.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Live per-opponent status during a round: answered, or still thinking.
class OpponentPips extends StatelessWidget {
  const OpponentPips({super.key, required this.opponents});

  final List<MatchParticipant> opponents;

  @override
  Widget build(BuildContext context) {
    if (opponents.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final l10n = context.l10n;

    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: 6,
      children: [
        for (final opponent in opponents)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: opponent.answeredCurrentRound
                  ? AppColors.success.withValues(alpha: 0.14)
                  : theme.sq.surface,
              borderRadius: BorderRadius.circular(AppRadii.pill),
              border: Border.all(
                color: opponent.answeredCurrentRound
                    ? AppColors.success.withValues(alpha: 0.4)
                    : theme.sq.border,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SqAvatar(
                  name: opponent.player.label,
                  seed: opponent.userId,
                  avatarId: opponent.player.avatarId,
                  size: 18,
                  showGlyph: false,
                ),
                const SizedBox(width: 6),
                Text(
                  opponent.answeredCurrentRound
                      ? l10n.battleOpponentAnswered
                      : l10n.battleOpponentThinking,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: opponent.answeredCurrentRound
                        ? AppColors.success
                        : theme.sq.textSecondary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// A rank tier chip. The icon key comes from the server so tiers can be
/// re-cut without an app update.
class TierChip extends StatelessWidget {
  const TierChip({super.key, required this.tier, required this.label, this.rating});

  final String tier;
  final String label;
  final int? rating;

  static const _colors = <String, Color>{
    'bronze': Color(0xFFB4713A),
    'silver': Color(0xFF9FB0C0),
    'gold': Color(0xFFE0B44A),
    'platinum': Color(0xFF5FD4C4),
    'diamond': Color(0xFF6FA8FF),
    'master': Color(0xFFB57BFF),
    'legend': Color(0xFFFF6B8A),
  };

  @override
  Widget build(BuildContext context) {
    final tint = _colors[tier] ?? Theme.of(context).sq.textSecondary;
    return SqBadge(
      label: rating == null ? label : '$label · $rating',
      color: tint,
      icon: Icons.shield_rounded,
      dense: true,
    );
  }
}
