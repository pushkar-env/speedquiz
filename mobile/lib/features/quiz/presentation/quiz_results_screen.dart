import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:quizverse/core/theme/app_theme.dart';
import 'package:quizverse/features/quiz/domain/quiz_models.dart';
import 'package:quizverse/shared/widgets/qv_button.dart';
import 'package:share_plus/share_plus.dart';

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

  Future<void> _shareResult() async {
    final result = widget.result;
    final text = result.shareText.isNotEmpty
        ? result.shareText
        : 'QUIZVERSE\n\n${result.topicName}\n'
            'Score: ${formatScore(result.finalScore)}\n'
            'Accuracy: ${result.accuracy.toStringAsFixed(0)}%\n'
            'Best Streak: ${result.bestStreak}';
    await SharePlus.instance.share(ShareParams(text: text));
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final avgSec = (result.averageAnswerMs / 1000).toStringAsFixed(1);
    final unlocks = result.newAchievements;

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
                  Expanded(
                    child: ListView(
                      children: [
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
                                  color:
                                      AppColors.warning.withValues(alpha: 0.14),
                                  borderRadius:
                                      BorderRadius.circular(AppRadii.pill),
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
                        if (!result.isPersonalBest &&
                            result.previousBest > 0) ...[
                          const SizedBox(height: 6),
                          Text(
                            'Personal best: ${formatScore(result.previousBest)}',
                            style: theme.textTheme.bodyMedium,
                          ),
                        ],
                        if (unlocks.isNotEmpty) ...[
                          const SizedBox(height: AppSpacing.lg),
                          Text(
                            'Unlocked',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          ...unlocks.map(
                            (a) => Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: _UnlockCard(achievement: a),
                            ),
                          ),
                        ],
                        const SizedBox(height: AppSpacing.lg),
                        _ShareCardPreview(result: result),
                      ],
                    ),
                  ),
                  QvButton(
                    label: 'PLAY AGAIN',
                    onPressed: () => context.go('/quiz/setup'),
                  ),
                  const SizedBox(height: 10),
                  QvGhostButton(
                    label: 'SHARE RESULT',
                    onPressed: _shareResult,
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

class _ShareCardPreview extends StatelessWidget {
  const _ShareCardPreview({required this.result});

  final QuizResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadii.md),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? const [Color(0xFF1A2836), Color(0xFF12201A)]
              : [
                  AppColors.surfaceLight,
                  AppColors.accent.withValues(alpha: 0.08),
                ],
        ),
        border: Border.all(
          color: AppColors.accent.withValues(alpha: 0.28),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'SHARE CARD',
            style: theme.textTheme.labelLarge?.copyWith(
              letterSpacing: 1.2,
              color: AppColors.accent,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            result.topicName,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${formatScore(result.finalScore)} · '
            '${result.accuracy.toStringAsFixed(0)}% accuracy · '
            'streak ${result.bestStreak}',
            style: theme.textTheme.bodyMedium,
          ),
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
    final dark = theme.brightness == Brightness.dark;
    final rewardBits = <String>[];
    if (achievement.xpReward > 0) {
      rewardBits.add('+${achievement.xpReward} XP');
    }
    if (achievement.coinsReward > 0) {
      rewardBits.add('+${achievement.coinsReward} coins');
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadii.md),
        color: dark ? AppColors.surfaceDark : AppColors.surfaceLight,
        border: Border.all(
          color: AppColors.accent.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.accent.withValues(alpha: 0.14),
            ),
            child: Text(
              _iconGlyph(achievement.icon),
              style: const TextStyle(fontSize: 20),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  achievement.name,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  achievement.description,
                  style: theme.textTheme.bodyMedium,
                ),
                if (rewardBits.isNotEmpty)
                  Text(
                    rewardBits.join(' · '),
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: AppColors.accent,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _iconGlyph(String icon) {
  switch (icon) {
    case 'flag':
      return '🏁';
    case 'check':
      return '✅';
    case 'fire':
      return '🔥';
    case 'bolt':
      return '⚡';
    case 'brain':
      return '🧠';
    case 'infinity':
      return '∞';
    case 'star':
      return '⭐';
    case 'calendar':
      return '📅';
    case 'planet':
      return '🪐';
    case 'sigma':
      return '∑';
    case 'robot':
      return '🤖';
    default:
      return '🏆';
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
