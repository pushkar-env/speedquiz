import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:speedquiz/core/theme/app_theme.dart';

/// Circular gauge used for the question timer and the profile level ring.
///
/// Paints a track plus a gradient sweep; the whole thing lives inside a
/// [RepaintBoundary] because the timer variant repaints ~10×/second.
class SqProgressRing extends StatefulWidget {
  const SqProgressRing({
    super.key,
    required this.value,
    this.size = 68,
    this.stroke = 6,
    this.gradient,
    this.trackColor,
    this.child,
    this.glow = false,
    this.fillFromZero = false,
    this.fillDuration = const Duration(milliseconds: 1100),
  });

  final double value;
  final double size;
  final double stroke;
  final Gradient? gradient;
  final Color? trackColor;
  final Widget? child;

  /// Adds a soft halo — used when the timer runs low.
  final bool glow;

  /// Sweep up from empty when this widget appears, instead of snapping to
  /// [value]. Reserved for progress the player *earned* — a level ring reads
  /// as a reward when it fills, and as a static graphic when it does not.
  ///
  /// Deliberately off by default: the question timer must show the truth on
  /// its very first frame, never a flourish.
  final bool fillFromZero;

  final Duration fillDuration;

  @override
  State<SqProgressRing> createState() => _SqProgressRingState();
}

class _SqProgressRingState extends State<SqProgressRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late Animation<double> _sweep;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.fillDuration);
    _sweep = _tween(0, widget.value);
  }

  Animation<double> _tween(double from, double to) {
    return Tween<double>(begin: from, end: to).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!widget.fillFromZero) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
    } else if (!_controller.isAnimating && _controller.value == 0) {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(SqProgressRing old) {
    super.didUpdateWidget(old);
    if (old.value == widget.value) return;
    if (!widget.fillFromZero) return;
    // Animate onwards from wherever the sweep currently sits, so a value that
    // changes mid-fill does not jump.
    _sweep = _tween(_sweep.value, widget.value);
    _controller
      ..reset()
      ..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.sq;
    final track = widget.trackColor ?? p.border.withValues(alpha: 0.7);
    final gradient = widget.gradient ?? AppColors.brandGradient;
    final child = widget.child == null ? null : Center(child: widget.child);

    return RepaintBoundary(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: widget.fillFromZero
            ? AnimatedBuilder(
                animation: _sweep,
                builder: (context, inner) => CustomPaint(
                  painter: _RingPainter(
                    value: _sweep.value.clamp(0.0, 1.0),
                    stroke: widget.stroke,
                    gradient: gradient,
                    track: track,
                    glow: widget.glow,
                  ),
                  child: inner,
                ),
                child: child,
              )
            : CustomPaint(
                painter: _RingPainter(
                  value: widget.value.clamp(0.0, 1.0),
                  stroke: widget.stroke,
                  gradient: gradient,
                  track: track,
                  glow: widget.glow,
                ),
                child: child,
              ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.value,
    required this.stroke,
    required this.gradient,
    required this.track,
    required this.glow,
  });

  final double value;
  final double stroke;
  final Gradient gradient;
  final Color track;
  final bool glow;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final inset = rect.deflate(stroke / 2);
    const startAngle = -math.pi / 2;
    final sweep = 2 * math.pi * value;

    final trackPaint = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(inset, 0, 2 * math.pi, false, trackPaint);

    if (value <= 0) return;

    if (glow) {
      final haloColor = gradient.colors.first;
      final halo = Paint()
        ..color = haloColor.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke * 2.2
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
      canvas.drawArc(inset, startAngle, sweep, false, halo);
    }

    final progress = Paint()
      ..shader = gradient.createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(inset, startAngle, sweep, false, progress);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.value != value ||
      old.stroke != stroke ||
      old.track != track ||
      old.glow != glow ||
      old.gradient != gradient;
}
