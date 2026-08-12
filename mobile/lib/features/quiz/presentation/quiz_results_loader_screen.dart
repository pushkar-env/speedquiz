import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/network/api_errors.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/quiz/data/quiz_repository.dart';
import 'package:speedquiz/features/quiz/domain/quiz_models.dart';
import 'package:speedquiz/features/quiz/presentation/quiz_results_screen.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// Owner results: renders the in-memory [QuizResult] when the run just
/// finished, otherwise refetches it (deep link, cold start, app resume).
class QuizResultsLoaderScreen extends ConsumerWidget {
  const QuizResultsLoaderScreen({
    super.key,
    required this.sessionId,
    this.args,
  });

  final String sessionId;
  final QuizResultArgs? args;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = this.args;
    if (args != null) return QuizResultsScreen(args: args);

    final async = ref.watch(_ownerResultProvider(sessionId));

    return async.when(
      loading: () => Scaffold(
        backgroundColor: Colors.transparent,
        body: SqBackdrop(
          intensity: 0.5,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 42,
                  height: 42,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    color: context.sq.accent,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  context.l10n.resultsLoading,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ),
      ),
      error: (error, _) => Scaffold(
        backgroundColor: Colors.transparent,
        body: SqBackdrop(
          intensity: 0.4,
          child: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SqErrorState(
                      title: context.l10n.resultsUnavailable,
                      message: apiErrorMessage(
                        error,
                        fallback: context.l10n.resultsCouldNotLoad,
                      ),
                      onRetry: () =>
                          ref.invalidate(_ownerResultProvider(sessionId)),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    SqButton(
                      label: context.l10n.resultsGoHome,
                      icon: Icons.home_rounded,
                      onPressed: () => context.go(Routes.home),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextButton(
                      onPressed: () => context.go('/share/results/$sessionId'),
                      child: Text(context.l10n.resultsOpenSharedCard),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      data: (result) => QuizResultsScreen(args: QuizResultArgs(result: result)),
    );
  }
}

final _ownerResultProvider = FutureProvider.autoDispose
    .family<QuizResult, String>((ref, sessionId) {
      return ref.watch(quizRepositoryProvider).getResult(sessionId);
    });
