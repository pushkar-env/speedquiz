import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:speedquiz/core/theme/app_theme.dart';

/// Soft points of light drifting around the edge of a rounded rectangle.
///
/// Sits behind [SqGlowBorder] in the hierarchy of "look at this": the glow
/// border says *this is important*, the particles say *this is alive*. Used on
/// the profile identity card, where the player lands often enough that a
/// completely still panel starts to read as a screenshot.
///
/// Each particle walks the border path at its own speed with a comet tail
/// behind it, so the motion never resolves into an obvious rotating ring. The
/// whole thing is one ticker and one [CustomPaint] inside a [RepaintBoundary] —
/// cheap enough to leave running under a scrolling list.
///
/// Honours the platform reduce-motion setting by painting nothing at all.
class SqParticleBorder extends StatefulWidget {
  const SqParticleBorder({
    super.key,
    required this.child,
    this.radius = AppRadii.lg,
    this.colors,
    this.count = 4,
    this.period = const Duration(seconds: 11),
    this.active = true,
    this.particleSize = 2.6,
    this.tailLength = 0.09,
  });

  final Widget child;
  final double radius;

  /// Palette cycled across particles. Defaults to the brand ramp.
  final List<Color>? colors;

  /// How many lights orbit at once. Above ~6 it stops reading as sparkle and
  /// starts reading as a dotted border.
  final int count;

  /// Time for the slowest particle to complete one lap.
  final Duration period;

  final bool active;
  final double particleSize;

  /// Tail length as a fraction of the perimeter.
  final double tailLength;

  @override
  State<SqParticleBorder> createState() => _SqParticleBorderState();
}

class _SqParticleBorderState extends State<SqParticleBorder>
    with SingleTickerProviderStateMixin {
  // Eager, never lazy: with reduce-motion on, nothing else touches the
  // controller, so a lazy initialiser would first run inside dispose() and
  // build a Ticker on an already-deactivated element.
  late final AnimationController _controller;
  bool _ticking = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.period);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(SqParticleBorder old) {
    super.didUpdateWidget(old);
    if (old.active != widget.active) _sync();
  }

  void _sync() {
    final should = widget.active && !MediaQuery.disableAnimationsOf(context);
    if (should == _ticking) return;
    _ticking = should;
    if (should) {
      _controller.repeat();
    } else {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ticking) return widget.child;

    final colors = widget.colors ??
        const [
          AppColors.accent,
          AppColors.cyan,
          AppColors.violet,
          AppColors.magenta,
        ];

    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) => CustomPaint(
                  painter: _ParticleBorderPainter(
                    progress: _controller.value,
                    colors: colors,
                    radius: widget.radius,
                    count: widget.count,
                    particleSize: widget.particleSize,
                    tailLength: widget.tailLength,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ParticleBorderPainter extends CustomPainter {
  const _ParticleBorderPainter({
    required this.progress,
    required this.colors,
    required this.radius,
    required this.count,
    required this.particleSize,
    required this.tailLength,
  });

  final double progress;
  final List<Color> colors;
  final double radius;
  final int count;
  final double particleSize;
  final double tailLength;

  /// Tail samples. Enough to read as a smooth streak, few enough that four
  /// particles stay well under a millisecond per frame.
  static const _tailSteps = 9;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final rect = Offset.zero & size;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          rect.deflate(0.5),
          Radius.circular(radius),
        ),
      );

    final metrics = path.computeMetrics().toList();
    if (metrics.isEmpty) return;
    final metric = metrics.first;
    final length = metric.length;
    if (length <= 0) return;

    for (var i = 0; i < count; i++) {
      final color = colors[i % colors.length];

      // Stagger start positions, and give each particle a slightly different
      // lap time so they drift apart instead of holding formation.
      final speed = 1.0 + (i % 3) * 0.22;
      final offset = i / count;
      final head = ((progress * speed) + offset) % 1.0;

      // Fade the whole particle in and out across its lap so lights appear and
      // vanish rather than looping visibly.
      final life = math.sin(head * math.pi * 2).abs() * 0.65 + 0.35;

      for (var s = _tailSteps; s >= 0; s--) {
        final t = s / _tailSteps;
        final at = (head - t * tailLength + 1.0) % 1.0;
        final tangent = metric.getTangentForOffset(at * length);
        if (tangent == null) continue;

        // Head is brightest and largest; the tail thins as it trails away.
        final falloff = (1 - t) * (1 - t);
        final alpha = (falloff * life).clamp(0.0, 1.0);
        if (alpha <= 0.01) continue;

        final dotSize = particleSize * (0.35 + 0.65 * falloff);

        canvas.drawCircle(
          tangent.position,
          dotSize * 2.6,
          Paint()
            ..color = color.withValues(alpha: alpha * 0.30)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
        );
        canvas.drawCircle(
          tangent.position,
          dotSize,
          Paint()..color = color.withValues(alpha: alpha * 0.95),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_ParticleBorderPainter old) =>
      old.progress != progress ||
      old.colors != colors ||
      old.radius != radius ||
      old.count != count;
}
