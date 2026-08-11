import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:speedquiz/core/theme/app_theme.dart';

/// Ambient animated background: slow-orbiting colour blooms over the base
/// gradient. Gives every screen depth without competing with content.
///
/// Respects the platform "reduce motion" setting — when animations are
/// disabled the blooms are painted once and never ticked.
class SqBackdrop extends StatefulWidget {
  const SqBackdrop({
    super.key,
    required this.child,
    this.intensity = 1,
    this.colors,
  });

  final Widget child;

  /// 0 hides the blooms entirely; 1 is the default ambience.
  final double intensity;

  /// Overrides the bloom palette (defaults to brand + violet + cyan).
  final List<Color>? colors;

  @override
  State<SqBackdrop> createState() => _SqBackdropState();
}

class _SqBackdropState extends State<SqBackdrop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 24),
  );

  bool _ticking = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final shouldTick = !reduceMotion && widget.intensity > 0;
    if (shouldTick == _ticking) return;
    _ticking = shouldTick;
    if (shouldTick) {
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
    final p = context.sq;
    final colors = widget.colors ??
        const [AppColors.accent, AppColors.violet, AppColors.cyan];

    return DecoratedBox(
      decoration: BoxDecoration(gradient: p.backgroundGradient),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (widget.intensity > 0)
            RepaintBoundary(
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) => CustomPaint(
                  painter: _BloomPainter(
                    progress: _controller.value,
                    colors: colors,
                    intensity: widget.intensity * (p.isDark ? 1 : 0.55),
                  ),
                ),
              ),
            ),
          widget.child,
        ],
      ),
    );
  }
}

class _BloomPainter extends CustomPainter {
  const _BloomPainter({
    required this.progress,
    required this.colors,
    required this.intensity,
  });

  final double progress;
  final List<Color> colors;
  final double intensity;

  @override
  void paint(Canvas canvas, Size size) {
    // Three blooms drifting on slow, offset elliptical paths.
    const orbits = [
      _Orbit(cx: 0.18, cy: 0.12, rx: 0.16, ry: 0.10, radius: 0.62, phase: 0.0),
      _Orbit(cx: 0.86, cy: 0.30, rx: 0.13, ry: 0.14, radius: 0.54, phase: 0.42),
      _Orbit(cx: 0.42, cy: 0.88, rx: 0.18, ry: 0.09, radius: 0.70, phase: 0.75),
    ];

    for (var i = 0; i < orbits.length; i++) {
      final orbit = orbits[i];
      final angle = (progress + orbit.phase) * 2 * math.pi;
      final center = Offset(
        (orbit.cx + math.cos(angle) * orbit.rx) * size.width,
        (orbit.cy + math.sin(angle) * orbit.ry) * size.height,
      );
      final radius = orbit.radius * size.shortestSide;
      final color = colors[i % colors.length];

      final paint = Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: 0.20 * intensity),
            color.withValues(alpha: 0.07 * intensity),
            color.withValues(alpha: 0),
          ],
          stops: const [0, 0.45, 1],
        ).createShader(Rect.fromCircle(center: center, radius: radius));

      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(_BloomPainter old) =>
      old.progress != progress ||
      old.intensity != intensity ||
      old.colors != colors;
}

class _Orbit {
  const _Orbit({
    required this.cx,
    required this.cy,
    required this.rx,
    required this.ry,
    required this.radius,
    required this.phase,
  });

  final double cx;
  final double cy;
  final double rx;
  final double ry;
  final double radius;
  final double phase;
}
