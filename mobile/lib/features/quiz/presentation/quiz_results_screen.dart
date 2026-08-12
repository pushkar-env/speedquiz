import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import 'package:speedquiz/core/feedback/audio_service.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
import 'package:speedquiz/core/i18n/game_labels.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/theme/app_motion.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/quiz/domain/quiz_models.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// `92300` -> `1:32`. Runs are minutes long at most, so no hours case.
String _formatDuration(int ms) {
  final total = (ms / 1000).round();
  final minutes = total ~/ 60;
  final seconds = total % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

class QuizResultsScreen extends ConsumerStatefulWidget {
  const QuizResultsScreen({super.key, required this.args});

  final QuizResultArgs args;

  QuizResult get result => args.result;

  @override
  ConsumerState<QuizResultsScreen> createState() => _QuizResultsScreenState();
}

class _QuizResultsScreenState extends ConsumerState<QuizResultsScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  );

  late final Animation<double> _scoreScale = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.1, 0.75, curve: AppMotion.spring),
  );

  bool _celebrate = false;
  bool _sharing = false;

  /// A run worth celebrating: a personal best, a level-up, or an unlock.
  bool get _isCelebration =>
      widget.result.isPersonalBest ||
      widget.args.leveledUp ||
      widget.result.newAchievements.isNotEmpty;

  /// Restart the same topic and mode without a detour through setup — the
  /// single biggest thing that keeps a session going.
  void _playAgain() {
    final args = widget.args;
    if (!args.canReplay) {
      context.go(Routes.quizSetup);
      return;
    }
    context.pushReplacement(
      Routes.quizPlay,
      extra: {
        'topicId': args.topicId,
        'topicName': widget.result.topicName,
        'mode': args.mode ?? widget.result.mode,
        'difficulty': args.difficulty ?? widget.result.difficulty,
        'adaptive': args.adaptive,
        // Replay the run you just played, in the language you played it in.
        'language': widget.result.language,
      },
    );
  }

  @override
  void initState() {
    super.initState();
    _controller.forward();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final audio = ref.read(audioServiceProvider);
      if (!_isCelebration) {
        audio.play(Sfx.finish);
        return;
      }
      setState(() => _celebrate = true);
      Haptics.milestone();
      audio.play(Sfx.unlock);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _shareResult() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    final result = widget.result;
    final l10n = context.l10n;
    // The server builds the share card in the *run's* language; this fallback
    // only runs when it sent nothing, and follows the reader instead.
    final text = result.shareText.isNotEmpty
        ? result.shareText
        : 'SPEEDQUIZ\n\n${result.topicName}\n'
              '${l10n.score}: ${formatScore(result.finalScore)}\n'
              '${l10n.accuracy}: ${result.accuracy.toStringAsFixed(0)}%\n'
              '${l10n.bestStreak}: ${result.bestStreak}';
    try {
      await SharePlus.instance.share(ShareParams(text: text));
    } catch (_) {
      if (mounted) SqToast.error(context, l10n.resultsShareFailed);
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final l10n = context.l10n;
    final result = widget.result;
    final unlocks = result.newAchievements;
    final avgSeconds = (result.averageAnswerMs / 1000).toStringAsFixed(1);
    final isSpeedrun = result.mode == 'speedrun';

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SqBackdrop(
        intensity: _isCelebration ? 1 : 0.5,
        colors: _isCelebration
            ? const [AppColors.gold, AppColors.accent, AppColors.magenta]
            : null,
        child: Stack(
          children: [
            SafeArea(
              child: Column(
                children: [
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.lg,
                        AppSpacing.lg,
                        AppSpacing.lg,
                        AppSpacing.md,
                      ),
                      children: [
                        SqStagger(
                          child: Center(
                            child: SqBadge(
                              label: result.isPersonalBest
                                  ? l10n.resultsNewPersonalBest
                                  : l10n.resultsRunComplete,
                              gradient: result.isPersonalBest
                                  ? AppColors.premiumGradient
                                  : null,
                              icon: result.isPersonalBest
                                  ? Icons.emoji_events_rounded
                                  : Icons.flag_rounded,
                            ),
                          ),
                        ),
                        if (widget.args.leveledUp) ...[
                          const SizedBox(height: AppSpacing.md),
                          SqStagger(
                            index: 1,
                            child: _LevelUpBanner(level: result.level ?? 1),
                          ),
                        ],
                        const SizedBox(height: AppSpacing.lg),
                        ScaleTransition(
                          scale: Tween<double>(
                            begin: 0.7,
                            end: 1,
                          ).animate(_scoreScale),
                          child: Center(
                            child: SqAnimatedCounter(
                              value: result.finalScore,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.displayLarge?.copyWith(
                                fontSize: 62,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Center(
                          child: Text(
                            '${result.topicName} · '
                            '${localizedDifficulty(context, result.difficulty)} · '
                            '${localizedMode(context, result.mode)}',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                        if (!result.isPersonalBest &&
                            result.previousBest > 0) ...[
                          const SizedBox(height: 6),
                          Center(
                            child: Text(
                              l10n.personalBestValue(
                                formatScore(result.previousBest),
                              ),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: p.textFaint,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: AppSpacing.xl),
                        SqStagger(
                          index: 1,
                          child: Row(
                            children: [
                              Expanded(
                                child: _StatTile(
                                  glyph: '🎯',
                                  label: l10n.accuracy,
                                  value:
                                      '${result.accuracy.toStringAsFixed(0)}%',
                                  tint: AppColors.accent,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: _StatTile(
                                  glyph: '🔥',
                                  label: l10n.bestStreak,
                                  value: '${result.bestStreak}',
                                  tint: AppColors.gold,
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
                                child: _StatTile(
                                  glyph: '⚡',
                                  label: l10n.resultsAvgAnswer,
                                  value: '${avgSeconds}s',
                                  tint: AppColors.cyan,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                // How long you lasted is the whole point of a
                                // speedrun; every other mode is counting
                                // questions.
                                child: isSpeedrun && result.durationMs > 0
                                    ? _StatTile(
                                        glyph: '⏱',
                                        label: l10n.resultsSurvived,
                                        value:
                                            _formatDuration(result.durationMs),
                                        tint: AppColors.violet,
                                      )
                                    : _StatTile(
                                        glyph: '📘',
                                        label: l10n.resultsQuestions,
                                        value: '${result.questionsAnswered}',
                                        tint: AppColors.violet,
                                      ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: AppSpacing.md),
                        SqStagger(
                          index: 3,
                          child: _XpCard(
                            xpEarned: result.xpEarned,
                            level: result.level,
                            xp: result.xp,
                          ),
                        ),
                        if (unlocks.isNotEmpty) ...[
                          const SizedBox(height: AppSpacing.xl),
                          SqStagger(
                            index: 4,
                            child: SqSectionHeader(
                              title: l10n.resultsUnlocked,
                              subtitle: unlocks.length == 1
                                  ? l10n.resultsOneAchievement
                                  : l10n.achievementsUnlockedCount(
                                      unlocks.length,
                                    ),
                            ),
                          ),
                          const SizedBox(height: AppSpacing.md),
                          for (var i = 0; i < unlocks.length; i++)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: SqStagger(
                                index: 5 + i,
                                child: _UnlockCard(achievement: unlocks[i]),
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg,
                      0,
                      AppSpacing.lg,
                      AppSpacing.sm,
                    ),
                    child: Column(
                      children: [
                        SqButton(
                          label: widget.args.canReplay
                              ? l10n.resultsPlayAgain
                              : l10n.resultsNewRun,
                          icon: Icons.replay_rounded,
                          onPressed: _playAgain,
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            if (widget.args.canReplay) ...[
                              Expanded(
                                child: SqButton(
                                  label: l10n.resultsNewRun,
                                  icon: Icons.tune_rounded,
                                  variant: SqButtonVariant.ghost,
                                  onPressed: () => context.go(Routes.quizSetup),
                                ),
                              ),
                              const SizedBox(width: 10),
                            ],
                            Expanded(
                              child: SqButton(
                                label: l10n.resultsShare,
                                icon: Icons.ios_share_rounded,
                                variant: SqButtonVariant.ghost,
                                loading: _sharing,
                                onPressed: _shareResult,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: SqButton(
                                label: l10n.resultsHome,
                                icon: Icons.home_rounded,
                                variant: SqButtonVariant.ghost,
                                onPressed: () => context.go(Routes.home),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (_isCelebration)
              Positioned.fill(child: SqConfetti(play: _celebrate)),
          ],
        ),
      ),
    );
  }
}

/// Level-up callout. Rare enough to earn its own gold treatment.
class _LevelUpBanner extends StatelessWidget {
  const _LevelUpBanner({required this.level});

  final int level;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SqGlowBorder(
      radius: AppRadii.md,
      thickness: 1.4,
      glow: 0.32,
      period: const Duration(seconds: 4),
      colors: const [
        AppColors.gold,
        Color(0xFFFFF0C2),
        AppColors.warning,
        AppColors.gold,
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              AppColors.gold.withValues(alpha: 0.26),
              AppColors.warning.withValues(alpha: 0.10),
            ],
          ),
          borderRadius: BorderRadius.circular(AppRadii.md),
          boxShadow: AppShadows.glow(AppColors.gold, strength: 0.22),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('🎉', style: TextStyle(fontSize: 18)),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                context.l10n.levelUpTo(level),
                textAlign: TextAlign.center,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: AppColors.gold,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.glyph,
    required this.label,
    required this.value,
    required this.tint,
  });

  final String glyph;
  final String label;
  final String value;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(glyph, style: const TextStyle(fontSize: 15)),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: p.textFaint,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: theme.textTheme.headlineSmall?.copyWith(color: tint),
          ),
        ],
      ),
    );
  }
}

class _XpCard extends StatelessWidget {
  const _XpCard({required this.xpEarned, this.level, this.xp});

  final int xpEarned;
  final int? level;
  final int? xp;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final currentLevel = level ?? 1;
    final currentXp = xp ?? 0;
    final threshold = xpThresholdForLevel(currentLevel);
    final progress = threshold <= 0
        ? 0.0
        : (currentXp / threshold).clamp(0.0, 1.0);

    return SqSurface(
      padding: const EdgeInsets.all(AppSpacing.lg),
      highlighted: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SqAnimatedCounter(
                value: xpEarned,
                prefix: '+',
                suffix: ' XP',
                grouped: false,
                style: theme.textTheme.headlineSmall?.copyWith(color: p.accent),
              ),
              const Spacer(),
              SqBadge(label: context.l10n.levelBadge(currentLevel)),
            ],
          ),
          if (level != null) ...[
            const SizedBox(height: AppSpacing.md),
            SqProgressTrack(value: progress, height: 8),
            const SizedBox(height: 6),
            Text(
              '$currentXp / $threshold XP to level ${currentLevel + 1}',
              style: theme.textTheme.labelSmall?.copyWith(color: p.textFaint),
            ),
          ],
        ],
      ),
    );
  }
}

class _UnlockCard extends StatelessWidget {
  const _UnlockCard({required this.achievement});

  final AchievementUnlock achievement;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final rewards = [
      if (achievement.xpReward > 0) '+${achievement.xpReward} XP',
      if (achievement.coinsReward > 0) '+${achievement.coinsReward} coins',
    ].join(' · ');

    return SqSurface(
      accent: AppColors.gold,
      highlighted: true,
      glow: true,
      child: Row(
        children: [
          SqBreathe(
            scale: 0.05,
            period: const Duration(milliseconds: 2200),
            child: Container(
              width: 46,
              height: 46,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: AppColors.premiumGradient,
              ),
              child: Text(
                achievementGlyph(achievement.icon),
                style: const TextStyle(fontSize: 20),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(achievement.name, style: theme.textTheme.titleSmall),
                const SizedBox(height: 1),
                Text(achievement.description, style: theme.textTheme.bodySmall),
                if (rewards.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    rewards,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: AppColors.gold,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Icon(Icons.auto_awesome_rounded, color: p.accent, size: 18),
        ],
      ),
    );
  }
}
