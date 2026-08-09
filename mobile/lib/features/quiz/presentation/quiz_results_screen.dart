import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:quizverse/core/theme/app_theme.dart';
import 'package:quizverse/features/quiz/domain/quiz_models.dart';
import 'package:quizverse/shared/widgets/qv_button.dart';

class QuizResultsScreen extends StatefulWidget {
  const QuizResultsScreen({super.key, required this.result});

  final QuizResult result;

  @override
  State<QuizResultsScreen> createState() => _QuizResultsScreenState();
}

class _QuizResultsScreenState extends State<QuizResultsScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scoreScale;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _scoreScale = Tween<double>(begin: 0.82, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutBack),
    );
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final avgSec = (result.averageAnswerMs / 1000).toStringAsFixed(1);

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: dark ? AppColors.backgroundDark.wash : null,
          color: dark ? null : AppColors.backgroundLight,
        ),
        child: SafeArea(
          child: FadeTransition(
            opacity: _fade,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'GAME OVER',
                    style: theme.textTheme.titleMedium?.copyWith(
                      letterSpacing: 2.2,
                      color: AppColors.warning,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  ScaleTransition(
                    scale: _scoreScale,
                    child: Text(
                      formatScore(result.finalScore),
                      style: theme.textTheme.displayMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: -1.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${result.topicName} · ${result.difficulty.toUpperCase()} · ${result.mode.replaceAll('_', ' ')}',
                    style: theme.textTheme.bodyLarge,
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  QvSurface(
                    child: Column(
                      children: [
                        _StatRow(
                          label: 'Best Streak',
                          icon: '🔥',
                          value: '${result.bestStreak}',
                        ),
                        const Divider(height: 20),
                        _StatRow(
                          label: 'Accuracy',
                          icon: '🎯',
                          value: '${result.accuracy.toStringAsFixed(0)}%',
                        ),
                        const Divider(height: 20),
                        _StatRow(
                          label: 'Avg Answer',
                          icon: '⚡',
                          value: '${avgSec}s',
                        ),
                        const Divider(height: 20),
                        _StatRow(
                          label: 'Questions',
                          icon: '📘',
                          value: '${result.questionsAnswered}',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Row(
                    children: [
                      Text(
                        '+${result.xpEarned} XP',
                        style: theme.textTheme.headlineSmall?.copyWith(
                          color: AppColors.accent,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const Spacer(),
                      if (result.isPersonalBest)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.warning.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(AppRadii.pill),
                          ),
                          child: Text(
                            'NEW BEST',
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: AppColors.warning,
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (!result.isPersonalBest && result.previousBest > 0) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Personal best: ${formatScore(result.previousBest)}',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                  const Spacer(),
                  QvButton(
                    label: 'PLAY AGAIN',
                    onPressed: () => context.go('/quiz/setup'),
                  ),
                  const SizedBox(height: 10),
                  QvGhostButton(
                    label: 'SHARE RESULT',
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: result.shareText),
                      );
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Result copied — ready to share'),
                          ),
                        );
                      }
                    },
                  ),
                  const SizedBox(height: 4),
                  Center(
                    child: TextButton(
                      onPressed: () => context.go('/home'),
                      child: const Text('HOME'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({
    required this.label,
    required this.icon,
    required this.value,
  });

  final String label;
  final String icon;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text('$icon  $label'),
        const Spacer(),
        Text(
          value,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
      ],
    );
  }
}
