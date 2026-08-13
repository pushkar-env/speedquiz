import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import 'package:speedquiz/core/feedback/audio_service.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/multiplayer/domain/multiplayer_models.dart';
import 'package:speedquiz/features/multiplayer/presentation/battle_controller.dart';
import 'package:speedquiz/features/multiplayer/presentation/widgets/battle_widgets.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// One route for the whole match, switching on its status.
///
/// A lobby, a live round and a result screen are three views of one object,
/// and the transitions between them are driven by the server. Giving each its
/// own route would mean pushing and popping in response to socket events —
/// which is how a player ends up on a results screen for a match that just
/// restarted, or stranded on a lobby that has already begun.
class BattleScreen extends ConsumerWidget {
  const BattleScreen({super.key, required this.matchId});

  final String matchId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(battleControllerProvider(matchId));
    final controller = ref.read(battleControllerProvider(matchId).notifier);
    final l10n = context.l10n;

    final match = state.match;

    return PopScope(
      // Leaving mid-round forfeits, so it needs a confirmation. Everywhere
      // else back is ordinary.
      canPop: match == null || !match.isPlayable || match.isOver,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final confirmed = await _confirmLeave(context);
        if (confirmed && context.mounted) {
          await controller.leave();
          if (context.mounted) context.pop();
        }
      },
      child: Scaffold(
        backgroundColor: context.sq.background,
        body: SqBackdrop(
          child: SafeArea(
            child: state.isLoading
                ? const Center(child: CircularProgressIndicator())
                : match == null
                    ? SqErrorState(
                        message: l10n.matchError(state.error ?? 'network_error'),
                        onRetry: controller.refresh,
                      )
                    : _Body(matchId: matchId, state: state),
          ),
        ),
      ),
    );
  }

  static Future<bool> _confirmLeave(BuildContext context) async {
    final l10n = context.l10n;
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => SqDialog(
        title: l10n.battleLeaveTitle,
        message: l10n.battleLeaveBody,
        tone: SqDialogTone.danger,
        glyph: '🚪',
        primaryLabel: l10n.battleLeaveConfirm,
        onPrimary: () => Navigator.of(dialogContext).pop(true),
        secondaryLabel: l10n.cancel,
        onSecondary: () => Navigator.of(dialogContext).pop(false),
      ),
    );
    return result ?? false;
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.matchId, required this.state});

  final String matchId;
  final BattleState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final match = state.match!;
    if (match.isOver || state.result != null) {
      return _ResultView(matchId: matchId, state: state);
    }
    if (match.isInLobby) {
      return _LobbyView(matchId: matchId, state: state);
    }
    if (!match.isMyTurn) {
      return _WaitingView(matchId: matchId, state: state);
    }
    return _PlayView(matchId: matchId, state: state);
  }
}

// --- Lobby ------------------------------------------------------------------

class _LobbyView extends ConsumerWidget {
  const _LobbyView({required this.matchId, required this.state});

  final String matchId;
  final BattleState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final match = state.match!;
    final controller = ref.read(battleControllerProvider(matchId).notifier);
    final me = match.me;

    // An unanswered invite is a decision, not a lobby.
    if (me?.status == ParticipantStatus.invited) {
      return _InviteView(matchId: matchId, state: state);
    }

    final seated = match.participants
        .where((p) => p.status != ParticipantStatus.declined)
        .toList(growable: false);
    final readyCount =
        seated.where((p) => p.status == ParticipantStatus.ready).length;
    final isHost = me?.isHost ?? false;
    final amReady = me?.status == ParticipantStatus.ready;

    return Column(
      children: [
        _TopBar(title: l10n.lobbyTitle, subtitle: match.topicName),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              if (match.code != null) _RoomCodeCard(code: match.code!),
              const SizedBox(height: AppSpacing.md),
              SqSectionHeader(
                title: l10n.lobbySeats(seated.length, match.maxPlayers),
                subtitle: l10n.lobbyPlayersReady(readyCount, seated.length),
              ),
              const SizedBox(height: AppSpacing.sm),
              SqSurface(
                child: Column(
                  children: [
                    for (final participant in seated)
                      PlayerTile(
                        player: participant.player,
                        isOnline: participant.isConnected,
                        subtitle: participant.isHost ? l10n.lobbyTitle : null,
                        trailing: participant.status == ParticipantStatus.ready
                            ? const Icon(
                                Icons.check_circle_rounded,
                                color: AppColors.success,
                              )
                            : Text(
                                participant.status == ParticipantStatus.invited
                                    ? l10n.friendsRequestPending
                                    : l10n.lobbyNotReady,
                                style: theme.textTheme.labelSmall,
                              ),
                      ),
                  ],
                ),
              ),
              if (seated.length < 2) ...[
                const SizedBox(height: AppSpacing.lg),
                Text(
                  l10n.lobbyWaitingForOpponent,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            children: [
              SqButton(
                label: amReady ? l10n.lobbyNotReady : l10n.lobbyReady,
                variant: amReady
                    ? SqButtonVariant.ghost
                    : SqButtonVariant.primary,
                onPressed: () => controller.setReady(ready: !amReady),
              ),
              if (isHost && seated.length >= 2) ...[
                const SizedBox(height: AppSpacing.sm),
                SqGhostButton(
                  label: l10n.lobbyStartNow,
                  onPressed: controller.start,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _InviteView extends ConsumerWidget {
  const _InviteView({required this.matchId, required this.state});

  final String matchId;
  final BattleState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final match = state.match!;
    final controller = ref.read(battleControllerProvider(matchId).notifier);
    final host = match.participants
        .where((p) => p.isHost)
        .cast<MatchParticipant?>()
        .firstOrNull;

    return Column(
      children: [
        _TopBar(title: l10n.battleTitle, subtitle: match.topicName),
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SqAvatar(
                    name: host?.player.label,
                    seed: host?.userId,
                    avatarId: host?.player.avatarId,
                    premium: host?.player.isPremium ?? false,
                    size: 92,
                    ring: true,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    '${host?.player.label ?? ''} ${l10n.lobbyChallengedYou}',
                    style: theme.textTheme.titleLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${match.topicName} · ${match.questionCount}',
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            children: [
              SqButton(label: l10n.lobbyAccept, onPressed: controller.accept),
              const SizedBox(height: AppSpacing.sm),
              SqGhostButton(
                label: l10n.lobbyDecline,
                onPressed: () async {
                  await controller.decline();
                  if (context.mounted) context.pop();
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RoomCodeCard extends StatelessWidget {
  const _RoomCodeCard({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    return SqSurface(
      highlighted: true,
      child: Column(
        children: [
          Text(l10n.lobbyRoomCode, style: theme.textTheme.bodySmall),
          const SizedBox(height: 6),
          SelectableText(
            code,
            style: theme.textTheme.headlineMedium?.copyWith(
              letterSpacing: 8,
              fontWeight: FontWeight.w900,
              color: theme.sq.accent,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: SqGhostButton(
                  label: l10n.battleCopy,
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: code));
                    if (context.mounted) {
                      SqToast.success(context, l10n.lobbyCodeCopied);
                    }
                  },
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: SqGhostButton(
                  label: l10n.lobbyShareCode,
                  onPressed: () => SharePlus.instance.share(
                    ShareParams(text: '${l10n.lobbyRoomCode}: $code'),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// --- Playing ----------------------------------------------------------------

class _PlayView extends ConsumerWidget {
  const _PlayView({required this.matchId, required this.state});

  final String matchId;
  final BattleState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final match = state.match!;
    final round = state.round;
    final controller = ref.read(battleControllerProvider(matchId).notifier);

    if (round == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final feedback = state.feedback;
    final revealed = feedback != null;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.md,
            0,
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.battleRoundOf(round.roundIndex + 1, round.totalRounds),
                      style: theme.textTheme.labelLarge,
                    ),
                  ),
                  if (!state.isConnected &&
                      match.delivery == MatchDelivery.live)
                    SqBadge(
                      label: l10n.battleReconnecting,
                      color: AppColors.warning,
                      dense: true,
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              VersusHeader(me: match.me, opponent: match.primaryOpponent),
              const SizedBox(height: AppSpacing.sm),
              SqProgressTrack(
                value: (round.roundIndex + 1) / round.totalRounds,
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(round.prompt, style: theme.textTheme.titleLarge),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  if (!revealed)
                    RoundTimer(
                      deadline: round.deadlineAt.subtract(match.clockSkew),
                      totalMs: round.timeLimitMs,
                      onExpired: controller.timeout,
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              for (final option in round.options)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: _OptionButton(
                    option: option,
                    selected: state.selectedOptionIndex == option.index,
                    correct: revealed
                        ? option.index == feedback.correctOptionIndex
                        : null,
                    enabled: !revealed && !state.isSubmitting,
                    onTap: () {
                      Haptics.tap();
                      controller.submit(option.index);
                    },
                  ),
                ),
              if (revealed) ...[
                const SizedBox(height: AppSpacing.md),
                _Verdict(feedback: feedback, participants: match.opponents),
              ] else ...[
                const SizedBox(height: AppSpacing.md),
                OpponentPips(opponents: match.opponents),
              ],
              if (match.delivery == MatchDelivery.asynchronous) ...[
                const SizedBox(height: AppSpacing.md),
                Text(
                  l10n.battleAsyncNotice,
                  style: theme.textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _OptionButton extends StatelessWidget {
  const _OptionButton({
    required this.option,
    required this.selected,
    required this.correct,
    required this.enabled,
    required this.onTap,
  });

  final MatchOption option;
  final bool selected;

  /// Null until the round closes; then true for the right answer.
  final bool? correct;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    Color border = p.border;
    Color? fill;
    if (correct == true) {
      border = AppColors.success;
      fill = AppColors.success.withValues(alpha: 0.14);
    } else if (correct == false && selected) {
      border = AppColors.danger;
      fill = AppColors.danger.withValues(alpha: 0.14);
    } else if (selected) {
      border = p.accent;
      fill = p.accentWash(0.12);
    }

    return SqPressable(
      enabled: enabled,
      onTap: onTap,
      pressedScale: 0.98,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: 16,
        ),
        decoration: BoxDecoration(
          color: fill ?? p.surface,
          borderRadius: BorderRadius.circular(AppRadii.md),
          border: Border.all(color: border, width: 1.4),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(option.text, style: theme.textTheme.bodyLarge),
            ),
            if (correct == true)
              const Icon(Icons.check_rounded, color: AppColors.success)
            else if (correct == false && selected)
              const Icon(Icons.close_rounded, color: AppColors.danger),
          ],
        ),
      ),
    );
  }
}

class _Verdict extends StatelessWidget {
  const _Verdict({required this.feedback, required this.participants});

  final MatchAnswerFeedback feedback;
  final List<MatchParticipant> participants;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final tint = feedback.isCorrect ? AppColors.success : AppColors.danger;

    return SqSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                feedback.isCorrect
                    ? Icons.check_circle_rounded
                    : Icons.cancel_rounded,
                color: tint,
              ),
              const SizedBox(width: 8),
              Text(
                feedback.isCorrect ? l10n.battleCorrect : l10n.battleWrong,
                style: theme.textTheme.titleMedium?.copyWith(color: tint),
              ),
              const Spacer(),
              if (feedback.pointsAwarded > 0)
                SqBadge(label: '+${feedback.pointsAwarded}', dense: true),
            ],
          ),
          if (feedback.explanation != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(feedback.explanation!, style: theme.textTheme.bodyMedium),
          ],
          if (feedback.opponents.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            // Correctness only appears once the round has closed for everyone;
            // before that the server withholds it and these read as pending.
            for (final opponent in feedback.opponents)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    Icon(
                      opponent.isCorrect == null
                          ? Icons.more_horiz_rounded
                          : opponent.isCorrect!
                              ? Icons.check_rounded
                              : Icons.close_rounded,
                      size: 16,
                      color: opponent.isCorrect == null
                          ? theme.sq.textSecondary
                          : opponent.isCorrect!
                              ? AppColors.success
                              : AppColors.danger,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _nameFor(opponent.userId),
                      style: theme.textTheme.bodySmall,
                    ),
                    if (opponent.pointsAwarded != null) ...[
                      const Spacer(),
                      Text(
                        '+${opponent.pointsAwarded}',
                        style: theme.textTheme.labelSmall,
                      ),
                    ],
                  ],
                ),
              ),
          ],
          const SizedBox(height: AppSpacing.sm),
          Text(l10n.battleWaitingForOthers, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }

  String _nameFor(String userId) {
    for (final participant in participants) {
      if (participant.userId == userId) return participant.player.label;
    }
    return '';
  }
}

// --- Waiting on the opponent ------------------------------------------------

class _WaitingView extends ConsumerWidget {
  const _WaitingView({required this.matchId, required this.state});

  final String matchId;
  final BattleState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final match = state.match!;

    return Column(
      children: [
        _TopBar(title: l10n.battleTitle, subtitle: match.topicName),
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SqProgressRing(value: 1, size: 92),
                  const SizedBox(height: AppSpacing.lg),
                  Text(
                    l10n.resultAwaitingOpponent,
                    style: theme.textTheme.titleLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    l10n.resultAwaitingOpponentBody,
                    style: theme.textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  VersusHeader(me: match.me, opponent: match.primaryOpponent),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: SqButton(
            label: l10n.resultBackToBattle,
            variant: SqButtonVariant.ghost,
            onPressed: () => context.go(Routes.battle),
          ),
        ),
      ],
    );
  }
}

// --- Result -----------------------------------------------------------------

class _ResultView extends ConsumerStatefulWidget {
  const _ResultView({required this.matchId, required this.state});

  final String matchId;
  final BattleState state;

  @override
  ConsumerState<_ResultView> createState() => _ResultViewState();
}

class _ResultViewState extends ConsumerState<_ResultView> {
  @override
  void initState() {
    super.initState();
    // Fire once, after the frame — celebrating inside build would replay on
    // every rebuild the socket triggers.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.state.result?.myOutcome == MatchOutcome.win) {
        Sound.play(Sfx.finish);
        Haptics.success();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final result = widget.state.result;
    final match = widget.state.match!;
    final standings = result?.standings ?? match.participants;
    final outcome = result?.myOutcome ?? match.myOutcome;

    final (String title, String body, Color tint) = switch (outcome) {
      MatchOutcome.win => (l10n.resultWin, l10n.resultWinBody, AppColors.success),
      MatchOutcome.loss => (l10n.resultLoss, l10n.resultLossBody, AppColors.danger),
      MatchOutcome.draw => (l10n.resultDraw, l10n.resultDrawBody, AppColors.warning),
      null => (l10n.resultStandings, '', theme.sq.accent),
    };

    return Stack(
      children: [
        Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(AppSpacing.md),
                children: [
                  const SizedBox(height: AppSpacing.lg),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.displaySmall?.copyWith(color: tint),
                  ),
                  if (body.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      body,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyLarge,
                    ),
                  ],
                  if (result?.ratingDelta != null) ...[
                    const SizedBox(height: AppSpacing.md),
                    Center(
                      child: SqBadge(
                        label: result!.ratingDelta! >= 0
                            ? l10n.resultRatingGained(result.ratingDelta!)
                            : l10n.resultRatingLost(result.ratingDelta!),
                        color: result.ratingDelta! >= 0
                            ? AppColors.success
                            : AppColors.danger,
                      ),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.lg),
                  SqSectionHeader(title: l10n.resultStandings),
                  const SizedBox(height: AppSpacing.sm),
                  SqSurface(
                    child: Column(
                      children: [
                        for (final participant in standings)
                          PlayerTile(
                            player: participant.player,
                            subtitle:
                                '${participant.correctCount}/${match.questionCount} · ${participant.score}',
                            trailing: participant.placement == null
                                ? null
                                : SqBadge(
                                    label: l10n.resultPlacement(
                                      participant.placement!,
                                    ),
                                    dense: true,
                                    color: participant.placement == 1
                                        ? AppColors.success
                                        : null,
                                  ),
                          ),
                      ],
                    ),
                  ),
                  if ((result?.xpEarned ?? 0) > 0) ...[
                    const SizedBox(height: AppSpacing.md),
                    Center(
                      child: Text(
                        '+${result!.xpEarned} ${l10n.xp}  ·  +${result.coinsEarned} ${l10n.coins}',
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: SqButton(
                label: l10n.resultBackToBattle,
                onPressed: () => context.go(Routes.battle),
              ),
            ),
          ],
        ),
        if (outcome == MatchOutcome.win)
          const IgnorePointer(child: SqConfetti(play: true)),
      ],
    );
  }
}

// --- Shared -----------------------------------------------------------------

class _TopBar extends StatelessWidget {
  const _TopBar({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.sm,
        AppSpacing.sm,
        AppSpacing.md,
        0,
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleLarge),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
