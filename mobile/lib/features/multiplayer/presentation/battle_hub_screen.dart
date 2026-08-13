import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/push/push_service.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/multiplayer/data/multiplayer_repository.dart';
import 'package:speedquiz/features/multiplayer/domain/multiplayer_models.dart';
import 'package:speedquiz/features/multiplayer/presentation/multiplayer_providers.dart';
import 'package:speedquiz/features/multiplayer/presentation/widgets/battle_widgets.dart';
import 'package:speedquiz/features/shell/presentation/main_shell.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// The Battle tab: how you start a match, and everything you have in flight.
///
/// "In play" comes first and is sorted so anything waiting on *you* is at the
/// top. An async challenge is worthless if the person who owes a turn has to
/// go looking for it.
class BattleHubScreen extends ConsumerStatefulWidget {
  const BattleHubScreen({super.key});

  @override
  ConsumerState<BattleHubScreen> createState() => _BattleHubScreenState();
}

class _BattleHubScreenState extends ConsumerState<BattleHubScreen> {
  @override
  void initState() {
    super.initState();
    // Ask for notification permission here rather than at startup: opening
    // Battle is the moment "let us tell you when a friend challenges you"
    // actually means something. No-op when push is not configured.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(pushServiceProvider).ensurePermission();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final matches = ref.watch(matchListProvider);
    final rank = ref.watch(rankedProfileProvider);

    return Scaffold(
      backgroundColor: context.sq.background,
      body: SqBackdrop(
        child: SafeArea(
          bottom: false,
          child: RefreshIndicator(
            onRefresh: () async {
              ref
                ..invalidate(matchListProvider)
                ..invalidate(rankedProfileProvider);
            },
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.md,
                AppSpacing.md,
                MainShell.contentBottomPadding(context),
              ),
              children: [
                _Header(rank: rank.valueOrNull),
                const SizedBox(height: AppSpacing.lg),
                _ModeCard(
                  glyph: '⚔️',
                  title: l10n.battleQuickMatch,
                  subtitle: l10n.battleQuickMatchSubtitle,
                  onTap: () => context.push(Routes.ranked),
                ),
                const SizedBox(height: AppSpacing.sm),
                _ModeCard(
                  glyph: '🤝',
                  title: l10n.battleChallengeFriend,
                  subtitle: l10n.battleChallengeFriendSubtitle,
                  onTap: () => context.push(Routes.friends),
                ),
                const SizedBox(height: AppSpacing.sm),
                _ModeCard(
                  glyph: '🎟️',
                  title: l10n.battleJoinRoom,
                  subtitle: l10n.battlePrivateRoomSubtitle,
                  onTap: () => _promptForCode(context),
                ),
                const SizedBox(height: AppSpacing.lg),
                matches.when(
                  loading: () => const _ListSkeleton(),
                  error: (error, _) => SqErrorState(
                    message: l10n.matchError(errorCodeOf(error)),
                    onRetry: () => ref.invalidate(matchListProvider),
                  ),
                  data: (data) => _MatchSections(
                    active: data.active,
                    recent: data.recent,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _promptForCode(BuildContext context) async {
    final code = await showDialog<String>(
      context: context,
      builder: (_) => const _JoinCodeDialog(),
    );
    if (code == null || code.isEmpty || !context.mounted) return;

    try {
      final match = await ref
          .read(multiplayerRepositoryProvider)
          .joinByCode(code);
      if (!context.mounted) return;
      ref.invalidate(matchListProvider);
      context.push(Routes.matchPath(match.id));
    } catch (error) {
      if (!context.mounted) return;
      SqToast.error(context, context.l10n.matchError(errorCodeOf(error)));
    }
  }
}

class _Header extends StatelessWidget {
  const _Header({this.rank});

  final RankedProfile? rank;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.battleTitle, style: theme.textTheme.headlineMedium),
              if (rank != null) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    TierChip(
                      tier: rank!.tier,
                      label: rank!.isProvisional
                          ? l10n.rankedUnranked
                          : rank!.tierName,
                      rating: rank!.isProvisional ? null : rank!.rating,
                    ),
                    if (rank!.rank != null) ...[
                      const SizedBox(width: 6),
                      Text('#${rank!.rank}', style: theme.textTheme.bodySmall),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
        SqIconButton(
          icon: Icons.notifications_rounded,
          onPressed: () => context.push(Routes.notifications),
        ),
        const SizedBox(width: AppSpacing.sm),
        SqIconButton(
          icon: Icons.people_alt_rounded,
          onPressed: () => context.push(Routes.friends),
        ),
      ],
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.glyph,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final String glyph;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return SqPressable(
      onTap: onTap,
      pressedScale: 0.985,
      child: SqSurface(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: p.accentWash(0.12),
                borderRadius: BorderRadius.circular(AppRadii.md),
              ),
              child: Text(glyph, style: const TextStyle(fontSize: 22)),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text(subtitle, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: p.textSecondary),
          ],
        ),
      ),
    );
  }
}

class _MatchSections extends ConsumerWidget {
  const _MatchSections({required this.active, required this.recent});

  final List<MatchState> active;
  final List<MatchState> recent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;

    if (active.isEmpty && recent.isEmpty) {
      return SqEmptyState(
        icon: '🏁',
        title: l10n.battleNoMatches,
        message: l10n.battleNoMatchesBody,
      );
    }

    // Anything waiting on this player floats to the top of "in play".
    final sortedActive = [...active]..sort((a, b) {
        if (a.isMyTurn == b.isMyTurn) return b.createdAt.compareTo(a.createdAt);
        return a.isMyTurn ? -1 : 1;
      });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (sortedActive.isNotEmpty) ...[
          SqSectionHeader(title: l10n.battleActiveMatches),
          const SizedBox(height: AppSpacing.sm),
          for (final match in sortedActive) _MatchRow(match: match),
          const SizedBox(height: AppSpacing.lg),
        ],
        if (recent.isNotEmpty) ...[
          SqSectionHeader(title: l10n.battleRecentMatches),
          const SizedBox(height: AppSpacing.sm),
          for (final match in recent) _MatchRow(match: match),
        ],
      ],
    );
  }
}

class _MatchRow extends StatelessWidget {
  const _MatchRow({required this.match});

  final MatchState match;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final opponent = match.primaryOpponent;

    final (String action, Color tint) = switch (match) {
      _ when match.isMyTurn => (l10n.battleYourTurn, AppColors.success),
      _ when match.isPlayable => (l10n.battleWaitingOnThem, AppColors.warning),
      _ when match.isInLobby => (l10n.battlePlay, theme.sq.accent),
      _ => (
          switch (match.myOutcome) {
            MatchOutcome.win => l10n.resultWin,
            MatchOutcome.loss => l10n.resultLoss,
            MatchOutcome.draw => l10n.resultDraw,
            null => l10n.battleView,
          },
          match.myOutcome == MatchOutcome.win
              ? AppColors.success
              : theme.sq.textSecondary,
        ),
    };

    final subtitle = match.format == MatchFormat.room
        ? '${match.topicName} · ${l10n.lobbySeats(match.participants.length, match.maxPlayers)}'
        : match.topicName;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: SqPressable(
        onTap: () => context.push(Routes.matchPath(match.id)),
        pressedScale: 0.985,
        child: SqSurface(
          padding: const EdgeInsets.all(AppSpacing.md),
          highlighted: match.isMyTurn,
          child: Row(
            children: [
              SqAvatar(
                name: opponent?.player.label ?? match.topicName,
                seed: opponent?.userId ?? match.id,
                avatarId: opponent?.player.avatarId,
                size: 42,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      opponent?.player.label ?? l10n.battlePrivateRoom,
                      style: theme.textTheme.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              SqBadge(label: action, color: tint, dense: true),
            ],
          ),
        ),
      ),
    );
  }
}

class _JoinCodeDialog extends StatefulWidget {
  const _JoinCodeDialog();

  @override
  State<_JoinCodeDialog> createState() => _JoinCodeDialogState();
}

class _JoinCodeDialogState extends State<_JoinCodeDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SqDialog(
      title: l10n.lobbyEnterCode,
      glyph: '🎟️',
      content: TextField(
        controller: _controller,
        autofocus: true,
        textCapitalization: TextCapitalization.characters,
        maxLength: 8,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              letterSpacing: 6,
              fontWeight: FontWeight.w900,
            ),
        // Room codes use an alphabet with no vowels and no 0/O/1/I/L, so
        // anything outside it is a typo rather than a different room.
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp('[a-zA-Z0-9]')),
          TextInputFormatter.withFunction(
            (_, next) => next.copyWith(text: next.text.toUpperCase()),
          ),
        ],
        decoration: const InputDecoration(counterText: ''),
        onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
      ),
      primaryLabel: l10n.lobbyJoin,
      onPrimary: () => Navigator.of(context).pop(_controller.text.trim()),
      secondaryLabel: l10n.cancel,
      onSecondary: () => Navigator.of(context).pop(),
    );
  }
}

class _ListSkeleton extends StatelessWidget {
  const _ListSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < 3; i++)
          const Padding(
            padding: EdgeInsets.only(bottom: AppSpacing.sm),
            child: SqShimmer(child: SizedBox(height: 74, width: double.infinity)),
          ),
      ],
    );
  }
}
