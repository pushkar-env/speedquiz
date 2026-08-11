import 'package:flutter/material.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
import 'package:speedquiz/core/theme/app_theme.dart';

enum SqToastTone { info, success, warning, error }

/// App-wide toast. Replaces bare `SnackBar` so every transient message gets
/// the same shape, icon, accent stripe and haptic.
abstract final class SqToast {
  static void show(
    BuildContext context,
    String message, {
    SqToastTone tone = SqToastTone.info,
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = const Duration(seconds: 3),
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;

    switch (tone) {
      case SqToastTone.success:
        Haptics.success();
      case SqToastTone.error:
        Haptics.error();
      case SqToastTone.warning:
      case SqToastTone.info:
        Haptics.tap();
    }

    final p = context.sq;
    final tint = _tint(tone, p);

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: duration,
          backgroundColor: Colors.transparent,
          elevation: 0,
          padding: EdgeInsets.zero,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            0,
            AppSpacing.md,
            AppSpacing.md,
          ),
          content: _ToastBody(
            message: message,
            tint: tint,
            icon: _icon(tone),
            actionLabel: actionLabel,
            onAction: onAction,
          ),
        ),
      );
  }

  static void success(BuildContext context, String message) =>
      show(context, message, tone: SqToastTone.success);

  static void error(
    BuildContext context,
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
  }) =>
      show(
        context,
        message,
        tone: SqToastTone.error,
        actionLabel: actionLabel,
        onAction: onAction,
        duration: const Duration(seconds: 4),
      );

  static void warning(BuildContext context, String message) =>
      show(context, message, tone: SqToastTone.warning);

  static void info(BuildContext context, String message) =>
      show(context, message);

  static Color _tint(SqToastTone tone, SqPalette p) {
    switch (tone) {
      case SqToastTone.info:
        return p.accent;
      case SqToastTone.success:
        return AppColors.success;
      case SqToastTone.warning:
        return AppColors.warning;
      case SqToastTone.error:
        return AppColors.danger;
    }
  }

  static IconData _icon(SqToastTone tone) {
    switch (tone) {
      case SqToastTone.info:
        return Icons.info_outline_rounded;
      case SqToastTone.success:
        return Icons.check_circle_outline_rounded;
      case SqToastTone.warning:
        return Icons.warning_amber_rounded;
      case SqToastTone.error:
        return Icons.error_outline_rounded;
    }
  }
}

class _ToastBody extends StatelessWidget {
  const _ToastBody({
    required this.message,
    required this.tint,
    required this.icon,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final Color tint;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadii.md),
      child: Container(
        decoration: BoxDecoration(
          color: p.surfaceElevated,
          borderRadius: BorderRadius.circular(AppRadii.md),
          border: Border.all(color: p.border),
          boxShadow: AppShadows.soft(p),
        ),
        child: IntrinsicHeight(
          child: Row(
            children: [
              Container(width: 4, color: tint),
              const SizedBox(width: 12),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Icon(icon, color: tint, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Text(
                    message,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: p.textPrimary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
              if (actionLabel != null)
                TextButton(
                  onPressed: () {
                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                    onAction?.call();
                  },
                  child: Text(
                    actionLabel!,
                    style: theme.textTheme.labelLarge?.copyWith(color: tint),
                  ),
                )
              else
                const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}
