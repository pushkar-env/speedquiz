import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
import 'package:speedquiz/core/theme/app_motion.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/shared/widgets/sq_button.dart';

enum SqDialogTone { neutral, success, warning, danger }

/// Presents a SpeedQuiz dialog with a blurred scrim and a spring entrance.
///
/// [builder] receives the **dialog route's** context. Always pop with that
/// context: `Navigator.of(callerContext).pop()` resolves to the GoRouter
/// navigator and tears the current page off the route stack instead of
/// closing the dialog, which leaves the app on an empty (black) route.
Future<T?> showSqDialog<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool dismissible = true,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: dismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.transparent,
    transitionDuration: AppMotion.normal,
    pageBuilder: (dialogContext, _, _) => builder(dialogContext),
    transitionBuilder: (context, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: AppMotion.emphasized,
        reverseCurve: AppMotion.exit,
      );
      return _DialogShell(animation: curved, child: child);
    },
  );
}

class _DialogShell extends StatelessWidget {
  const _DialogShell({required this.animation, required this.child});

  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = context.sq;
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final t = animation.value;
        return Stack(
          children: [
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 8 * t, sigmaY: 8 * t),
                child: ColoredBox(
                  color: p.scrim.withValues(alpha: 0.72 * t),
                ),
              ),
            ),
            Opacity(
              opacity: t.clamp(0.0, 1.0),
              child: Transform.scale(
                scale: 0.9 + 0.1 * t,
                child: child,
              ),
            ),
          ],
        );
      },
      child: child,
    );
  }
}

/// The dialog body: optional glyph, title, message and stacked actions.
class SqDialog extends StatelessWidget {
  const SqDialog({
    super.key,
    required this.title,
    this.message,
    this.glyph,
    this.icon,
    this.tone = SqDialogTone.neutral,
    this.primaryLabel,
    this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
    this.content,
  });

  final String title;
  final String? message;

  /// Emoji shown in the header badge. Takes precedence over [icon].
  final String? glyph;
  final IconData? icon;
  final SqDialogTone tone;
  final String? primaryLabel;
  final VoidCallback? onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final Widget? content;

  Color _toneColor(SqPalette p) {
    switch (tone) {
      case SqDialogTone.neutral:
        return p.accent;
      case SqDialogTone.success:
        return AppColors.success;
      case SqDialogTone.warning:
        return AppColors.warning;
      case SqDialogTone.danger:
        return AppColors.danger;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final tint = _toneColor(p);

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.all(AppSpacing.lg),
              decoration: BoxDecoration(
                color: p.surfaceElevated,
                borderRadius: BorderRadius.circular(AppRadii.lg),
                border: Border.all(color: p.border),
                boxShadow: AppShadows.lifted(p),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (glyph != null || icon != null) ...[
                    Center(
                      child: Container(
                        width: 62,
                        height: 62,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: tint.withValues(alpha: 0.13),
                          border: Border.all(
                            color: tint.withValues(alpha: 0.32),
                          ),
                        ),
                        child: glyph != null
                            ? Text(
                                glyph!,
                                style: const TextStyle(fontSize: 27),
                              )
                            : Icon(icon, color: tint, size: 27),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                  ],
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall,
                  ),
                  if (message != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      message!,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                  if (content != null) ...[
                    const SizedBox(height: AppSpacing.md),
                    content!,
                  ],
                  if (primaryLabel != null) ...[
                    const SizedBox(height: AppSpacing.lg),
                    SqButton(
                      label: primaryLabel!,
                      variant: tone == SqDialogTone.danger
                          ? SqButtonVariant.danger
                          : SqButtonVariant.primary,
                      onPressed: onPrimary ??
                          () => Navigator.of(context).pop(),
                    ),
                  ],
                  if (secondaryLabel != null) ...[
                    const SizedBox(height: 10),
                    SqButton(
                      label: secondaryLabel!,
                      variant: SqButtonVariant.ghost,
                      onPressed: onSecondary ??
                          () => Navigator.of(context).pop(),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Yes/no confirmation. Resolves to `true` only when the user confirms.
Future<bool> showSqConfirm(
  BuildContext context, {
  required String title,
  required String message,
  String? confirmLabel,
  String? cancelLabel,
  SqDialogTone tone = SqDialogTone.neutral,
  String? glyph,
  IconData? icon,
}) async {
  final result = await showSqDialog<bool>(
    context,
    builder: (dialogContext) => SqDialog(
      title: title,
      message: message,
      tone: tone,
      glyph: glyph,
      icon: icon ?? (glyph == null ? Icons.help_outline_rounded : null),
      primaryLabel: confirmLabel ?? context.l10n.confirm,
      onPrimary: () {
        Haptics.press();
        Navigator.of(dialogContext).pop(true);
      },
      secondaryLabel: cancelLabel ?? context.l10n.cancel.toUpperCase(),
      onSecondary: () => Navigator.of(dialogContext).pop(false),
    ),
  );
  return result ?? false;
}

/// Informational popup with a single dismiss action.
Future<void> showSqInfo(
  BuildContext context, {
  required String title,
  required String message,
  String? actionLabel,
  SqDialogTone tone = SqDialogTone.neutral,
  String? glyph,
  IconData? icon,
}) {
  return showSqDialog<void>(
    context,
    builder: (dialogContext) => SqDialog(
      title: title,
      message: message,
      tone: tone,
      glyph: glyph,
      icon: icon,
      primaryLabel: actionLabel ?? context.l10n.gotIt,
      onPrimary: () => Navigator.of(dialogContext).pop(),
    ),
  );
}

/// Bottom sheet with the app's rounded top, drag handle and blurred scrim.
Future<T?> showSqSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool isScrollControlled = true,
}) {
  final p = context.sq;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    backgroundColor: Colors.transparent,
    barrierColor: p.scrim.withValues(alpha: 0.6),
    useSafeArea: true,
    builder: (context) => SqSheetShell(child: builder(context)),
  );
}

/// Chrome for a bottom sheet: rounded container, border and grab handle.
class SqSheetShell extends StatelessWidget {
  const SqSheetShell({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = context.sq;
    return Container(
      decoration: BoxDecoration(
        color: p.surfaceElevated,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadii.lg),
        ),
        border: Border(
          top: BorderSide(color: p.border),
          left: BorderSide(color: p.border),
          right: BorderSide(color: p.border),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 4),
            child: Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                color: p.border,
                borderRadius: BorderRadius.circular(AppRadii.pill),
              ),
            ),
          ),
          Flexible(child: child),
        ],
      ),
    );
  }
}
