import 'package:flutter/material.dart';
import 'package:speedquiz/core/feedback/audio_service.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
import 'package:speedquiz/core/theme/app_motion.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/shared/widgets/sq_glow.dart';
import 'package:speedquiz/shared/widgets/sq_press.dart';
import 'package:speedquiz/shared/widgets/sq_shake.dart';

enum SqButtonVariant {
  /// Gradient fill — one per screen, reserved for the primary action.
  primary,

  /// Solid surface with a border — secondary actions.
  ghost,

  /// Transparent with a tinted label — tertiary / dismissive actions.
  subtle,

  /// Destructive confirmation.
  danger,

  /// Premium / upgrade paths.
  gold,
}

/// The app's button. Press-scales, taps a haptic, and can shake itself to
/// reject an action without a modal.
class SqButton extends StatefulWidget {
  const SqButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.variant = SqButtonVariant.primary,
    this.expand = true,
    this.loading = false,
    this.icon,
    this.height = 54,
    this.haptic = true,
  });

  /// Convenience for the most common secondary button.
  const SqButton.ghost({
    super.key,
    required this.label,
    required this.onPressed,
    this.expand = true,
    this.loading = false,
    this.icon,
    this.height = 54,
    this.haptic = true,
  }) : variant = SqButtonVariant.ghost;

  final String label;
  final VoidCallback? onPressed;
  final SqButtonVariant variant;
  final bool expand;
  final bool loading;
  final IconData? icon;
  final double height;
  final bool haptic;

  @override
  State<SqButton> createState() => SqButtonState();
}

class SqButtonState extends State<SqButton> with SingleTickerProviderStateMixin {
  late final ShakeController _shake = ShakeController(vsync: this);

  /// Reject the current interaction: shake + error haptic. Reach it with a
  /// `GlobalKey<SqButtonState>` when validation fails.
  void reject() => _shake.shake();

  @override
  void dispose() {
    _shake.dispose();
    super.dispose();
  }

  bool get _disabled => widget.loading || widget.onPressed == null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final style = _resolve(p);

    final content = widget.loading
        ? SizedBox(
            height: 22,
            width: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              color: style.foreground,
            ),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 19, color: style.foreground),
                const SizedBox(width: 10),
              ],
              Flexible(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: style.foreground,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
            ],
          );

    final filled = style.gradient != null;

    final surface = AnimatedOpacity(
      duration: AppMotion.fast,
      opacity: _disabled ? 0.55 : 1,
      child: AnimatedContainer(
        duration: AppMotion.fast,
        curve: AppMotion.standard,
        height: widget.height,
        width: widget.expand ? double.infinity : null,
        padding: widget.expand
            ? null
            : const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: style.gradient,
          color: style.background,
          borderRadius: BorderRadius.circular(AppRadii.md),
          border: style.border == null
              ? null
              : Border.all(color: style.border!, width: 1.2),
          boxShadow: _disabled || style.glow == null
              ? null
              : AppShadows.glow(style.glow!, strength: 0.28),
        ),
        child: content,
      ),
    );

    return SqShake(
      controller: _shake,
      child: SqPressable(
        enabled: !_disabled,
        haptic: false,
        pressedScale: 0.97,
        semanticLabel: widget.label,
        onTap: _disabled
            ? null
            : () {
                if (widget.haptic) Haptics.press();
                Sound.tap();
                widget.onPressed!.call();
              },
        // Only the gradient variants catch the light; a ghost button glinting
        // would read as a loading state.
        child: SqSheen(
          active: filled && !_disabled,
          radius: AppRadii.md,
          child: surface,
        ),
      ),
    );
  }

  _ButtonStyle _resolve(SqPalette p) {
    switch (widget.variant) {
      case SqButtonVariant.primary:
        return const _ButtonStyle(
          gradient: AppColors.brandGradient,
          // Ink on the bright gradient in both themes — white would only
          // reach ~1.6:1 against mint.
          foreground: Color(0xFF04110C),
          glow: AppColors.accent,
        );
      case SqButtonVariant.ghost:
        return _ButtonStyle(
          background: p.surface,
          border: p.border,
          foreground: p.textPrimary,
        );
      case SqButtonVariant.subtle:
        return _ButtonStyle(
          background: p.accentWash(0.12),
          foreground: p.accent,
        );
      case SqButtonVariant.danger:
        return _ButtonStyle(
          background: AppColors.danger.withValues(alpha: 0.14),
          border: AppColors.danger.withValues(alpha: 0.5),
          foreground: AppColors.danger,
        );
      case SqButtonVariant.gold:
        return _ButtonStyle(
          gradient: AppColors.premiumGradient,
          foreground: const Color(0xFF201400),
          glow: AppColors.gold,
        );
    }
  }
}

class _ButtonStyle {
  const _ButtonStyle({
    required this.foreground,
    this.gradient,
    this.background,
    this.border,
    this.glow,
  });

  final Color foreground;
  final Gradient? gradient;
  final Color? background;
  final Color? border;
  final Color? glow;
}

/// Secondary button kept as a named widget for readability at call sites.
class SqGhostButton extends StatelessWidget {
  const SqGhostButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.expand = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    return SqButton(
      label: label,
      onPressed: onPressed,
      icon: icon,
      expand: expand,
      variant: SqButtonVariant.ghost,
    );
  }
}

/// Circular icon button used in headers and overlays.
class SqIconButton extends StatelessWidget {
  const SqIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.size = 42,
    this.color,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final p = context.sq;
    final button = SqPressable(
      onTap: onPressed,
      pressedScale: 0.9,
      semanticLabel: tooltip,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: p.surface.withValues(alpha: p.isDark ? 0.7 : 0.9),
          shape: BoxShape.circle,
          border: Border.all(color: p.border),
        ),
        child: Icon(icon, size: size * 0.46, color: color ?? p.textSecondary),
      ),
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}
