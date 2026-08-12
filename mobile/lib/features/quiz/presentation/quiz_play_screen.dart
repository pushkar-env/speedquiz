import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:speedquiz/core/feedback/audio_service.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
import 'package:speedquiz/core/i18n/game_labels.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/theme/app_motion.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/auth/presentation/auth_controller.dart';
import 'package:speedquiz/features/custom_topics/data/custom_topics_repository.dart';
import 'package:speedquiz/features/daily/data/daily_repository.dart';
import 'package:speedquiz/features/entitlements/presentation/premium_paywall_sheet.dart';
import 'package:speedquiz/features/leaderboard/data/leaderboard_repository.dart';
import 'package:speedquiz/features/profile/data/profile_repository.dart';
import 'package:speedquiz/features/quiz/domain/quiz_models.dart';
import 'package:speedquiz/features/quiz/domain/speedrun_rules.dart';
import 'package:speedquiz/features/quiz/domain/survival_rules.dart';
import 'package:speedquiz/features/quiz/presentation/quiz_play_controller.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

class QuizPlayScreen extends ConsumerStatefulWidget {
  const QuizPlayScreen({
    super.key,
    required this.topicId,
    required this.mode,
    required this.difficulty,
    this.adaptive = false,
    this.language,
    this.topicName,
    this.existingSession,
  });

  final String topicId;
  final String mode;
  final String difficulty;
  final bool adaptive;

  /// Content language chosen on the setup screen. Null lets the server use the
  /// player's last choice, which is what deep links and the daily do.
  final String? language;

  final String? topicName;
  final QuizSession? existingSession;

  @override
  ConsumerState<QuizPlayScreen> createState() => _QuizPlayScreenState();
}

class _QuizPlayScreenState extends ConsumerState<QuizPlayScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      ref.read(quizPlayControllerProvider.notifier).start(
            topicId: widget.topicId,
            mode: widget.mode,
            difficulty: widget.difficulty,
            adaptive: widget.adaptive,
            language: widget.language,
            existingSession: widget.existingSession,
          );
    });
  }

  /// Leaving mid-run must be deliberate — a stray back swipe should not throw
  /// away a streak. Confirming scores the run rather than discarding it.
  Future<void> _confirmQuit() async {
    if (ref.read(quizPlayControllerProvider) is! QuizPlayActive) return;

    final l10n = context.l10n;
    final quit = await showSqConfirm(
      context,
      title: l10n.playEndRunTitle,
      message: l10n.playEndRunBody,
      confirmLabel: l10n.playEndRunConfirm,
      cancelLabel: l10n.playKeepPlaying,
      tone: SqDialogTone.warning,
      glyph: '🚪',
    );
    if (quit && mounted) {
      await ref.read(quizPlayControllerProvider.notifier).endRun();
    }
  }

  void _onFinished(QuizResult result) {
    // Captured before applyProgress overwrites it, so the results screen can
    // celebrate a level-up.
    final levelBefore = ref.read(currentUserProvider)?.level;

    ref.read(authControllerProvider.notifier).applyProgress(
          level: result.level,
          xp: result.xp,
          coins: result.coins,
          dailyStreak: result.dailyStreak,
          currentStreak: result.currentStreak ?? result.dailyStreak,
        );
    ref.invalidate(dailyChallengeProvider);
    ref.invalidate(leaderboardProvider('weekly'));
    ref.invalidate(leaderboardProvider('daily'));
    ref.invalidate(profileProvider);

    context.go(
      '/quiz/results/${result.sessionId}',
      extra: QuizResultArgs(
        result: result,
        topicId: widget.topicId,
        mode: widget.mode,
        difficulty: widget.difficulty,
        adaptive: widget.adaptive,
        leveledUp: levelBefore != null &&
            result.level != null &&
            result.level! > levelBefore,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(quizPlayControllerProvider);
    final controller = ref.read(quizPlayControllerProvider.notifier);

    ref.listen<QuizPlayState>(quizPlayControllerProvider, (prev, next) {
      if (next is QuizPlayFinished) _onFinished(next.result);
    });

    return PopScope(
      canPop: state is! QuizPlayActive,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmQuit();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SqBackdrop(
          intensity: 0.4,
          child: SafeArea(
            child: switch (state) {
              QuizPlayIdle() || QuizPlayLoading() => _PreparingView(
                  message: context.l10n.playPreparing,
                ),
              QuizPlayCountdown(:final beat) => _CountInView(beat: beat),
              QuizPlayFinished() => _PreparingView(
                  message: context.l10n.playScoringRun,
                ),
              QuizPlayError(:final message, :final failure) => _ErrorView(
                  message: message,
                  failure: failure,
                  language: widget.language,
                  onRetry: () => controller.start(
                    topicId: widget.topicId,
                    mode: widget.mode,
                    difficulty: widget.difficulty,
                    adaptive: widget.adaptive,
                    language: widget.language,
                  ),
                ),
              QuizPlayActive(
                :final session,
                :final feedback,
                :final submitting,
                :final selectedOptionIndex,
                :final tightened,
              ) =>
                _QuestionView(
                  session: session,
                  feedback: feedback,
                  submitting: submitting,
                  selectedOptionIndex: selectedOptionIndex,
                  tightened: tightened,
                  audio: ref.read(audioServiceProvider),
                  remainingMs: controller.remainingMs,
                  runClockMs: controller.runClockMs,
                  topicName: widget.topicName ?? session.topicName,
                  onSelect: (i) => controller.submit(optionIndex: i),
                  onNext: controller.continueAfterFeedback,
                  onEnd: controller.endRun,
                  onQuit: _confirmQuit,
                ),
            },
          ),
        ),
      ),
    );
  }
}

class _PreparingView extends StatelessWidget {
  const _PreparingView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 46,
            height: 46,
            child: CircularProgressIndicator(strokeWidth: 3, color: p.accent),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(message, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            context.l10n.playPreparingHint,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// Speedrun's count-in. The beat is dead time the run needs anyway, so it also
/// carries the three rules that decide whether the player survives.
class _CountInView extends ConsumerStatefulWidget {
  const _CountInView({required this.beat});

  final int beat;

  @override
  ConsumerState<_CountInView> createState() => _CountInViewState();
}

class _CountInViewState extends ConsumerState<_CountInView> {
  @override
  void initState() {
    super.initState();
    _cue();
  }

  @override
  void didUpdateWidget(covariant _CountInView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.beat != widget.beat) _cue();
  }

  void _cue() {
    final audio = ref.read(audioServiceProvider);
    if (widget.beat == 0) {
      Haptics.milestone();
      audio.play(Sfx.streak);
    } else {
      Haptics.tap();
      audio.play(Sfx.tick);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final go = widget.beat == 0;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 132,
              child: AnimatedSwitcher(
                duration: AppMotion.fast,
                switchInCurve: AppMotion.spring,
                transitionBuilder: (child, animation) => ScaleTransition(
                  scale: Tween<double>(begin: 1.6, end: 1).animate(animation),
                  child: FadeTransition(opacity: animation, child: child),
                ),
                child: Text(
                  go ? context.l10n.playGo : '${widget.beat}',
                  key: ValueKey(widget.beat),
                  style: theme.textTheme.displayLarge?.copyWith(
                    fontSize: go ? 88 : 116,
                    color: go ? AppColors.accent : p.textPrimary,
                  ),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              context.l10n.playSpeedrunTitle,
              style: theme.textTheme.labelMedium?.copyWith(
                letterSpacing: 3,
                color: AppColors.gold,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            _RuleLine(glyph: '✅', text: context.l10n.playRuleRight),
            _RuleLine(glyph: '❌', text: context.l10n.playRuleWrong),
            _RuleLine(glyph: '⏱', text: context.l10n.playRuleTighter),
          ],
        ),
      ),
    );
  }
}

class _RuleLine extends StatelessWidget {
  const _RuleLine({required this.glyph, required this.text});

  final String glyph;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(glyph, style: const TextStyle(fontSize: 14)),
          const SizedBox(width: 10),
          Flexible(
            child: Text(text, style: theme.textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({
    required this.message,
    required this.failure,
    required this.onRetry,
    this.language,
  });

  /// The server's own wording, used when the client has nothing better.
  final String message;
  final QuizPlayFailure failure;
  final VoidCallback onRetry;
  final String? language;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final capped = failure == QuizPlayFailure.entitlementCap;
    final languageMissing =
        failure == QuizPlayFailure.contentLanguageUnavailable;
    final nativeName = AppLanguage.fromCode(language).nativeLabel;

    // Prefer copy the client owns; fall back to the server's message only for
    // failures we have no specific words for.
    final (title, body) = switch (failure) {
      QuizPlayFailure.entitlementCap => (
          l10n.playFreeLimitReached,
          l10n.errorUniqueCap,
        ),
      QuizPlayFailure.contentLanguageUnavailable => (
          l10n.languageBankEmpty(nativeName),
          l10n.languageBankEmptyHint(nativeName),
        ),
      QuizPlayFailure.noQuestion => (l10n.playRunInterrupted, l10n.errorNoQuestion),
      QuizPlayFailure.noNextQuestion => (
          l10n.playRunInterrupted,
          l10n.errorNoNextQuestion,
        ),
      QuizPlayFailure.unknown => (l10n.playRunInterrupted, message),
    };

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SqErrorState(
              title: title,
              message: body,
              // Retrying a language the bank cannot serve just fails again;
              // the way out is a different topic or language, back on setup.
              onRetry: capped || languageMissing ? null : onRetry,
            ),
            const SizedBox(height: AppSpacing.md),
            if (capped)
              SqButton(
                label: l10n.playGoPremium,
                variant: SqButtonVariant.gold,
                icon: Icons.workspace_premium_rounded,
                onPressed: () => showPremiumPaywall(
                  context,
                  reason: l10n.playPaywallReason,
                ),
              ),
            if (languageMissing)
              SqButton(
                label: l10n.setupPickATopic,
                icon: Icons.tune_rounded,
                onPressed: () => context.go(Routes.quizSetup),
              ),
            const SizedBox(height: 10),
            SqButton(
              label: l10n.playBackHome,
              variant: SqButtonVariant.ghost,
              onPressed: () => context.go(Routes.home),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuestionView extends StatefulWidget {
  const _QuestionView({
    required this.session,
    required this.submitting,
    required this.remainingMs,
    required this.runClockMs,
    required this.topicName,
    required this.audio,
    required this.onSelect,
    required this.onNext,
    required this.onEnd,
    required this.onQuit,
    this.tightened = false,
    this.feedback,
    this.selectedOptionIndex,
  });

  final QuizSession session;
  final bool submitting;
  final AnswerFeedback? feedback;
  final int? selectedOptionIndex;
  final bool tightened;
  final AudioService audio;
  final ValueListenable<int> remainingMs;
  final ValueListenable<int> runClockMs;
  final String topicName;
  final ValueChanged<int> onSelect;
  final VoidCallback onNext;
  final VoidCallback onEnd;
  final VoidCallback onQuit;

  @override
  State<_QuestionView> createState() => _QuestionViewState();
}

class _QuestionViewState extends State<_QuestionView> {
  /// Bumped on every wrong answer so the option list shakes exactly once.
  int _wrongShakes = 0;

  bool get _answered => widget.feedback != null;
  bool get _isSpeedrun => widget.session.mode == 'speedrun';

  @override
  void didUpdateWidget(covariant _QuestionView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final feedback = widget.feedback;
    if (oldWidget.feedback == null && feedback != null) {
      if (feedback.isCorrect) {
        Haptics.success();
        // A milestone streak gets its own sparkle so momentum is audible.
        widget.audio.play(
          feedback.milestoneBonus > 0 ||
                  (feedback.streak > 0 && feedback.streak % 5 == 0)
              ? Sfx.streak
              : Sfx.correct,
        );
      } else {
        // No setState needed: didUpdateWidget is always followed by build,
        // and SqShakeOnChange fires the error haptic itself.
        _wrongShakes++;
        widget.audio.play(Sfx.wrong);
      }
    }
  }

  _OptionVisualState _optionState(int optionIndex) {
    final feedback = widget.feedback;
    if (feedback == null) {
      if (!widget.submitting) return _OptionVisualState.idle;
      // Commit to the tap the instant it happens. The verdict needs a server
      // round trip, and until this the only thing that changed on screen was a
      // 16px spinner — so the wait read as the app hanging. Dimming the
      // rejected options immediately makes the choice feel taken, which is the
      // part the player is actually waiting to see.
      return widget.selectedOptionIndex == optionIndex
          ? _OptionVisualState.pending
          : _OptionVisualState.dimmed;
    }
    if (optionIndex == feedback.correctOptionIndex) {
      return _OptionVisualState.correct;
    }
    if (widget.selectedOptionIndex == optionIndex && !feedback.isCorrect) {
      return _OptionVisualState.wrong;
    }
    return _OptionVisualState.dimmed;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = widget.session;
    final question = session.currentQuestion;

    if (question == null) {
      return Center(child: Text(context.l10n.errorNoQuestion));
    }

    return Column(
      children: [
        _GameHud(
          session: session,
          feedback: widget.feedback,
          topicName: widget.topicName,
          remainingMs: widget.remainingMs,
          runClockMs: widget.runClockMs,
          timeLimitMs: question.timeLimitMs,
          answered: _answered,
          tightened: widget.tightened,
          audio: widget.audio,
          onQuit: widget.onQuit,
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.md,
              AppSpacing.lg,
              AppSpacing.lg,
            ),
            children: [
              // Keyed so a new question animates in rather than swapping text.
              AnimatedSwitcher(
                duration: AppMotion.normal,
                switchInCurve: AppMotion.enter,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0.06, 0),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: Text(
                  question.prompt,
                  key: ValueKey(question.quizQuestionId),
                  style: theme.textTheme.headlineSmall?.copyWith(height: 1.28),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              SqShakeOnChange(
                trigger: _wrongShakes == 0 ? null : _wrongShakes,
                amplitude: 8,
                haptic: true,
                child: Column(
                  children: [
                    for (var i = 0; i < question.options.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _OptionTile(
                          key: ValueKey(
                            '${question.quizQuestionId}_${question.options[i].index}',
                          ),
                          letter: String.fromCharCode(65 + i),
                          text: question.options[i].text,
                          enabled: !_answered && !widget.submitting,
                          state: _optionState(question.options[i].index),
                          onTap: () =>
                              widget.onSelect(question.options[i].index),
                        ),
                      ),
                  ],
                ),
              ),
              // Speedrun keeps the play surface bare — quitting lives on the
              // HUD, and a stray tap here would cost a run.
              if (!_answered && !_isSpeedrun) ...[
                const SizedBox(height: AppSpacing.sm),
                Center(
                  child: TextButton.icon(
                    onPressed: widget.onQuit,
                    icon: const Icon(Icons.flag_outlined, size: 16),
                    label: Text(context.l10n.playEndRun),
                  ),
                ),
              ],
            ],
          ),
        ),
        // Speedrun has no verdict panel at all: the options carry the answer
        // and the HUD carries the clock, so nothing interrupts the run.
        if (!_isSpeedrun)
          _FeedbackPanel(
            feedback: widget.feedback,
            questionId: question.questionId,
            selectedOptionText: _selectedOptionText(question),
            onNext: widget.onNext,
            onEnd: widget.onEnd,
          ),
      ],
    );
  }

  String? _selectedOptionText(PlayableQuestion question) {
    final index = widget.selectedOptionIndex;
    if (index == null) return null;
    for (final option in question.options) {
      if (option.index == index) return option.text;
    }
    return null;
  }
}

/// Top gameplay bar: quit, mode, score, streak, lives and the timer ring.
///
/// Speedrun swaps the passive time chip for a run clock that owns the top of
/// the screen — in that mode the clock *is* the game state, so it gets the
/// weight normally given to the score.
class _GameHud extends StatelessWidget {
  const _GameHud({
    required this.session,
    required this.topicName,
    required this.remainingMs,
    required this.runClockMs,
    required this.timeLimitMs,
    required this.answered,
    required this.audio,
    required this.onQuit,
    this.tightened = false,
    this.feedback,
  });

  final QuizSession session;
  final String topicName;
  final ValueListenable<int> remainingMs;
  final ValueListenable<int> runClockMs;
  final int timeLimitMs;
  final bool answered;
  final bool tightened;
  final AudioService audio;
  final VoidCallback onQuit;
  final AnswerFeedback? feedback;

  bool get _isSpeedrun => session.mode == 'speedrun';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final score = feedback?.score ?? session.score;
    final streak = feedback?.streak ?? session.streak;
    final lives = feedback?.lives ?? session.lives;
    final budget = feedback?.timeRemainingMs ?? session.timeRemainingMs;
    final overdrive = _isSpeedrun && streak >= SpeedrunRules.overdriveStreak;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.lg,
        0,
      ),
      child: Column(
        children: [
          Row(
            children: [
              SqIconButton(
                icon: Icons.close_rounded,
                tooltip: context.l10n.playEndRun,
                onPressed: onQuit,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      topicName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    Row(
                      children: [
                        // Yields to the ramp cue rather than pushing it off
                        // the edge — the cue is the more urgent of the two.
                        Flexible(
                          child: Text(
                            '${context.l10n.questionNumber(session.questionNumber)} · '
                            '${localizedMode(context, session.mode)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: p.textFaint,
                            ),
                          ),
                        ),
                        if (_isSpeedrun && tightened) ...[
                          const SizedBox(width: 8),
                          const _TightenedFlag(),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              // Only this subtree rebuilds while the clock runs.
              _TimerRing(
                remainingMs: remainingMs,
                timeLimitMs: timeLimitMs,
                frozen: answered,
                audio: audio,
                // Speedrun's per-question ring is the secondary clock; the run
                // clock below owns the audible countdown.
                tick: !_isSpeedrun,
              ),
            ],
          ),
          if (_isSpeedrun) ...[
            const SizedBox(height: AppSpacing.md),
            _RunClock(
              runClockMs: runClockMs,
              timeDeltaMs: feedback?.timeDeltaMs,
              speedTier: feedback?.speedTier,
              answerKey: session.currentQuestion?.quizQuestionId,
              audio: audio,
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              SqPopCounter(
                value: score,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontFamily: 'SpaceGrotesk',
                ),
              ),
              const Spacer(),
              if (lives != null) ...[
                _LivesChip(lives: lives),
                const SizedBox(width: 8),
              ],
              if (budget != null && !_isSpeedrun) ...[
                _HudChip(
                  glyph: '⏱',
                  label: '${(budget / 1000).ceil()}s',
                  tint: AppColors.cyan,
                ),
                const SizedBox(width: 8),
              ],
              if (overdrive)
                _OverdriveChip(streak: streak)
              else
                _HudChip(
                  glyph: '🔥',
                  label: '×$streak',
                  tint: AppColors.gold,
                  emphasised: streak >= 3,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The run clock: a big draining number plus the bar it drains along.
///
/// Rebuilt ~20x/second from the controller's notifier, so it deliberately owns
/// as little of the tree as possible.
class _RunClock extends StatefulWidget {
  const _RunClock({
    required this.runClockMs,
    required this.audio,
    this.timeDeltaMs,
    this.speedTier,
    this.answerKey,
  });

  final ValueListenable<int> runClockMs;
  final AudioService audio;
  final int? timeDeltaMs;
  final String? speedTier;

  /// Identity of the answer being flashed, so the burst replays per answer.
  final String? answerKey;

  @override
  State<_RunClock> createState() => _RunClockState();
}

class _RunClockState extends State<_RunClock> {
  int _lastTickSecond = -1;

  void _maybeTick(int value) {
    if (value > SpeedrunRules.dangerMs || value <= 0) return;
    final second = (value / 1000).ceil();
    if (second == _lastTickSecond) return;
    _lastTickSecond = second;
    widget.audio.play(Sfx.tick);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final delta = widget.timeDeltaMs;

    return ValueListenableBuilder<int>(
      valueListenable: widget.runClockMs,
      builder: (context, value, _) {
        _maybeTick(value);
        final danger = value <= SpeedrunRules.dangerMs;
        final tint = danger ? AppColors.danger : AppColors.cyan;
        final ratio = value / SpeedrunRules.clockCapMs;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                // The burst takes the label's slot rather than a slot of its
                // own: the clock must never be pushed around, and during a
                // flash the delta is the more useful of the two anyway.
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: delta != null && delta != 0
                        ? _TimeDeltaBurst(
                            key: ValueKey('delta_${widget.answerKey}'),
                            deltaMs: delta,
                            speedTier: widget.speedTier,
                          )
                        : Text(
                            context.l10n.playRunClock,
                            style: theme.textTheme.labelSmall?.copyWith(
                              letterSpacing: 1.6,
                              color: tint,
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 10),
                // Tenths make the drain visible: a whole-second clock looks
                // stopped for most of every second.
                Text(
                  (value / 1000).toStringAsFixed(1),
                  style: theme.textTheme.displaySmall?.copyWith(
                    color: danger ? AppColors.danger : theme.sq.textPrimary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 3),
                Text(
                  's',
                  style: theme.textTheme.labelMedium?.copyWith(color: tint),
                ),
              ],
            ),
            const SizedBox(height: 6),
            SqProgressTrack(
              value: ratio,
              height: 7,
              animate: false,
              gradient: danger
                  ? const LinearGradient(
                      colors: [AppColors.danger, Color(0xFFFF8A5C)],
                    )
                  : const LinearGradient(
                      colors: [AppColors.cyan, AppColors.accent],
                    ),
            ),
          ],
        );
      },
    );
  }
}

/// The "+2.4s" / "−3.0s" that fires over the clock when an answer lands. This
/// is the whole reward loop in one glance, so it is loud on purpose.
class _TimeDeltaBurst extends StatefulWidget {
  const _TimeDeltaBurst({super.key, required this.deltaMs, this.speedTier});

  final int deltaMs;
  final String? speedTier;

  @override
  State<_TimeDeltaBurst> createState() => _TimeDeltaBurstState();
}

class _TimeDeltaBurstState extends State<_TimeDeltaBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: SpeedrunRules.flashMs),
  )..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gained = widget.deltaMs > 0;
    final tint = gained ? AppColors.accent : AppColors.danger;
    final seconds = (widget.deltaMs.abs() / 1000).toStringAsFixed(1);
    final tier = gained ? localizedSpeedTier(context, widget.speedTier) : '';

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value;
        // Punch in, hold, then drift up and out.
        final scale = t < 0.25 ? 0.7 + 1.2 * t : 1.0;
        final opacity = t < 0.7 ? 1.0 : (1 - (t - 0.7) / 0.3).clamp(0.0, 1.0);
        return Opacity(
          opacity: opacity,
          child: Transform.translate(
            offset: Offset(0, -14 * (t < 0.7 ? 0 : (t - 0.7) / 0.3)),
            child: Transform.scale(scale: scale, child: child),
          ),
        );
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (tier.isNotEmpty) ...[
            Text(
              tier,
              style: theme.textTheme.labelSmall?.copyWith(
                color: tint,
                letterSpacing: 1.4,
              ),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            '${gained ? '+' : '−'}${seconds}s',
            style: theme.textTheme.titleLarge?.copyWith(
              fontFamily: 'SpaceGrotesk',
              color: tint,
            ),
          ),
        ],
      ),
    );
  }
}

/// Streak is hot. Replaces the streak chip so the change is impossible to miss.
class _OverdriveChip extends StatelessWidget {
  const _OverdriveChip({required this.streak});

  final int streak;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SqBreathe(
      scale: 0.05,
      period: const Duration(milliseconds: 900),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          gradient: AppColors.heatGradient,
          borderRadius: BorderRadius.circular(AppRadii.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SqFlame(size: 12, intensity: 1.6),
            const SizedBox(width: 5),
            Text(
              context.l10n.overdriveMultiplier(streak),
              style: theme.textTheme.labelSmall?.copyWith(
                color: Colors.black87,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.8,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Fires when the question limit steps down, so the ramp is felt rather than
/// merely suffered. Self-retiring — it is a beat, not a status.
class _TightenedFlag extends StatefulWidget {
  const _TightenedFlag();

  @override
  State<_TightenedFlag> createState() => _TightenedFlagState();
}

class _TightenedFlagState extends State<_TightenedFlag>
    with SingleTickerProviderStateMixin {
  /// A controller rather than a delayed callback so leaving the run mid-beat
  /// takes the pending work with it.
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1900),
  )..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    Haptics.milestone();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return FadeTransition(
      // Holds, then fades over the last fifth.
      opacity: CurvedAnimation(
        parent: ReverseAnimation(_controller),
        curve: const Interval(0, 0.2, curve: AppMotion.exit),
      ),
      child: Text(
        '⚡ FASTER',
        style: theme.textTheme.labelSmall?.copyWith(
          color: AppColors.warning,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

/// Survival lives, as pips rather than a number.
///
/// "❤️ 1" and "❤️ 3" look the same at a glance, which wastes the most
/// important state in the mode. Pips make remaining lives readable without
/// reading, and the final life gets a pulsing danger treatment plus the
/// last-stand multiplier — the player should *want* to be there, not just
/// know they are.
class _LivesChip extends StatelessWidget {
  const _LivesChip({required this.lives});

  final int lives;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final lastStand = SurvivalRules.isLastStand(lives);
    final tint = lastStand ? AppColors.danger : AppColors.magenta;

    final chip = AnimatedContainer(
      duration: AppMotion.fast,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: lastStand ? tint.withValues(alpha: 0.20) : p.surface,
        borderRadius: BorderRadius.circular(AppRadii.pill),
        border: Border.all(
          color: lastStand ? tint.withValues(alpha: 0.6) : p.border,
        ),
        boxShadow:
            lastStand ? AppShadows.glow(tint, strength: 0.3) : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < SurvivalRules.maxLives; i++) ...[
            if (i > 0) const SizedBox(width: 3),
            AnimatedScale(
              duration: AppMotion.fast,
              curve: Curves.easeOutBack,
              scale: i < lives ? 1 : 0.7,
              child: Icon(
                i < lives
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                size: 13,
                color: i < lives ? tint : p.textFaint,
              ),
            ),
          ],
          if (lastStand) ...[
            const SizedBox(width: 6),
            Text(
              '×${SurvivalRules.lastStandMultiplier}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: tint,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ],
      ),
    );

    // Only the brink breathes — a chip that always pulses stops meaning
    // anything.
    return lastStand ? SqBreathe(scale: 0.05, child: chip) : chip;
  }
}

class _HudChip extends StatelessWidget {
  const _HudChip({
    required this.glyph,
    required this.label,
    required this.tint,
    this.emphasised = false,
  });

  final String glyph;
  final String label;
  final Color tint;
  final bool emphasised;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return AnimatedContainer(
      duration: AppMotion.fast,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: emphasised ? tint.withValues(alpha: 0.18) : p.surface,
        borderRadius: BorderRadius.circular(AppRadii.pill),
        border: Border.all(
          color: emphasised ? tint.withValues(alpha: 0.5) : p.border,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(glyph, style: const TextStyle(fontSize: 12)),
          const SizedBox(width: 5),
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: emphasised ? tint : p.textPrimary,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

/// Circular countdown. Listens to the controller's notifier directly so the
/// rest of the question tree stays still between ticks.
class _TimerRing extends StatefulWidget {
  const _TimerRing({
    required this.remainingMs,
    required this.timeLimitMs,
    required this.frozen,
    required this.audio,
    this.tick = true,
  });

  final ValueListenable<int> remainingMs;
  final int timeLimitMs;
  final bool frozen;
  final AudioService audio;

  /// Whether this ring owns the audible countdown. Off in speedrun, where the
  /// run clock does it — two clocks ticking at once is just noise.
  final bool tick;

  @override
  State<_TimerRing> createState() => _TimerRingState();
}

class _TimerRingState extends State<_TimerRing> {
  /// Last whole second we ticked on, so the cue fires once per second rather
  /// than on every one of the ten frames that second contains.
  int _lastTickSecond = -1;

  void _maybeTick(int seconds, bool low) {
    if (!widget.tick || widget.frozen || !low || seconds <= 0 || seconds > 3) {
      return;
    }
    if (seconds == _lastTickSecond) return;
    _lastTickSecond = seconds;
    widget.audio.play(Sfx.tick);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ValueListenableBuilder<int>(
      valueListenable: widget.remainingMs,
      builder: (context, value, _) {
        final timeLimitMs = widget.timeLimitMs;
        final frozen = widget.frozen;
        final ratio = timeLimitMs == 0 ? 0.0 : value / timeLimitMs;
        final low = !frozen && ratio <= 0.25;
        final seconds = (value / 1000).ceil();
        _maybeTick(seconds, low);

        return SqProgressRing(
          value: frozen ? 0 : ratio,
          size: 56,
          stroke: 5,
          glow: low,
          gradient: low
              ? const LinearGradient(
                  colors: [AppColors.danger, Color(0xFFFF8A5C)],
                )
              : AppColors.brandGradient,
          child: Text(
            frozen ? '–' : '$seconds',
            style: theme.textTheme.titleMedium?.copyWith(
              fontFamily: 'SpaceGrotesk',
              fontWeight: FontWeight.w700,
              color: low ? AppColors.danger : theme.sq.textPrimary,
            ),
          ),
        );
      },
    );
  }
}

enum _OptionVisualState { idle, pending, correct, wrong, dimmed }

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    super.key,
    required this.letter,
    required this.text,
    required this.enabled,
    required this.state,
    required this.onTap,
  });

  final String letter;
  final String text;
  final bool enabled;
  final _OptionVisualState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    late final Color border;
    late final Color background;
    late final Color badge;
    var badgeFilled = false;

    switch (state) {
      case _OptionVisualState.correct:
        border = AppColors.success;
        background = AppColors.success.withValues(alpha: p.isDark ? 0.16 : 0.1);
        badge = AppColors.success;
        badgeFilled = true;
      case _OptionVisualState.wrong:
        border = AppColors.danger;
        background = AppColors.danger.withValues(alpha: p.isDark ? 0.16 : 0.1);
        badge = AppColors.danger;
        badgeFilled = true;
      case _OptionVisualState.dimmed:
        border = p.border;
        background = p.surface.withValues(alpha: 0.4);
        badge = p.textFaint;
      case _OptionVisualState.pending:
        border = p.accent;
        background = p.accentWash(0.1);
        badge = p.accent;
      case _OptionVisualState.idle:
        border = p.border;
        background = p.surface;
        badge = p.accent;
    }

    final dim = state == _OptionVisualState.dimmed;
    final decided = state == _OptionVisualState.correct ||
        state == _OptionVisualState.wrong;

    return AnimatedOpacity(
      duration: AppMotion.fast,
      opacity: dim ? 0.45 : 1,
      // Correct/wrong answers pop slightly so the eye lands on them.
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 1, end: decided ? 1.015 : 1),
        duration: AppMotion.fast,
        curve: AppMotion.spring,
        builder: (context, scale, child) =>
            Transform.scale(scale: scale, child: child),
        child: SqPressable(
          onTap: enabled ? onTap : null,
          enabled: enabled,
          pressedScale: 0.975,
          child: AnimatedContainer(
            duration: AppMotion.fast,
            curve: AppMotion.standard,
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(AppRadii.md),
              border: Border.all(color: border, width: decided ? 1.8 : 1),
              boxShadow: decided
                  ? AppShadows.glow(border, strength: 0.18)
                  : null,
            ),
            child: Row(
              children: [
                AnimatedContainer(
                  duration: AppMotion.fast,
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: badgeFilled
                        ? badge
                        : badge.withValues(alpha: 0.16),
                  ),
                  child: Text(
                    letter,
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontFamily: 'SpaceGrotesk',
                      color: badgeFilled ? Colors.white : badge,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(text, style: theme.textTheme.titleSmall),
                ),
                if (state == _OptionVisualState.correct)
                  const Icon(
                    Icons.check_circle_rounded,
                    color: AppColors.success,
                    size: 20,
                  )
                else if (state == _OptionVisualState.wrong)
                  const Icon(
                    Icons.cancel_rounded,
                    color: AppColors.danger,
                    size: 20,
                  )
                else if (state == _OptionVisualState.pending)
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: p.accent,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Bottom panel that slides in with the verdict, the explanation and the
/// action that moves the run forward.
///
/// Not used by speedrun: there, a panel is the thing that would kill the pace.
class _FeedbackPanel extends StatelessWidget {
  const _FeedbackPanel({
    required this.feedback,
    required this.questionId,
    required this.onNext,
    required this.onEnd,
    this.selectedOptionText,
  });

  final AnswerFeedback? feedback;
  final String questionId;
  final String? selectedOptionText;
  final VoidCallback onNext;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: AppMotion.normal,
      switchInCurve: AppMotion.emphasized,
      switchOutCurve: AppMotion.exit,
      transitionBuilder: (child, animation) => SizeTransition(
        sizeFactor: animation,
        alignment: Alignment.topCenter,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.25),
            end: Offset.zero,
          ).animate(animation),
          child: FadeTransition(opacity: animation, child: child),
        ),
      ),
      child: feedback == null
          ? const SizedBox.shrink(key: ValueKey('empty'))
          : _FeedbackBody(
              key: ValueKey('feedback_$questionId'),
              feedback: feedback!,
              questionId: questionId,
              selectedOptionText: selectedOptionText,
              onNext: onNext,
              onEnd: onEnd,
            ),
    );
  }
}

class _FeedbackBody extends StatefulWidget {
  const _FeedbackBody({
    super.key,
    required this.feedback,
    required this.questionId,
    required this.onNext,
    required this.onEnd,
    this.selectedOptionText,
  });

  final AnswerFeedback feedback;
  final String questionId;
  final String? selectedOptionText;
  final VoidCallback onNext;
  final VoidCallback onEnd;

  @override
  State<_FeedbackBody> createState() => _FeedbackBodyState();
}

class _FeedbackBodyState extends State<_FeedbackBody> {
  final _scrollController = ScrollController();

  bool _loadingTeach = false;
  TeachMeResult? _teach;
  String? _teachError;
  bool _expanded = false;

  bool get _canTeach => !widget.feedback.isCorrect;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Bring freshly expanded content into view; otherwise it unfolds below the
  /// fold and reads as if the action bar is covering it.
  void _revealBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: AppMotion.normal,
        curve: AppMotion.enter,
      );
    });
  }

  Future<void> _loadTeach(WidgetRef ref) async {
    if (_loadingTeach || _teach != null) return;
    setState(() {
      _loadingTeach = true;
      _teachError = null;
    });
    try {
      final result = await ref.read(customTopicsRepositoryProvider).teachMe(
            questionId: widget.questionId,
            userOptionText: widget.selectedOptionText,
          );
      if (!mounted) return;
      setState(() {
        _teach = result;
        _loadingTeach = false;
        _expanded = true;
      });
      _revealBottom();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingTeach = false;
        _teachError = context.l10n.playTeachError;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final feedback = widget.feedback;
    final correct = feedback.isCorrect;
    final tint = correct ? AppColors.success : AppColors.danger;

    return Container(
      width: double.infinity,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.62,
      ),
      decoration: BoxDecoration(
        color: p.surfaceElevated,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadii.lg),
        ),
        border: Border(
          top: BorderSide(color: tint.withValues(alpha: 0.45), width: 1.5),
          left: BorderSide(color: p.border),
          right: BorderSide(color: p.border),
        ),
        boxShadow: AppShadows.lifted(p),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: SingleChildScrollView(
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.md,
                  AppSpacing.lg,
                  AppSpacing.md,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          correct
                              ? Icons.check_circle_rounded
                              : Icons.cancel_rounded,
                          color: tint,
                          size: 22,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          correct ? context.l10n.playCorrect : context.l10n.playNotQuite,
                          style: theme.textTheme.titleLarge?.copyWith(
                            color: tint,
                          ),
                        ),
                        const Spacer(),
                        if (correct)
                          SqAnimatedCounter(
                            value: feedback.pointsAwarded,
                            prefix: '+',
                            duration: AppMotion.normal,
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontFamily: 'SpaceGrotesk',
                              color: tint,
                            ),
                          ),
                      ],
                    ),
                    if (correct &&
                        (feedback.speedBonus > 0 ||
                            feedback.streakMultiplier > 1)) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          if (feedback.speedBonus > 0)
                            SqBadge(
                              label: '+${feedback.speedBonus} SPEED',
                              color: AppColors.gold,
                              icon: Icons.bolt_rounded,
                              dense: true,
                            ),
                          if (feedback.streakMultiplier > 1)
                            SqBadge(
                              label: '×'
                                  '${feedback.streakMultiplier.toStringAsFixed(2)}'
                                  ' STREAK',
                              color: AppColors.warning,
                              dense: true,
                            ),
                        ],
                      ),
                    ],
                    if (!correct) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.success.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(AppRadii.sm),
                          border: Border.all(
                            color: AppColors.success.withValues(alpha: 0.3),
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('✓', style: TextStyle(fontSize: 14)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                feedback.correctOptionText,
                                style: theme.textTheme.titleSmall,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      context.l10n.playWhy,
                      style: theme.textTheme.labelSmall?.copyWith(
                        letterSpacing: 1.4,
                        color: p.textFaint,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      feedback.explanation,
                      style: theme.textTheme.bodyLarge,
                    ),
                    if (_canTeach) ...[
                      const SizedBox(height: AppSpacing.md),
                      Consumer(
                        builder: (context, ref, _) {
                          if (_teach != null) {
                            return _TeachMePanel(
                              result: _teach!,
                              expanded: _expanded,
                              onToggle: () {
                                setState(() => _expanded = !_expanded);
                                if (_expanded) _revealBottom();
                              },
                            );
                          }
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              SqButton(
                                label: _loadingTeach
                                    ? context.l10n.playTeaching
                                    : context.l10n.playTeachMeThis,
                                icon: Icons.school_rounded,
                                variant: SqButtonVariant.subtle,
                                height: 46,
                                loading: _loadingTeach,
                                onPressed: () => _loadTeach(ref),
                              ),
                              if (_teachError != null) ...[
                                const SizedBox(height: 8),
                                Text(
                                  _teachError!,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: AppColors.danger,
                                  ),
                                ),
                              ],
                            ],
                          );
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ),
            // Hairline separating the scrollable explanation from the action
            // bar, so long content reads as "scrolls under" rather than
            // "hidden behind the button".
            Divider(height: 1, thickness: 1, color: p.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.md,
                AppSpacing.lg,
                AppSpacing.md,
              ),
              child: Column(
                children: [
                  SqButton(
                    label: feedback.runEnded ? context.l10n.playSeeResults : context.l10n.playNext,
                    icon: feedback.runEnded
                        ? Icons.emoji_events_rounded
                        : Icons.arrow_forward_rounded,
                    onPressed:
                        feedback.runEnded ? widget.onEnd : widget.onNext,
                  ),
                  if (!feedback.runEnded)
                    TextButton(
                      onPressed: widget.onEnd,
                      child: Text(context.l10n.playEndRun),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TeachMePanel extends StatelessWidget {
  const _TeachMePanel({
    required this.result,
    required this.expanded,
    required this.onToggle,
  });

  final TeachMeResult result;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return SqSurface(
      accent: AppColors.violet,
      highlighted: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SqPressable(
            onTap: onToggle,
            pressedScale: 0.99,
            child: Row(
              children: [
                const Icon(
                  Icons.school_rounded,
                  size: 16,
                  color: AppColors.violet,
                ),
                const SizedBox(width: 8),
                Text(
                  context.l10n.playTeachMe,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: AppColors.violet,
                    letterSpacing: 1.2,
                  ),
                ),
                const Spacer(),
                AnimatedRotation(
                  turns: expanded ? 0.5 : 0,
                  duration: AppMotion.fast,
                  child: Icon(
                    Icons.expand_more_rounded,
                    size: 18,
                    color: p.textFaint,
                  ),
                ),
              ],
            ),
          ),
          AnimatedSize(
            duration: AppMotion.normal,
            curve: AppMotion.enter,
            alignment: Alignment.topCenter,
            child: expanded
                ? Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _TeachBlock(
                          title: context.l10n.teachWhyCorrect,
                          body: result.whyCorrect,
                        ),
                        _TeachBlock(
                          title: context.l10n.teachWhyWrong,
                          body: result.whyWrong,
                        ),
                        _TeachBlock(
                          title: context.l10n.teachKeyConcept,
                          body: result.keyConcept,
                        ),
                        _TeachBlock(
                          title: context.l10n.teachRemember,
                          body: result.memorableFact,
                        ),
                      ],
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

class _TeachBlock extends StatelessWidget {
  const _TeachBlock({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 2),
          Text(body, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}
