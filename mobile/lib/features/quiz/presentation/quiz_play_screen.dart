import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:speedquiz/core/feedback/audio_service.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
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
import 'package:speedquiz/features/quiz/presentation/quiz_play_controller.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

class QuizPlayScreen extends ConsumerStatefulWidget {
  const QuizPlayScreen({
    super.key,
    required this.topicId,
    required this.mode,
    required this.difficulty,
    this.adaptive = false,
    this.topicName,
    this.existingSession,
  });

  final String topicId;
  final String mode;
  final String difficulty;
  final bool adaptive;
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
            existingSession: widget.existingSession,
          );
    });
  }

  /// Leaving mid-run must be deliberate — a stray back swipe should not throw
  /// away a streak. Confirming scores the run rather than discarding it.
  Future<void> _confirmQuit() async {
    if (ref.read(quizPlayControllerProvider) is! QuizPlayActive) return;

    final quit = await showSqConfirm(
      context,
      title: 'End this run?',
      message: 'Your score so far is banked and the run is scored now. '
          'You cannot resume it afterwards.',
      confirmLabel: 'END RUN',
      cancelLabel: 'KEEP PLAYING',
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
              QuizPlayIdle() || QuizPlayLoading() => const _PreparingView(),
              QuizPlayFinished() => const _PreparingView(
                  message: 'Scoring your run…',
                ),
              QuizPlayError(:final message, :final isEntitlementCap) =>
                _ErrorView(
                  message: message,
                  isEntitlementCap: isEntitlementCap,
                  onRetry: () => controller.start(
                    topicId: widget.topicId,
                    mode: widget.mode,
                    difficulty: widget.difficulty,
                    adaptive: widget.adaptive,
                  ),
                ),
              QuizPlayActive(
                :final session,
                :final feedback,
                :final submitting,
                :final selectedOptionIndex,
              ) =>
                _QuestionView(
                  session: session,
                  feedback: feedback,
                  submitting: submitting,
                  selectedOptionIndex: selectedOptionIndex,
                  audio: ref.read(audioServiceProvider),
                  remainingMs: controller.remainingMs,
                  autoAdvanceMs: controller.autoAdvanceMs,
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
  const _PreparingView({this.message = 'Preparing your challenge…'});

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
            'Questions are served from the bank, not generated live.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({
    required this.message,
    required this.isEntitlementCap,
    required this.onRetry,
  });

  final String message;
  final bool isEntitlementCap;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SqErrorState(
              title: isEntitlementCap ? 'Free limit reached' : 'Run interrupted',
              message: message,
              onRetry: isEntitlementCap ? null : onRetry,
            ),
            const SizedBox(height: AppSpacing.md),
            if (isEntitlementCap)
              SqButton(
                label: 'GO PREMIUM',
                variant: SqButtonVariant.gold,
                icon: Icons.workspace_premium_rounded,
                onPressed: () => showPremiumPaywall(
                  context,
                  reason: 'You hit the free unique-question limit '
                      'for this topic.',
                ),
              ),
            const SizedBox(height: 10),
            SqButton(
              label: 'BACK HOME',
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
    required this.autoAdvanceMs,
    required this.topicName,
    required this.audio,
    required this.onSelect,
    required this.onNext,
    required this.onEnd,
    required this.onQuit,
    this.feedback,
    this.selectedOptionIndex,
  });

  final QuizSession session;
  final bool submitting;
  final AnswerFeedback? feedback;
  final int? selectedOptionIndex;
  final AudioService audio;
  final ValueListenable<int> remainingMs;
  final ValueListenable<int?> autoAdvanceMs;
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
          feedback.streak > 0 && feedback.streak % 5 == 0
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
      return widget.selectedOptionIndex == optionIndex && widget.submitting
          ? _OptionVisualState.pending
          : _OptionVisualState.idle;
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
      return const Center(child: Text('No question available.'));
    }

    return Column(
      children: [
        _GameHud(
          session: session,
          feedback: widget.feedback,
          topicName: widget.topicName,
          remainingMs: widget.remainingMs,
          timeLimitMs: question.timeLimitMs,
          answered: _answered,
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
              if (!_answered) ...[
                const SizedBox(height: AppSpacing.sm),
                Center(
                  child: TextButton.icon(
                    onPressed: widget.onQuit,
                    icon: const Icon(Icons.flag_outlined, size: 16),
                    label: const Text('End run'),
                  ),
                ),
              ],
            ],
          ),
        ),
        _FeedbackPanel(
          feedback: widget.feedback,
          questionId: question.questionId,
          selectedOptionText: _selectedOptionText(question),
          isSpeedrun: _isSpeedrun,
          autoAdvanceMs: widget.autoAdvanceMs,
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
class _GameHud extends StatelessWidget {
  const _GameHud({
    required this.session,
    required this.topicName,
    required this.remainingMs,
    required this.timeLimitMs,
    required this.answered,
    required this.audio,
    required this.onQuit,
    this.feedback,
  });

  final QuizSession session;
  final String topicName;
  final ValueListenable<int> remainingMs;
  final int timeLimitMs;
  final bool answered;
  final AudioService audio;
  final VoidCallback onQuit;
  final AnswerFeedback? feedback;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final score = feedback?.score ?? session.score;
    final streak = feedback?.streak ?? session.streak;
    final lives = feedback?.lives ?? session.lives;
    final budget = feedback?.timeRemainingMs ?? session.timeRemainingMs;

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
                tooltip: 'End run',
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
                    Text(
                      'Q${session.questionNumber} · '
                      '${humanizeMode(session.mode)}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: p.textFaint,
                      ),
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
              ),
            ],
          ),
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
                _HudChip(
                  glyph: '❤️',
                  label: '$lives',
                  tint: AppColors.danger,
                ),
                const SizedBox(width: 8),
              ],
              if (budget != null) ...[
                _HudChip(
                  glyph: '⏱',
                  label: '${(budget / 1000).ceil()}s',
                  tint: AppColors.cyan,
                ),
                const SizedBox(width: 8),
              ],
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
  });

  final ValueListenable<int> remainingMs;
  final int timeLimitMs;
  final bool frozen;
  final AudioService audio;

  @override
  State<_TimerRing> createState() => _TimerRingState();
}

class _TimerRingState extends State<_TimerRing> {
  /// Last whole second we ticked on, so the cue fires once per second rather
  /// than on every one of the ten frames that second contains.
  int _lastTickSecond = -1;

  void _maybeTick(int seconds, bool low) {
    if (widget.frozen || !low || seconds <= 0 || seconds > 3) return;
    if (seconds == _lastTickSecond) return;
    _lastTickSecond = seconds;
    widget.audio.play(Sfx.tick, volume: 0.6);
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
class _FeedbackPanel extends StatelessWidget {
  const _FeedbackPanel({
    required this.feedback,
    required this.questionId,
    required this.isSpeedrun,
    required this.autoAdvanceMs,
    required this.onNext,
    required this.onEnd,
    this.selectedOptionText,
  });

  final AnswerFeedback? feedback;
  final String questionId;
  final String? selectedOptionText;
  final bool isSpeedrun;
  final ValueListenable<int?> autoAdvanceMs;
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
              isSpeedrun: isSpeedrun,
              autoAdvanceMs: autoAdvanceMs,
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
    required this.isSpeedrun,
    required this.autoAdvanceMs,
    required this.onNext,
    required this.onEnd,
    this.selectedOptionText,
  });

  final AnswerFeedback feedback;
  final String questionId;
  final String? selectedOptionText;
  final bool isSpeedrun;
  final ValueListenable<int?> autoAdvanceMs;
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

  /// Teach Me is a "sit and read" affordance. Speedrun auto-advances in three
  /// seconds, so offering it there only baits a tap that gets cut off.
  bool get _canTeach => !widget.isSpeedrun && !widget.feedback.isCorrect;

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
        _teachError = 'Could not load a deeper explanation right now.';
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
                          correct ? 'Correct' : 'Not quite',
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
                      'WHY',
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
                                    ? 'TEACHING…'
                                    : 'TEACH ME THIS',
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
              child: widget.isSpeedrun
                  ? _AutoAdvanceBar(
                      autoAdvanceMs: widget.autoAdvanceMs,
                      label: feedback.runEnded
                          ? 'Results in'
                          : 'Next question in',
                    )
                  : Column(
                      children: [
                        SqButton(
                          label: feedback.runEnded ? 'SEE RESULTS' : 'NEXT',
                          icon: feedback.runEnded
                              ? Icons.emoji_events_rounded
                              : Icons.arrow_forward_rounded,
                          onPressed:
                              feedback.runEnded ? widget.onEnd : widget.onNext,
                        ),
                        if (!feedback.runEnded)
                          TextButton(
                            onPressed: widget.onEnd,
                            child: const Text('End run'),
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

class _AutoAdvanceBar extends StatelessWidget {
  const _AutoAdvanceBar({required this.autoAdvanceMs, required this.label});

  final ValueListenable<int?> autoAdvanceMs;
  final String label;

  static const _totalMs = 3000;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ValueListenableBuilder<int?>(
      valueListenable: autoAdvanceMs,
      builder: (context, value, _) {
        final remaining = value ?? _totalMs;
        final progress = (remaining / _totalMs).clamp(0.0, 1.0);
        final seconds = (remaining / 1000).ceil().clamp(1, 3);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '$label $seconds',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            SqProgressTrack(
              value: progress,
              height: 8,
              animate: false,
              gradient: AppColors.heatGradient,
            ),
          ],
        );
      },
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
                  'TEACH ME',
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
                          title: 'Why the answer is right',
                          body: result.whyCorrect,
                        ),
                        _TeachBlock(
                          title: 'Why yours missed',
                          body: result.whyWrong,
                        ),
                        _TeachBlock(
                          title: 'Key concept',
                          body: result.keyConcept,
                        ),
                        _TeachBlock(
                          title: 'Remember this',
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
