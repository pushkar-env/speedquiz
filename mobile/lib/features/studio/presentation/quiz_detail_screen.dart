import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/routing/nav.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/multiplayer/domain/multiplayer_models.dart';
import 'package:speedquiz/features/multiplayer/presentation/multiplayer_providers.dart';
import 'package:speedquiz/features/studio/data/custom_quiz_repository.dart';
import 'package:speedquiz/features/studio/domain/custom_quiz_models.dart';
import 'package:speedquiz/features/studio/presentation/widgets/quiz_widgets.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// One quiz: play it, challenge someone with it, see who is winning it.
///
/// The same screen for the author and for a player. What differs is the top
/// action — the author gets "Edit" while a draft is unfinished — and the fact
/// that only the author is ever sent the questions.
class QuizDetailScreen extends ConsumerStatefulWidget {
  const QuizDetailScreen({super.key, required this.quizId});

  final String quizId;

  @override
  ConsumerState<QuizDetailScreen> createState() => _QuizDetailScreenState();
}

class _QuizDetailScreenState extends ConsumerState<QuizDetailScreen> {
  String? _mode;
  bool _starting = false;

  Future<void> _refresh() async {
    ref
      ..invalidate(customQuizProvider(widget.quizId))
      ..invalidate(quizLeaderboardProvider(widget.quizId));
    await ref.read(customQuizProvider(widget.quizId).future);
  }

  Future<void> _play(CustomQuiz quiz) async {
    if (_starting) return;
    setState(() => _starting = true);
    final l10n = context.l10n;

    try {
      final run = await ref
          .read(customQuizRepositoryProvider)
          .start(quiz.id, mode: _mode ?? quiz.defaultMode);
      if (!mounted) return;
      Haptics.success();
      setState(() => _starting = false);

      await context.push(
        Routes.quizPlay,
        extra: {
          'topicId': run.session.topicId,
          'topicName': run.session.topicName,
          'mode': run.session.mode,
          'difficulty': run.session.difficulty,
          'language': run.session.language,
          'session': run.session,
        },
      );
      // Back from the run: the board and the play counters have moved.
      if (mounted) await _refresh();
    } catch (error) {
      if (!mounted) return;
      Haptics.error();
      setState(() => _starting = false);
      SqToast.error(
        context,
        quizErrorMessage(context, error, fallback: l10n.somethingWentWrong),
      );
    }
  }

  Future<void> _challenge(CustomQuiz quiz) async {
    Haptics.tap();
    final friends = await ref.read(friendsProvider.future);
    if (!mounted) return;

    if (friends.isEmpty) {
      await showSqInfo(
        context,
        title: context.l10n.friendsNoFriends,
        message: context.l10n.friendsNoFriendsBody,
        glyph: '👥',
        actionLabel: context.l10n.friendsAdd,
      );
      if (mounted) context.push(Routes.friends);
      return;
    }

    final opponent = await showSqSheet<PlayerBrief>(
      context,
      builder: (sheetContext) => _FriendPicker(friends: friends),
    );
    if (opponent == null || !mounted) return;
    await _sendChallenge(quiz, opponentUserId: opponent.userId);
  }

  Future<void> _openRoom(CustomQuiz quiz) async {
    Haptics.tap();
    await _sendChallenge(quiz, isRoom: true);
  }

  Future<void> _sendChallenge(
    CustomQuiz quiz, {
    String? opponentUserId,
    bool isRoom = false,
  }) async {
    final router = GoRouter.of(context);
    try {
      final match = await ref
          .read(customQuizRepositoryProvider)
          .challenge(
            quiz.id,
            opponentUserId: opponentUserId,
            isRoom: isRoom,
          );
      if (!mounted) return;
      Haptics.success();
      ref.invalidate(matchListProvider);
      router.push(Routes.matchPath(match.id));
    } catch (error) {
      if (!mounted) return;
      Haptics.error();
      SqToast.error(context, quizErrorMessage(context, error));
    }
  }

  Future<void> _share(CustomQuiz quiz) async {
    final code = quiz.code;
    if (code == null) return;
    Haptics.tap();
    final l10n = context.l10n;
    final message = l10n.quizShareMessage(quiz.title, code);
    try {
      await SharePlus.instance.share(ShareParams(text: message));
    } catch (_) {
      // Sharing can be unavailable (no target app, a locked-down device).
      // The code is the payload, so falling back to the clipboard still gets
      // the player what they were reaching for.
      await Clipboard.setData(ClipboardData(text: message));
      if (mounted) SqToast.success(context, l10n.quizCodeCopied);
    }
  }

  Future<void> _copyCode(CustomQuiz quiz) async {
    final code = quiz.code;
    if (code == null) return;
    Haptics.tap();
    await Clipboard.setData(ClipboardData(text: code));
    if (mounted) SqToast.success(context, context.l10n.quizCodeCopied);
  }

  Future<void> _report(CustomQuiz quiz) async {
    final l10n = context.l10n;
    final reason = await showSqSheet<String>(
      context,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Text(
                l10n.quizReportTitle,
                style: Theme.of(sheetContext).textTheme.titleLarge,
              ),
            ),
            for (final (value, label) in [
              ('offensive', l10n.quizReportOffensive),
              ('wrong_answers', l10n.quizReportWrongAnswers),
              ('spam', l10n.quizReportSpam),
              ('copyright', l10n.quizReportCopyright),
              ('other', l10n.quizReportOther),
            ])
              ListTile(
                title: Text(label),
                onTap: () => Navigator.of(sheetContext).pop(value),
              ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    );
    if (reason == null || !mounted) return;

    try {
      await ref
          .read(customQuizRepositoryProvider)
          .report(quiz.id, reason: reason);
      if (mounted) SqToast.success(context, l10n.quizReportSent);
    } catch (error) {
      if (mounted) SqToast.error(context, quizErrorMessage(context, error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final l10n = context.l10n;
    final quizAsync = ref.watch(customQuizProvider(widget.quizId));

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SqBackdrop(
        intensity: 0.55,
        colors: const [AppColors.gold, AppColors.accent, AppColors.violet],
        child: SafeArea(
          child: quizAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: SqErrorState(
                message: quizErrorMessage(context, error),
                onRetry: _refresh,
              ),
            ),
            data: (quiz) => Column(
              children: [
                _header(theme, l10n, quiz),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _refresh,
                    color: p.accent,
                    backgroundColor: p.surfaceElevated,
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.lg,
                        AppSpacing.sm,
                        AppSpacing.lg,
                        AppSpacing.xxl,
                      ),
                      children: [
                        SqStagger(child: _QuizHeadline(quiz: quiz)),
                        if (quiz.isOwner && !quiz.status.isLive) ...[
                          const SizedBox(height: AppSpacing.md),
                          SqStagger(
                            index: 1,
                            child: SqSurface(
                              accent: quizStatusTint(quiz.status),
                              highlighted: true,
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.info_outline_rounded,
                                    size: 19,
                                    color: quizStatusTint(quiz.status),
                                  ),
                                  const SizedBox(width: AppSpacing.sm),
                                  Expanded(
                                    child: Text(
                                      quiz.isHidden
                                          ? (quiz.moderationNote ??
                                                l10n.editorHiddenNote)
                                          : l10n.quizDraftNotice,
                                      style: theme.textTheme.bodyMedium,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                        if (quiz.code != null &&
                            quiz.visibility != QuizVisibility.private) ...[
                          const SizedBox(height: AppSpacing.md),
                          SqStagger(
                            index: 2,
                            child: _ShareRow(
                              code: quiz.code!,
                              onCopy: () => _copyCode(quiz),
                              onShare: () => _share(quiz),
                            ),
                          ),
                        ],
                        if (quiz.isPlayable) ...[
                          const SizedBox(height: AppSpacing.lg),
                          SqStagger(
                            index: 3,
                            child: SqSectionHeader(title: l10n.quizChooseMode),
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          SqStagger(
                            index: 4,
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final (value, label, icon) in [
                                  (
                                    'casual',
                                    l10n.setupModeCasual,
                                    Icons.all_inclusive_rounded,
                                  ),
                                  (
                                    'speedrun',
                                    l10n.setupModeSpeedrun,
                                    Icons.bolt_rounded,
                                  ),
                                  (
                                    'survival',
                                    l10n.setupModeSurvival,
                                    Icons.favorite_rounded,
                                  ),
                                ])
                                  QuizChip(
                                    label: label,
                                    icon: icon,
                                    selected:
                                        (_mode ?? quiz.defaultMode) == value,
                                    onTap: () {
                                      Haptics.tap();
                                      setState(() => _mode = value);
                                    },
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(height: AppSpacing.md),
                          SqStagger(
                            index: 5,
                            child: SqButton(
                              label: l10n.quizPlaySolo,
                              icon: Icons.play_arrow_rounded,
                              loading: _starting,
                              onPressed: () => _play(quiz),
                            ),
                          ),
                          const SizedBox(height: 10),
                          SqStagger(
                            index: 6,
                            child: Row(
                              children: [
                                Expanded(
                                  child: SqButton(
                                    label: l10n.quizChallengeFriend,
                                    icon: Icons.sports_kabaddi_rounded,
                                    variant: SqButtonVariant.ghost,
                                    onPressed: () => _challenge(quiz),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                SqIconButton(
                                  icon: Icons.groups_rounded,
                                  tooltip: l10n.quizOpenRoom,
                                  size: 54,
                                  onPressed: () => _openRoom(quiz),
                                ),
                              ],
                            ),
                          ),
                        ],
                        const SizedBox(height: AppSpacing.xl),
                        _Leaderboard(quizId: quiz.id),
                        if (!quiz.isOwner) ...[
                          const SizedBox(height: AppSpacing.lg),
                          Center(
                            child: TextButton.icon(
                              onPressed: () => _report(quiz),
                              icon: const Icon(Icons.flag_outlined, size: 16),
                              label: Text(l10n.quizReport),
                              style: TextButton.styleFrom(
                                foregroundColor: p.textFaint,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(ThemeData theme, SqStrings l10n, CustomQuiz quiz) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        0,
      ),
      child: Row(
        children: [
          SqIconButton(
            icon: Icons.arrow_back_rounded,
            tooltip: l10n.close,
            onPressed: () => context.popOrGo(Routes.studio),
          ),
          const Spacer(),
          if (quiz.isOwner && !quiz.isHidden)
            SqButton(
              label: l10n.quizEdit,
              icon: Icons.edit_rounded,
              variant: SqButtonVariant.ghost,
              expand: false,
              height: 42,
              onPressed: () async {
                await context.push(Routes.quizEditorPath(quiz.id));
                if (mounted) await _refresh();
              },
            ),
        ],
      ),
    );
  }
}

class _QuizHeadline extends StatelessWidget {
  const _QuizHeadline({required this.quiz});

  final CustomQuiz quiz;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final l10n = context.l10n;
    final tint = quizStatusTint(quiz.status);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            QuizGlyph(icon: quiz.icon, size: 62, tint: tint),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(quiz.title, style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      SqAvatar(
                        name: quiz.author.name,
                        seed: quiz.author.userId,
                        size: 18,
                        premium: quiz.author.isPremium,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          l10n.quizByAuthor(quiz.author.name),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                      if (quiz.isOwner) ...[
                        const SizedBox(width: 8),
                        SqBadge(
                          label: quizStatusLabel(l10n, quiz.status),
                          color: tint,
                          dense: true,
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        if (quiz.description != null && quiz.description!.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          Text(quiz.description!, style: theme.textTheme.bodyMedium),
        ],
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            _Stat(
              label: l10n.editorQuestionsLabel,
              value: '${quiz.questionCount}',
            ),
            _Stat(
              label: l10n.quizLeaderboardSubtitle,
              value: quiz.playerCount == 0
                  ? '—'
                  : l10n.quizPlayersCount(quiz.playerCount),
            ),
            _Stat(
              label: l10n.score,
              value: quiz.topScore == 0 ? '—' : formatScore(quiz.topScore),
              tint: AppColors.gold,
            ),
          ],
        ),
        if (quiz.myBestScore != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            l10n.quizYourBest(formatScore(quiz.myBestScore!)),
            style: theme.textTheme.labelMedium?.copyWith(color: p.accent),
          ),
        ],
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, this.tint});

  final String label;
  final String value;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(color: tint),
          ),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(color: p.textFaint),
          ),
        ],
      ),
    );
  }
}

class _ShareRow extends StatelessWidget {
  const _ShareRow({
    required this.code,
    required this.onCopy,
    required this.onShare,
  });

  final String code;
  final VoidCallback onCopy;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SqSurface(
      // A Wrap rather than a Row: the code is set at wide tracking so it can be
      // read off a screenshot, and on a narrow phone it plus a labelled button
      // does not fit on one line. Wrapping drops Share underneath instead of
      // squeezing the one string that has to stay legible.
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          QuizCodeChip(code: code, onTap: onCopy),
          SqButton(
            label: l10n.quizShare,
            icon: Icons.ios_share_rounded,
            variant: SqButtonVariant.ghost,
            expand: false,
            height: 44,
            onPressed: onShare,
          ),
        ],
      ),
    );
  }
}

/// Pick which friend to challenge.
class _FriendPicker extends StatelessWidget {
  const _FriendPicker({required this.friends});

  final List<Friend> friends;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.6,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: SqSectionHeader(title: context.l10n.quizChallengeFriend),
          ),
          for (final friend in friends)
            ListTile(
              leading: SqAvatar(
                name: friend.player.label,
                seed: friend.player.userId,
                size: 36,
                premium: friend.player.isPremium,
              ),
              title: Text(friend.player.label),
              subtitle: Text('@${friend.player.username}'),
              trailing: friend.isOnline
                  ? const Icon(
                      Icons.circle,
                      size: 10,
                      color: AppColors.success,
                    )
                  : null,
              onTap: () => Navigator.of(context).pop(friend.player),
            ),
        ],
      ),
    );
  }
}

/// This quiz's own board — every player's best run, best first.
class _Leaderboard extends ConsumerWidget {
  const _Leaderboard({required this.quizId});

  final String quizId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final async = ref.watch(quizLeaderboardProvider(quizId));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SqSectionHeader(
          title: l10n.quizLeaderboardTitle,
          subtitle: l10n.quizLeaderboardSubtitle,
        ),
        const SizedBox(height: AppSpacing.sm),
        async.when(
          loading: () => const SqShimmer(
            child: Column(
              children: [
                SqSkeletonCard(height: 56, lines: 1),
                SizedBox(height: AppSpacing.sm),
                SqSkeletonCard(height: 56, lines: 1),
              ],
            ),
          ),
          error: (error, _) => SqErrorState(
            message: quizErrorMessage(context, error),
            onRetry: () => ref.invalidate(quizLeaderboardProvider(quizId)),
          ),
          data: (board) {
            if (board.entries.isEmpty) {
              return SqSurface(
                child: Text(
                  l10n.quizLeaderboardEmpty,
                  style: theme.textTheme.bodyMedium,
                ),
              );
            }
            return Column(
              children: [
                for (final entry in board.entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _BoardRow(entry: entry),
                  ),
                // Only when the player's own row fell outside the page — a
                // duplicate directly under itself reads as a rendering bug.
                if (board.me != null && !board.meIsListed) ...[
                  const SizedBox(height: 4),
                  _BoardRow(entry: board.me!),
                ],
              ],
            );
          },
        ),
      ],
    );
  }
}

class _BoardRow extends StatelessWidget {
  const _BoardRow({required this.entry});

  final QuizLeaderboardEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final podium = entry.rank <= 3;

    return SqSurface(
      highlighted: entry.isMe,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: 10,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 26,
            child: Text(
              '${entry.rank}',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall?.copyWith(
                color: podium ? AppColors.gold : p.textFaint,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SqAvatar(
            name: entry.name,
            seed: entry.userId,
            size: 32,
            premium: entry.isPremium,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.isMe ? context.l10n.you : entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                Text(
                  '${entry.accuracy.toStringAsFixed(0)}% ${context.l10n.accuracy}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: p.textFaint,
                  ),
                ),
              ],
            ),
          ),
          Text(
            formatScore(entry.bestScore),
            style: theme.textTheme.titleSmall?.copyWith(
              color: entry.isMe ? p.accent : null,
            ),
          ),
        ],
      ),
    );
  }
}
