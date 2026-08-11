import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/share/data/share_repository.dart';
import 'package:speedquiz/shared/widgets/sq_button.dart';

class SharedResultScreen extends ConsumerWidget {
  const SharedResultScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(sharedResultProvider(sessionId));
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: dark ? AppColors.backgroundDark.wash : null,
          color: dark ? null : AppColors.backgroundLight,
        ),
        child: SafeArea(
          child: async.when(
            loading: () => const Center(
              child: CircularProgressIndicator(color: AppColors.accent),
            ),
            error: (err, _) => Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'This shared result is unavailable.',
                    style: theme.textTheme.titleLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  SqButton(
                    label: 'GO HOME',
                    onPressed: () => context.go('/home'),
                  ),
                ],
              ),
            ),
            data: (result) => Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'SHARED RESULT',
                    style: theme.textTheme.titleMedium?.copyWith(
                      letterSpacing: 2,
                      color: AppColors.accent,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    formatScore(result.finalScore),
                    style: theme.textTheme.displayMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: -1.5,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${result.topicName} · ${result.difficulty.toUpperCase()} · '
                    '${result.mode.replaceAll('_', ' ')}',
                    style: theme.textTheme.bodyLarge,
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  SqSurface(
                    child: Column(
                      children: [
                        _ShareStat(
                          label: 'Accuracy',
                          value: '${result.accuracy.toStringAsFixed(0)}%',
                        ),
                        const Divider(height: 20),
                        _ShareStat(
                          label: 'Best streak',
                          value: '${result.bestStreak}',
                        ),
                        const Divider(height: 20),
                        _ShareStat(
                          label: 'Questions',
                          value: '${result.questionsAnswered}',
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  SqButton(
                    label: 'PLAY SPEEDQUIZ',
                    onPressed: () => context.go('/home'),
                  ),
                  const SizedBox(height: 10),
                  Center(
                    child: TextButton(
                      onPressed: () => context.go('/quiz/setup'),
                      child: const Text('START A QUIZ'),
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

class _ShareStat extends StatelessWidget {
  const _ShareStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(label),
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
