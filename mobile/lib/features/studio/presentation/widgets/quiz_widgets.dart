import 'package:flutter/material.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/network/api_errors.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/studio/domain/custom_quiz_models.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// One studio error, in the player's language.
///
/// The API answers every failure the client should *do* something about with a
/// structured `detail.code`, precisely so no screen has to pattern-match on
/// prose. Anything without a code falls through to the generic network copy.
String quizErrorMessage(BuildContext context, Object error, {String? fallback}) {
  final code = apiErrorCode(error);
  if (code != null && code.isNotEmpty) return context.l10n.quizError(code);
  return localizedApiErrorMessage(context, error, fallback: fallback);
}

/// Colour a quiz's state is drawn in, everywhere it appears.
///
/// Kept in one place because status is shown on three screens and a draft that
/// is amber on the hub and grey in the editor reads as two different things.
Color quizStatusTint(QuizStatus status) => switch (status) {
  QuizStatus.published => AppColors.accent,
  QuizStatus.draft => AppColors.warning,
  QuizStatus.archived => AppColors.cyan,
  QuizStatus.hidden => AppColors.danger,
};

String quizStatusLabel(SqStrings l10n, QuizStatus status) => switch (status) {
  QuizStatus.published => l10n.quizStatusPublished,
  QuizStatus.draft => l10n.quizStatusDraft,
  QuizStatus.archived => l10n.quizStatusArchived,
  QuizStatus.hidden => l10n.quizStatusHidden,
};

String quizVisibilityLabel(SqStrings l10n, QuizVisibility visibility) =>
    switch (visibility) {
      QuizVisibility.private => l10n.quizVisibilityPrivate,
      QuizVisibility.friends => l10n.quizVisibilityFriends,
      QuizVisibility.link => l10n.quizVisibilityLink,
    };

String quizVisibilityBody(SqStrings l10n, QuizVisibility visibility) =>
    switch (visibility) {
      QuizVisibility.private => l10n.quizVisibilityPrivateBody,
      QuizVisibility.friends => l10n.quizVisibilityFriendsBody,
      QuizVisibility.link => l10n.quizVisibilityLinkBody,
    };

IconData quizVisibilityIcon(QuizVisibility visibility) => switch (visibility) {
  QuizVisibility.private => Icons.lock_outline_rounded,
  QuizVisibility.friends => Icons.group_outlined,
  QuizVisibility.link => Icons.link_rounded,
};

/// The square emoji plate a quiz is identified by, in list rows and headers.
class QuizGlyph extends StatelessWidget {
  const QuizGlyph({super.key, required this.icon, this.tint, this.size = 48});

  final String icon;
  final Color? tint;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colour = tint ?? context.sq.accent;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadii.sm),
        border: Border.all(color: colour.withValues(alpha: 0.28)),
      ),
      child: Text(icon, style: TextStyle(fontSize: size * 0.46)),
    );
  }
}

/// One quiz in a list.
///
/// Shows status only to the author: "Draft" on a quiz somebody shared with you
/// would be describing a state you cannot see or act on.
class QuizCard extends StatelessWidget {
  const QuizCard({super.key, required this.quiz, required this.onTap});

  final CustomQuiz quiz;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final l10n = context.l10n;
    final tint = quizStatusTint(quiz.status);

    return SqSurface(
      onTap: onTap,
      accent: tint,
      // A draft is the one row that wants the eye: it is unfinished work.
      highlighted: quiz.isOwner && quiz.status == QuizStatus.draft,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          QuizGlyph(icon: quiz.icon, tint: tint),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        quiz.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    if (quiz.isOwner) ...[
                      const SizedBox(width: 8),
                      SqBadge(
                        label: quizStatusLabel(l10n, quiz.status),
                        color: tint,
                        dense: true,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  quiz.isOwner
                      ? l10n.quizStatLine(quiz.questionCount, quiz.playCount)
                      : l10n.quizByAuthor(quiz.author.name),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
                if (quiz.myBestScore != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    l10n.quizYourBest(formatScore(quiz.myBestScore!)),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: AppColors.gold,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 6),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Icon(
                quizVisibilityIcon(quiz.visibility),
                size: 16,
                color: p.textFaint,
              ),
              const SizedBox(height: 10),
              Icon(Icons.chevron_right_rounded, color: p.textFaint),
            ],
          ),
        ],
      ),
    );
  }
}

/// Selectable chip used for difficulty, mode and visibility choices.
///
/// A local copy rather than a shared widget: the studio's chips carry an
/// optional icon and a tint the rest of the app's pill rows do not use, and
/// widening the shared one for a single caller is how a design system rots.
class QuizChip extends StatelessWidget {
  const QuizChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.tint,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final colour = tint ?? p.accent;

    return SqPressable(
      onTap: onTap,
      pressedScale: 0.96,
      borderRadius: BorderRadius.circular(AppRadii.pill),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: selected
              ? colour.withValues(alpha: p.isDark ? 0.18 : 0.12)
              : p.surface,
          borderRadius: BorderRadius.circular(AppRadii.pill),
          border: Border.all(
            color: selected ? colour.withValues(alpha: 0.65) : p.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 15,
                color: selected ? colour : p.textFaint,
              ),
              const SizedBox(width: 7),
            ],
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: selected ? colour : p.textSecondary,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The share code, sized to be read off someone else's screen.
class QuizCodeChip extends StatelessWidget {
  const QuizCodeChip({super.key, required this.code, this.onTap});

  final String code;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return SqPressable(
      onTap: onTap,
      pressedScale: 0.97,
      borderRadius: BorderRadius.circular(AppRadii.sm),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.gold.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadii.sm),
          border: Border.all(color: AppColors.gold.withValues(alpha: 0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              code,
              maxLines: 1,
              style: theme.textTheme.titleMedium?.copyWith(
                color: AppColors.gold,
                // Wide tracking: this string gets typed into another phone
                // from a screenshot, so the characters have to stay separable.
                letterSpacing: 3,
                fontWeight: FontWeight.w800,
              ),
            ),
            if (onTap != null) ...[
              const SizedBox(width: 10),
              Icon(Icons.copy_rounded, size: 15, color: p.textFaint),
            ],
          ],
        ),
      ),
    );
  }
}
