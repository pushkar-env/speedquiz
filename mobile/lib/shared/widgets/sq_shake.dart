import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:speedquiz/core/feedback/haptics.dart';

/// Drives a decaying horizontal shake on a [SqShake] subtree.
///
/// Held by the owning `State` and disposed with it:
/// ```dart
/// final _shake = ShakeController(vsync: this);
/// ...
/// SqShake(controller: _shake, child: ...)
/// ...
/// _shake.shake();
/// ```
class ShakeController extends ChangeNotifier {
  ShakeController({required TickerProvider vsync})
      : _controller = AnimationController(
          vsync: vsync,
          duration: const Duration(milliseconds: 480),
        ) {
    _controller.addListener(notifyListeners);
  }

  final AnimationController _controller;
  double _amplitude = 10;

  /// 0..1 progress of the current shake.
  double get value => _controller.value;

  /// Current horizontal offset in logical pixels.
  double get offset {
    if (_controller.isDismissed) return 0;
    // Four oscillations that decay to zero, so it settles instead of snapping.
    final decay = 1 - _controller.value;
    return math.sin(_controller.value * math.pi * 8) * _amplitude * decay;
  }

  /// Play the shake. [amplitude] tunes how violent it feels.
  void shake({double amplitude = 10, bool haptic = true}) {
    _amplitude = amplitude;
    if (haptic) Haptics.error();
    _controller
      ..reset()
      ..forward();
  }

  @override
  void dispose() {
    _controller
      ..removeListener(notifyListeners)
      ..dispose();
    super.dispose();
  }
}

/// Applies the horizontal offset from [controller] to [child].
class SqShake extends StatelessWidget {
  const SqShake({super.key, required this.controller, required this.child});

  final ShakeController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) => Transform.translate(
        offset: Offset(controller.offset, 0),
        child: child,
      ),
      child: child,
    );
  }
}

/// Self-contained shake for widgets that should nudge whenever a boolean
/// trigger flips — no controller plumbing needed at the call site.
class SqShakeOnChange extends StatefulWidget {
  const SqShakeOnChange({
    super.key,
    required this.trigger,
    required this.child,
    this.amplitude = 10,
    this.haptic = true,
  });

  /// Every distinct non-null value plays one shake.
  final Object? trigger;
  final double amplitude;
  final bool haptic;
  final Widget child;

  @override
  State<SqShakeOnChange> createState() => _SqShakeOnChangeState();
}

class _SqShakeOnChangeState extends State<SqShakeOnChange>
    with SingleTickerProviderStateMixin {
  late final ShakeController _shake = ShakeController(vsync: this);

  @override
  void didUpdateWidget(covariant SqShakeOnChange oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.trigger != oldWidget.trigger && widget.trigger != null) {
      _shake.shake(amplitude: widget.amplitude, haptic: widget.haptic);
    }
  }

  @override
  void dispose() {
    _shake.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SqShake(controller: _shake, child: widget.child);
}
