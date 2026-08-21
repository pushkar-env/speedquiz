import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/studio/data/custom_quiz_repository.dart';
import 'package:speedquiz/features/studio/presentation/widgets/quiz_widgets.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// Landing screen for a share code that arrived from outside the app.
///
/// It exists because redeeming a code is a *write* — it grants the player
/// standing access — and a deep link cannot go straight to the quiz screen
/// without doing it first. It also gives the failure somewhere to live: a code
/// can be stale, revoked, or for a quiz the author has since made private, and
/// all three deserve a screen rather than a toast on top of the wrong page.
class QuizCodeScreen extends ConsumerStatefulWidget {
  const QuizCodeScreen({super.key, required this.code});

  final String code;

  @override
  ConsumerState<QuizCodeScreen> createState() => _QuizCodeScreenState();
}

class _QuizCodeScreenState extends ConsumerState<QuizCodeScreen> {
  Object? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolve());
  }

  Future<void> _resolve() async {
    setState(() => _error = null);
    try {
      final quiz = await ref
          .read(customQuizRepositoryProvider)
          .openByCode(widget.code);
      if (!mounted) return;
      Haptics.success();
      ref.invalidate(customQuizLibraryProvider);
      // Replace rather than push: backing out of the quiz should land on the
      // studio, not on a resolver screen that would immediately re-resolve.
      context.pushReplacement(Routes.quizDetailPath(quiz.id));
    } catch (error) {
      if (!mounted) return;
      Haptics.error();
      setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SqBackdrop(
        intensity: 0.55,
        colors: const [AppColors.gold, AppColors.violet, AppColors.accent],
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Center(
              child: _error == null
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        QuizCodeChip(code: widget.code.toUpperCase()),
                        const SizedBox(height: AppSpacing.lg),
                        const CircularProgressIndicator(),
                        const SizedBox(height: AppSpacing.md),
                        Text(
                          l10n.loading,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ],
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SqErrorState(
                          title: l10n.studioCodeInvalid,
                          message: quizErrorMessage(context, _error!),
                          onRetry: _resolve,
                        ),
                        const SizedBox(height: AppSpacing.md),
                        SqButton(
                          label: l10n.studioTitle,
                          variant: SqButtonVariant.ghost,
                          onPressed: () => context.go(Routes.studio),
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
