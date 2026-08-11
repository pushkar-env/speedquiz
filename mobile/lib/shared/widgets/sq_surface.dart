import 'package:flutter/material.dart';
import 'package:speedquiz/core/theme/app_motion.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/core/utils/formatters.dart';
import 'package:speedquiz/shared/widgets/sq_press.dart';

/// The standard card surface: bordered, rounded, optionally highlighted, and
/// press-responsive when it carries an [onTap].
class SqSurface extends StatelessWidget {
  const SqSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.md),
    this.highlighted = false,
    this.onTap,
    this.accent,
    this.elevated = false,
    this.radius = AppRadii.md,
    this.gradient,
  });

  final Widget child;
  final EdgeInsets padding;
  final bool highlighted;
  final VoidCallback? onTap;

  /// Overrides the highlight colour (defaults to the brand accent).
  final Color? accent;
  final bool elevated;
  final double radius;
  final Gradient? gradient;

  @override
  Widget build(BuildContext context) {
    final p = context.sq;
    final tint = accent ?? p.accent;
    final border = highlighted ? tint.withValues(alpha: 0.65) : p.border;
    final background = highlighted
        ? tint.withValues(alpha: p.isDark ? 0.1 : 0.07)
        : (elevated ? p.surfaceElevated : p.surface);

    final content = AnimatedContainer(
      duration: AppMotion.fast,
      curve: AppMotion.standard,
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: gradient == null ? background : null,
        gradient: gradient,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: border, width: highlighted ? 1.5 : 1),
        boxShadow: elevated ? AppShadows.soft(p) : null,
      ),
      child: child,
    );

    if (onTap == null) return content;
    return SqPressable(
      onTap: onTap,
      pressedScale: 0.985,
      borderRadius: BorderRadius.circular(radius),
      child: content,
    );
  }
}

/// Section title with optional subtitle and trailing action.
class SqSectionHeader extends StatelessWidget {
  const SqSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
    this.leading,
  });

  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (leading != null) ...[leading!, const SizedBox(width: 10)],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleLarge),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
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

/// Pill badge — plan tiers, streak counts, "NEW BEST", difficulty tags.
class SqBadge extends StatelessWidget {
  const SqBadge({
    super.key,
    required this.label,
    this.color,
    this.icon,
    this.gradient,
    this.dense = false,
  });

  final String label;
  final Color? color;
  final IconData? icon;
  final Gradient? gradient;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = color ?? theme.sq.accent;
    final onGradient = gradient != null;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 8 : 11,
        vertical: dense ? 3 : 6,
      ),
      decoration: BoxDecoration(
        gradient: gradient,
        color: onGradient ? null : tint.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadii.pill),
        border: onGradient
            ? null
            : Border.all(color: tint.withValues(alpha: 0.38)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(
              icon,
              size: dense ? 11 : 13,
              color: onGradient ? Colors.black87 : tint,
            ),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: (dense ? theme.textTheme.labelSmall : theme.textTheme.labelMedium)
                ?.copyWith(
              color: onGradient ? Colors.black87 : tint,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }
}

/// Level + XP progress with an animated fill.
class SqXpBar extends StatelessWidget {
  const SqXpBar({
    super.key,
    required this.level,
    required this.xp,
    this.xpPerLevel,
    this.compact = false,
  });

  final int level;
  final int xp;
  final int? xpPerLevel;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final threshold = xpPerLevel ?? xpThresholdForLevel(level);
    final progress = threshold <= 0 ? 0.0 : (xp / threshold).clamp(0.0, 1.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!compact)
          Row(
            children: [
              Text('LEVEL $level', style: theme.textTheme.labelLarge),
              const Spacer(),
              Text('$xp / $threshold XP', style: theme.textTheme.bodySmall),
            ],
          ),
        if (!compact) const SizedBox(height: 8),
        SqProgressTrack(value: progress, height: compact ? 5 : 9),
        if (compact) ...[
          const SizedBox(height: 4),
          Text(
            'LVL $level · $xp/$threshold XP',
            style: theme.textTheme.labelSmall?.copyWith(color: p.textFaint),
          ),
        ],
      ],
    );
  }
}

/// Rounded gradient progress track with an animated fill.
class SqProgressTrack extends StatelessWidget {
  const SqProgressTrack({
    super.key,
    required this.value,
    this.height = 8,
    this.gradient,
    this.animate = true,
  });

  final double value;
  final double height;
  final Gradient? gradient;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final p = context.sq;
    final clamped = value.clamp(0.0, 1.0);

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadii.pill),
      child: Container(
        height: height,
        color: p.border.withValues(alpha: 0.6),
        child: Align(
          alignment: Alignment.centerLeft,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth * clamped;
              final bar = Container(
                height: height,
                width: width,
                decoration: BoxDecoration(
                  gradient: gradient ?? AppColors.brandGradient,
                  borderRadius: BorderRadius.circular(AppRadii.pill),
                ),
              );
              if (!animate) return bar;
              return AnimatedContainer(
                duration: AppMotion.normal,
                curve: AppMotion.enter,
                height: height,
                width: width,
                decoration: BoxDecoration(
                  gradient: gradient ?? AppColors.brandGradient,
                  borderRadius: BorderRadius.circular(AppRadii.pill),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Empty-state block used when a list or board has nothing to show.
class SqEmptyState extends StatelessWidget {
  const SqEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final String icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
      child: Column(
        children: [
          Container(
            width: 72,
            height: 72,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: p.accentWash(0.1),
              border: Border.all(color: p.accentWash(0.25)),
            ),
            child: Text(icon, style: const TextStyle(fontSize: 30)),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(title, style: theme.textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
          if (action != null) ...[
            const SizedBox(height: AppSpacing.lg),
            action!,
          ],
        ],
      ),
    );
  }
}

/// Consistent inline error block with a retry affordance.
class SqErrorState extends StatelessWidget {
  const SqErrorState({
    super.key,
    required this.message,
    this.onRetry,
    this.title = 'Something went wrong',
  });

  final String title;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SqSurface(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        children: [
          Container(
            width: 54,
            height: 54,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.danger.withValues(alpha: 0.12),
            ),
            child: const Icon(
              Icons.wifi_tethering_error_rounded,
              color: AppColors.danger,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            title,
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            message,
            style: theme.textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          if (onRetry != null) ...[
            const SizedBox(height: AppSpacing.md),
            SqRetryButton(onRetry: onRetry!),
          ],
        ],
      ),
    );
  }
}

/// Small standalone retry control (kept separate so [SqErrorState] stays
/// free of a dependency cycle with the button library).
class SqRetryButton extends StatelessWidget {
  const SqRetryButton({super.key, required this.onRetry, this.label = 'RETRY'});

  final VoidCallback onRetry;
  final String label;

  @override
  Widget build(BuildContext context) {
    final p = context.sq;
    return SqPressable(
      onTap: onRetry,
      pressedScale: 0.94,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color: p.accentWash(0.14),
          borderRadius: BorderRadius.circular(AppRadii.pill),
          border: Border.all(color: p.accentWash(0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.refresh_rounded, size: 16, color: p.accent),
            const SizedBox(width: 8),
            Text(
              label,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: p.accent,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
