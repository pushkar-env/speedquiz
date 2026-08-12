import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:speedquiz/core/network/api_errors.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/share/data/share_repository.dart';
import 'package:speedquiz/features/share/domain/share_models.dart';
import 'package:speedquiz/shared/widgets/sq_logo.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// Public read-only card for a shared run. Reachable without a session, so it
/// doubles as the app's install pitch when a friend opens the link.
class SharedResultScreen extends ConsumerWidget {
  const SharedResultScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(sharedResultProvider(sessionId));

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SqBackdrop(
        colors: const [AppColors.accent, AppColors.violet, AppColors.gold],
        child: SafeArea(
          child: async.when(
            loading: () => Center(
              child: CircularProgressIndicator(color: context.sq.accent),
            ),
            error: (error, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SqErrorState(
                      title: 'Card unavailable',
                      message: apiErrorMessage(
                        error,
                        fallback:
                            'This shared result has expired or was removed.',
                      ),
                      onRetry: () =>
                          ref.invalidate(sharedResultProvider(sessionId)),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    SqButton(
                      label: 'OPEN SPEEDQUIZ',
                      icon: Icons.bolt_rounded,
                      onPressed: () => context.go(Routes.home),
                    ),
                  ],
                ),
              ),
            ),
            data: (result) => _SharedCard(result: result),
          ),
        ),
      ),
    );
  }
}

class _SharedCard extends StatelessWidget {
  const _SharedCard({required this.result});

  final SharedResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        children: [
          const SqStagger(child: SqLogoMark(size: 54)),
          const SizedBox(height: AppSpacing.lg),
          Expanded(
            child: Center(
              child: SqStagger(
                index: 1,
                child: Container(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppRadii.lg),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [p.accentWash(p.isDark ? 0.14 : 0.10), p.surface],
                    ),
                    border: Border.all(color: p.accentWash(0.32)),
                    boxShadow: AppShadows.lifted(p),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SqBadge(label: 'SHARED RUN', icon: Icons.share_rounded),
                      const SizedBox(height: AppSpacing.md),
                      SqAnimatedCounter(
                        value: result.finalScore,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.displayMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${result.topicName} · '
                        '${humanizeMode(result.difficulty)} · '
                        '${humanizeMode(result.mode)}',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      Row(
                        children: [
                          Expanded(
                            child: _MiniStat(
                              label: 'Accuracy',
                              value: '${result.accuracy.toStringAsFixed(0)}%',
                            ),
                          ),
                          Expanded(
                            child: _MiniStat(
                              label: 'Streak',
                              value: '${result.bestStreak}',
                            ),
                          ),
                          Expanded(
                            child: _MiniStat(
                              label: 'Questions',
                              value: '${result.questionsAnswered}',
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          SqStagger(
            index: 2,
            child: Text(
              'Think you can beat that?',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          SqStagger(
            index: 3,
            child: SqButton(
              label: 'BEAT THIS SCORE',
              icon: Icons.bolt_rounded,
              onPressed: () => context.go(Routes.quizSetup),
            ),
          ),
          const SizedBox(height: 10),
          SqStagger(
            index: 4,
            child: SqButton(
              label: 'GO HOME',
              variant: SqButtonVariant.ghost,
              onPressed: () => context.go(Routes.home),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        Text(
          value,
          style: theme.textTheme.titleLarge?.copyWith(
            fontFamily: 'SpaceGrotesk',
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label.toUpperCase(),
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.sq.textFaint,
            letterSpacing: 0.8,
          ),
        ),
      ],
    );
  }
}
