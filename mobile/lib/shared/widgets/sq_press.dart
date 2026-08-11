import 'package:flutter/material.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
import 'package:speedquiz/core/theme/app_motion.dart';

/// Wraps any widget with a physical press response: scales down on pointer
/// down, springs back on release, and fires a haptic tick.
///
/// This is the single source of "things feel alive when you touch them" —
/// buttons, cards, chips and tiles all route through it.
class SqPressable extends StatefulWidget {
  const SqPressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.pressedScale = 0.96,
    this.haptic = true,
    this.borderRadius,
    this.enabled = true,
    this.semanticLabel,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Scale applied while held. Larger surfaces want a subtler value.
  final double pressedScale;
  final bool haptic;
  final BorderRadius? borderRadius;
  final bool enabled;
  final String? semanticLabel;

  @override
  State<SqPressable> createState() => _SqPressableState();
}

class _SqPressableState extends State<SqPressable>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.instant,
    reverseDuration: const Duration(milliseconds: 220),
    lowerBound: 0,
    upperBound: 1,
  );

  late final Animation<double> _scale = _controller.drive(
    Tween<double>(begin: 1, end: widget.pressedScale)
        .chain(CurveTween(curve: Curves.easeOut)),
  );

  bool get _interactive =>
      widget.enabled && (widget.onTap != null || widget.onLongPress != null);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _down(_) {
    if (!_interactive) return;
    _controller.forward();
  }

  void _up([_]) {
    if (!_controller.isDismissed) _controller.reverse();
  }

  void _tap() {
    if (!_interactive || widget.onTap == null) return;
    if (widget.haptic) Haptics.tap();
    widget.onTap!.call();
  }

  void _longPress() {
    if (!_interactive || widget.onLongPress == null) return;
    if (widget.haptic) Haptics.press();
    widget.onLongPress!.call();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: _interactive,
      label: widget.semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: _down,
        onTapUp: _up,
        onTapCancel: _up,
        onTap: _tap,
        onLongPress: widget.onLongPress == null ? null : _longPress,
        child: ScaleTransition(scale: _scale, child: widget.child),
      ),
    );
  }
}
