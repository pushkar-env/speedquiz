import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:speedquiz/core/theme/app_theme.dart';

/// Circular gauge used for the question timer and the profile level ring.
///
/// Paints a track plus a gradient sweep; the whole thing lives inside a
/// [RepaintBoundary] because the timer variant repaints ~10×/second.
class SqProgressRing extends StatelessWidget {
  const SqProgressRing({
    super.key,
    required this.value,
    this.size = 68,
    this.stroke = 6,
    this.gradient,
    this.trackColor,
    this.child,
    this.glow = false,
  });

  final double value;
  final double size;
  final double stroke;
  final Gradient? gradient;
  final Color? trackColor;
  final Widget? child;

  /// Adds a soft halo — used when the timer runs low.
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final p = context.sq;
    return RepaintBoundary(
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _RingPainter(
            value: value.clamp(0.0, 1.0),
            stroke: stroke,
            gradient: gradient ?? AppColors.brandGradient,
            track: trackColor ?? p.border.withValues(alpha: 0.7),
            glow: glow,
          ),
          child: child == null ? null : Center(child: child),
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
