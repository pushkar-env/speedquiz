import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:quizverse/core/network/api_errors.dart';
import 'package:quizverse/core/theme/app_theme.dart';
import 'package:quizverse/features/quiz/data/quiz_repository.dart';
import 'package:quizverse/features/quiz/domain/quiz_models.dart';
import 'package:quizverse/features/quiz/presentation/quiz_results_screen.dart';
import 'package:quizverse/shared/widgets/qv_button.dart';

/// Owner results: uses in-memory [QuizResult] when present, otherwise fetches.
class QuizResultsLoaderScreen extends ConsumerWidget {
  const QuizResultsLoaderScreen({
    super.key,
    required this.sessionId,
    this.initialResult,
  });

  final String sessionId;
  final QuizResult? initialResult;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (initialResult != null) {
      return QuizResultsScreen(result: initialResult!);
    }

    final async = ref.watch(_ownerResultProvider(sessionId));
    return async.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator(color: AppColors.accent)),
      ),
      error: (err, _) => Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  apiErrorMessage(
                    err,
                    fallback: 'Could not load this result.',
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.md),
                QvButton(
                  label: 'GO HOME',
                  onPressed: () => context.go('/home'),
                ),
                const SizedBox(height: AppSpacing.sm),
                TextButton(
                  onPressed: () => context.go('/share/results/$sessionId'),
                  child: const Text('Open shared card'),
                ),
              ],
            ),
          ),
        ),
      ),
      data: (result) => QuizResultsScreen(result: result),
    );
  }
}

final _ownerResultProvider =
    FutureProvider.autoDispose.family<QuizResult, String>((ref, sessionId) {
  return ref.watch(quizRepositoryProvider).getResult(sessionId);
});
