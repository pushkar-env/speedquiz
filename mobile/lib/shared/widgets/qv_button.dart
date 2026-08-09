import 'package:flutter/material.dart';
import 'package:quizverse/core/theme/app_theme.dart';

class QvButton extends StatelessWidget {
  const QvButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.expand = true,
    this.loading = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool expand;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final child = loading
        ? const SizedBox(
            height: 22,
            width: 22,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          )
        : Text(label);
    final button = ElevatedButton(
      onPressed: loading ? null : onPressed,
      child: child,
    );
    if (!expand) return button;
    return SizedBox(width: double.infinity, height: 54, child: button);
  }
}

class QvGhostButton extends StatelessWidget {
  const QvGhostButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          side: BorderSide(
            color: dark ? AppColors.borderDark : AppColors.borderLight,
          ),
          foregroundColor: Theme.of(context).colorScheme.onSurface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.md),
          ),
        ),
        child: Text(label),
      ),
    );
  }
}

class QvSectionHeader extends StatelessWidget {
  const QvSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleLarge),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(subtitle!, style: theme.textTheme.bodyMedium),
              ],
            ],
          ),
        ),
        if (actionLabel != null)
          TextButton(onPressed: onAction, child: Text(actionLabel!)),
      ],
    );
  }
}

class QvSurface extends StatelessWidget {
  const QvSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.md),
    this.highlighted = false,
    this.onTap,
  });

  final Widget child;
  final EdgeInsets padding;
  final bool highlighted;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final border = highlighted
        ? AppColors.accent.withValues(alpha: 0.7)
        : (dark ? AppColors.borderDark : AppColors.borderLight);
    final bg = highlighted
        ? AppColors.accent.withValues(alpha: dark ? 0.1 : 0.08)
        : (dark ? AppColors.surfaceDark : AppColors.surfaceLight);

    final content = AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: border, width: highlighted ? 1.4 : 1),
      ),
      child: child,
    );

    if (onTap == null) return content;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.md),
        child: content,
      ),
    );
  }
}

class QvXpBar extends StatelessWidget {
  const QvXpBar({
    super.key,
    required this.level,
    required this.xp,
    this.xpPerLevel = 500,
  });

  final int level;
  final int xp;
  final int xpPerLevel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = (xp / xpPerLevel).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('LVL $level', style: theme.textTheme.labelLarge),
            const Spacer(),
            Text(
              '$xp / $xpPerLevel XP',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 8,
            backgroundColor: AppColors.borderDark.withValues(alpha: 0.35),
            color: AppColors.accent,
          ),
        ),
      ],
    );
  }
}

String formatScore(int score) {
  final s = score.abs().toString();
  final buf = StringBuffer(score < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    buf.write(s[i]);
    final remaining = s.length - i - 1;
    if (remaining > 0 && remaining % 3 == 0) buf.write(',');
  }
  return buf.toString();
}
