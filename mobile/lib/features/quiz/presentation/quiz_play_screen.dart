import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/auth/presentation/auth_controller.dart';
import 'package:speedquiz/features/custom_topics/data/custom_topics_repository.dart';
import 'package:speedquiz/features/daily/data/daily_repository.dart';
import 'package:speedquiz/features/entitlements/presentation/premium_paywall_sheet.dart';
import 'package:speedquiz/features/leaderboard/data/leaderboard_repository.dart';
import 'package:speedquiz/features/quiz/domain/quiz_models.dart';
import 'package:speedquiz/features/quiz/presentation/quiz_play_controller.dart';
import 'package:speedquiz/shared/widgets/sq_button.dart';

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
      ref.read(quizPlayControllerProvider.notifier).start(
            topicId: widget.topicId,
            mode: widget.mode,
            difficulty: widget.difficulty,
            adaptive: widget.adaptive,
            existingSession: widget.existingSession,
          );
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(quizPlayControllerProvider);

    ref.listen<QuizPlayState>(quizPlayControllerProvider, (prev, next) {
      if (next is QuizPlayFinished) {
        final result = next.result;
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
        context.go('/quiz/results/${result.sessionId}', extra: result);
      }
    });

    return Scaffold(
      body: SafeArea(
        child: switch (state) {
          QuizPlayLoading() || QuizPlayIdle() => const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: AppColors.accent),
                  SizedBox(height: 16),
                  Text('Preparing your challenge…'),
                ],
              ),
            ),
          QuizPlayError(:final message, :final isEntitlementCap) => Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(message, textAlign: TextAlign.center),
                  const SizedBox(height: AppSpacing.md),
                  if (isEntitlementCap) ...[
                    SqButton(
                      label: 'GO PREMIUM',
                      onPressed: () => showPremiumPaywall(
                        context,
                        reason:
                            'You hit the free unique-question limit for this topic.',
                      ),
                    ),
                    const SizedBox(height: 10),
                    SqGhostButton(
                      label: 'BACK HOME',
                      onPressed: () => context.go('/home'),
                    ),
                  ] else ...[
                    SqButton(
                      label: 'Back home',
                      onPressed: () => context.go('/home'),
                    ),
                    if (message.toLowerCase().contains('session')) ...[
                      const SizedBox(height: AppSpacing.sm),
                      TextButton(
                        onPressed: () async {
                          await ref
                              .read(authControllerProvider.notifier)
                              .continueAsGuest();
                          if (!context.mounted) return;
                          ref.read(quizPlayControllerProvider.notifier).start(
                                topicId: widget.topicId,
                                mode: widget.mode,
                                difficulty: widget.difficulty,
                                adaptive: widget.adaptive,
                                existingSession: null,
                              );
                        },
                        child: const Text('Sign in again & retry'),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          QuizPlayFinished() => const Center(
              child: CircularProgressIndicator(color: AppColors.accent),
            ),
          QuizPlayActive(
            :final session,
            :final remainingMs,
            :final feedback,
            :final submitting,
            :final selectedOptionIndex,
            :final autoAdvanceRemainingMs,
          ) =>
            _QuestionView(
              session: session,
              remainingMs: remainingMs,
              submitting: submitting,
              feedback: feedback,
              selectedOptionIndex: selectedOptionIndex,
              autoAdvanceRemainingMs: autoAdvanceRemainingMs,
              onSelect: (i) => ref
                  .read(quizPlayControllerProvider.notifier)
                  .submit(optionIndex: i),
              onNext: () => ref
                  .read(quizPlayControllerProvider.notifier)
                  .continueAfterFeedback(),
              onEnd: () =>
                  ref.read(quizPlayControllerProvider.notifier).endRun(),
            ),
        },
      ),
    );
  }
}

class _QuestionView extends StatefulWidget {
  const _QuestionView({
    required this.session,
    required this.remainingMs,
    required this.submitting,
    required this.onSelect,
    required this.onNext,
    required this.onEnd,
    this.feedback,
    this.selectedOptionIndex,
    this.autoAdvanceRemainingMs,
  });

  final QuizSession session;
  final int remainingMs;
  final bool submitting;
  final AnswerFeedback? feedback;
  final int? selectedOptionIndex;
  final int? autoAdvanceRemainingMs;
  final ValueChanged<int> onSelect;
  final VoidCallback onNext;
  final VoidCallback onEnd;

  @override
  State<_QuestionView> createState() => _QuestionViewState();
}

class _QuestionViewState extends State<_QuestionView> {
  final _feedbackKey = GlobalKey();

  bool get _answered => widget.feedback != null;
  bool get _isSpeedrun => widget.session.mode == 'speedrun';

  @override
  void didUpdateWidget(covariant _QuestionView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.feedback == null && widget.feedback != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _feedbackKey.currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(
            ctx,
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            alignment: 0.1,
          );
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = widget.session;
    final feedback = widget.feedback;
    final q = session.currentQuestion;
    if (q == null) {
      return const Center(child: Text('No question'));
    }

    final progress = q.timeLimitMs == 0
        ? 0.0
        : (_answered ? 0.0 : widget.remainingMs / q.timeLimitMs);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Hud(session: session, feedback: feedback, theme: theme),
          const SizedBox(height: AppSpacing.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: progress.clamp(0, 1),
              minHeight: 8,
              backgroundColor: AppColors.borderDark.withValues(alpha: 0.4),
              color: !_answered && progress < 0.25
                  ? AppColors.danger
                  : AppColors.accent,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _answered
                ? 'QUESTION ${session.questionNumber}'
                : 'QUESTION ${session.questionNumber}  ·  ${(widget.remainingMs / 1000).ceil()}s',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: AppSpacing.md),
          Expanded(
            child: ListView(
              children: [
                Text(
                  q.prompt,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                ...List.generate(q.options.length, (index) {
                  final opt = q.options[index];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _OptionTile(
                      index: index,
                      text: opt.text,
                      enabled: !_answered && !widget.submitting,
                      state: _optionVisualState(opt.index),
                      onTap: () => widget.onSelect(opt.index),
                    ),
                  );
                }),
                if (feedback != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  KeyedSubtree(
                    key: _feedbackKey,
                    child: _InlineFeedback(
                      feedback: feedback,
                      isSpeedrun: _isSpeedrun,
                      autoAdvanceRemainingMs: widget.autoAdvanceRemainingMs,
                      questionId: q.questionId,
                      selectedOptionText: () {
                        final idx = widget.selectedOptionIndex;
                        if (idx == null) return null;
                        for (final o in q.options) {
                          if (o.index == idx) return o.text;
                        }
                        return null;
                      }(),
                    ),
                  ),
                ],
                const SizedBox(height: AppSpacing.md),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          if (feedback != null) ...[
            if (_isSpeedrun && widget.autoAdvanceRemainingMs != null)
              _SpeedrunAdvanceBar(
                remainingMs: widget.autoAdvanceRemainingMs!,
                label: feedback.runEnded ? 'Results in' : 'Next question in',
              )
            else if (feedback.runEnded)
              SqButton(label: 'SEE RESULTS', onPressed: widget.onEnd)
            else
              SqButton(label: 'NEXT', onPressed: widget.onNext),
            if (!feedback.runEnded)
              TextButton(
                onPressed: widget.onEnd,
                child: const Text('End run'),
              ),
          ] else
            TextButton(onPressed: widget.onEnd, child: const Text('End run')),
        ],
      ),
    );
  }

  _OptionVisualState _optionVisualState(int optionIndex) {
    final feedback = widget.feedback;
    if (feedback == null) return _OptionVisualState.idle;
    final isCorrect = optionIndex == feedback.correctOptionIndex;
    final isSelected = widget.selectedOptionIndex == optionIndex;
    if (isCorrect) return _OptionVisualState.correct;
    if (isSelected && !feedback.isCorrect) return _OptionVisualState.wrong;
    return _OptionVisualState.dimmed;
  }
}

class _Hud extends StatelessWidget {
  const _Hud({
    required this.session,
    required this.theme,
    this.feedback,
  });

  final QuizSession session;
  final AnswerFeedback? feedback;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final score = feedback?.score ?? session.score;
    final streak = feedback?.streak ?? session.streak;
    final lives = feedback?.lives ?? session.lives;
    final timeRemaining = feedback?.timeRemainingMs ?? session.timeRemainingMs;

    return Row(
      children: [
        Text(
          formatScore(score),
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const Spacer(),
        if (lives != null)
          Text('❤️ $lives', style: theme.textTheme.titleMedium),
        if (timeRemaining != null) ...[
          const SizedBox(width: 12),
          Text(
            '⏱ ${(timeRemaining / 1000).ceil()}s',
            style: theme.textTheme.titleMedium,
          ),
        ],
        const SizedBox(width: 12),
        Text(
          '🔥 × $streak',
          style: theme.textTheme.titleMedium?.copyWith(
            color: AppColors.warning,
          ),
        ),
      ],
    );
  }
}

enum _OptionVisualState { idle, correct, wrong, dimmed }

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.index,
    required this.text,
    required this.enabled,
    required this.state,
    required this.onTap,
  });

  final int index;
  final String text;
  final bool enabled;
  final _OptionVisualState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final label = String.fromCharCode(65 + index);

    final Color border;
    final Color background;
    final Color badge;
    switch (state) {
      case _OptionVisualState.correct:
        border = AppColors.success;
        background = AppColors.success.withValues(alpha: 0.14);
        badge = AppColors.success;
      case _OptionVisualState.wrong:
        border = AppColors.danger;
        background = AppColors.danger.withValues(alpha: 0.14);
        badge = AppColors.danger;
      case _OptionVisualState.dimmed:
        border = dark ? AppColors.borderDark : AppColors.borderLight;
        background = (dark ? AppColors.surfaceDark : AppColors.surfaceLight)
            .withValues(alpha: 0.45);
        badge = AppColors.textSecondaryDark;
      case _OptionVisualState.idle:
        border = dark ? AppColors.borderDark : AppColors.borderLight;
        background = dark ? AppColors.surfaceDark : AppColors.surfaceLight;
        badge = AppColors.accent;
    }

    return Material(
      color: background,
      borderRadius: BorderRadius.circular(AppRadii.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.md),
        onTap: enabled ? onTap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.md),
            border: Border.all(
              color: border,
              width: state == _OptionVisualState.idle ? 1 : 1.6,
            ),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: badge.withValues(alpha: 0.18),
                child: Text(
                  label,
                  style: TextStyle(
                    color: badge,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(text, style: theme.textTheme.titleMedium),
              ),
              if (state == _OptionVisualState.correct)
                const Icon(Icons.check_circle_rounded, color: AppColors.success)
              else if (state == _OptionVisualState.wrong)
                const Icon(Icons.cancel_rounded, color: AppColors.danger),
            ],
          ),
        ),
      ),
    );
  }
}

class _InlineFeedback extends StatefulWidget {
  const _InlineFeedback({
    required this.feedback,
    required this.isSpeedrun,
    required this.questionId,
    this.autoAdvanceRemainingMs,
    this.selectedOptionText,
  });

  final AnswerFeedback feedback;
  final bool isSpeedrun;
  final String questionId;
  final int? autoAdvanceRemainingMs;
  final String? selectedOptionText;

  @override
  State<_InlineFeedback> createState() => _InlineFeedbackState();
}

class _InlineFeedbackState extends State<_InlineFeedback> {
  bool _loadingTeach = false;
  TeachMeResult? _teach;
  String? _teachError;

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
      });
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
    final correct = widget.feedback.isCorrect;
    final dark = theme.brightness == Brightness.dark;
    final feedback = widget.feedback;

    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: (correct ? AppColors.success : AppColors.danger)
              .withValues(alpha: dark ? 0.12 : 0.08),
          borderRadius: BorderRadius.circular(AppRadii.md),
          border: Border.all(
            color: (correct ? AppColors.success : AppColors.danger)
                .withValues(alpha: 0.45),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              correct ? '✓ CORRECT' : '✕ INCORRECT',
              style: theme.textTheme.titleLarge?.copyWith(
                color: correct ? AppColors.success : AppColors.danger,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            if (correct) ...[
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  Text(
                    '+${feedback.pointsAwarded}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (feedback.speedBonus > 0)
                    Text(
                      '+${feedback.speedBonus} speed',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: AppColors.warning,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  if (feedback.streakMultiplier > 1)
                    Text(
                      '×${feedback.streakMultiplier.toStringAsFixed(2)} streak',
                      style: theme.textTheme.bodyMedium,
                    ),
                ],
              ),
            ] else ...[
              Text(
                'Correct: ${feedback.correctOptionText}',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            Text(
              'WHY?',
              style: theme.textTheme.labelLarge?.copyWith(
                letterSpacing: 0.8,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              feedback.explanation,
              style: theme.textTheme.bodyLarge?.copyWith(height: 1.35),
            ),
            if (!correct) ...[
              const SizedBox(height: AppSpacing.md),
              Consumer(
                builder: (context, ref, _) {
                  if (_teach != null) {
                    return _TeachMePanel(result: _teach!);
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      OutlinedButton.icon(
                        onPressed:
                            _loadingTeach ? null : () => _loadTeach(ref),
                        icon: _loadingTeach
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.school_outlined, size: 18),
                        label: Text(
                          _loadingTeach ? 'Teaching…' : 'TEACH ME',
                        ),
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
            if (widget.isSpeedrun &&
                !feedback.runEnded &&
                widget.autoAdvanceRemainingMs != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Next in ${((widget.autoAdvanceRemainingMs! / 1000).ceil()).clamp(1, 3)}…',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: AppColors.warning,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TeachMePanel extends StatelessWidget {
  const _TeachMePanel({required this.result});

  final TeachMeResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'TEACH ME',
          style: theme.textTheme.labelLarge?.copyWith(
            letterSpacing: 0.8,
            color: AppColors.accent,
          ),
        ),
        const SizedBox(height: 8),
        _TeachBlock(title: 'Why correct', body: result.whyCorrect),
        _TeachBlock(title: 'Why your answer', body: result.whyWrong),
        _TeachBlock(title: 'Key concept', body: result.keyConcept),
        _TeachBlock(title: 'Remember this', body: result.memorableFact),
      ],
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
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(body, style: theme.textTheme.bodyMedium?.copyWith(height: 1.35)),
        ],
      ),
    );
  }
}

class _SpeedrunAdvanceBar extends StatelessWidget {
  const _SpeedrunAdvanceBar({
    required this.remainingMs,
    this.label = 'Next question in',
  });

  final int remainingMs;
  final String label;

  @override
  Widget build(BuildContext context) {
    final progress = (remainingMs / 3000).clamp(0.0, 1.0);
    final secs = ((remainingMs / 1000).ceil()).clamp(1, 3);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '$label $secs',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 10,
            backgroundColor: AppColors.borderDark.withValues(alpha: 0.35),
            color: AppColors.warning,
          ),
        ),
      ],
    );
  }
}
