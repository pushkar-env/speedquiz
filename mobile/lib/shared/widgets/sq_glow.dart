import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:speedquiz/core/theme/app_theme.dart';

/// A rounded surface wrapped in a slowly rotating gradient border, with a soft
/// bloom bleeding outwards.
///
/// This is the app's "this one matters" treatment — the play hero, a selected
/// mode, a fresh unlock. Used sparingly: if everything glows, nothing does.
///
/// Honours the platform reduce-motion setting by painting a still border and
/// never starting a ticker.
class SqGlowBorder extends StatefulWidget {
  const SqGlowBorder({
    super.key,
    required this.child,
    this.colors,
    this.radius = AppRadii.lg,
    this.thickness = 1.5,
    this.glow = 0.3,
    this.period = const Duration(seconds: 7),
    this.active = true,
  });

  final Widget child;

  /// Sweep palette. Defaults to the brand ramp.
  final List<Color>? colors;

  final double radius;
  final double thickness;

  /// Strength of the outer bloom, 0 disables it.
  final double glow;

  final Duration period;

  /// When false the border fades out entirely — lets a card animate between
  /// "selected" and "not" without swapping widgets.
  final bool active;

  @override
  State<SqGlowBorder> createState() => _SqGlowBorderState();
}

class _SqGlowBorderState extends State<SqGlowBorder>
    with SingleTickerProviderStateMixin {
  // Eager, never `late`-lazy: with reduce-motion on nothing else touches the
  // controller, so a lazy initialiser would first run inside dispose() and
  // create a Ticker on an already-deactivated element.
  late final AnimationController _spin;

  bool _ticking = false;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(vsync: this, duration: widget.period);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(SqGlowBorder old) {
    super.didUpdateWidget(old);
    if (old.active != widget.active) _sync();
  }

  void _sync() {
    final should =
        widget.active && !MediaQuery.disableAnimationsOf(context);
    if (should == _ticking) return;
    _ticking = should;
    if (should) {
      _spin.repeat();
    } else {
      _spin.stop();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors ??
        const [
          AppColors.accent,
          AppColors.cyan,
          AppColors.violet,
          AppColors.accent,
        ];

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _spin,
        builder: (context, child) => CustomPaint(
          foregroundPainter: _GlowBorderPainter(
            progress: _spin.value,
            colors: colors,
            radius: widget.radius,
            thickness: widget.thickness,
            glow: widget.active ? widget.glow : 0,
            opacity: widget.active ? 1 : 0,
          ),
          child: child,
        ),
        child: widget.child,
      ),
    );
  }
}

class _GlowBorderPainter extends CustomPainter {
  const _GlowBorderPainter({
    required this.progress,
    required this.colors,
    required this.radius,
    required this.thickness,
    required this.glow,
    required this.opacity,
  });

  final double progress;
  final List<Color> colors;
  final double radius;
  final double thickness;
  final double glow;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity <= 0) return;

    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(thickness / 2),
      Radius.circular(radius),
    );
    final shader = SweepGradient(
      colors: [
        for (final c in colors) c.withValues(alpha: c.a * opacity),
      ],
      transform: GradientRotation(progress * 2 * math.pi),
    ).createShader(rect);

    if (glow > 0) {
      // Bloom first, so the crisp border sits on top of its own halo.
      canvas.drawRRect(
        rrect,
        Paint()
          ..shader = shader
          ..style = PaintingStyle.stroke
          ..strokeWidth = thickness * 3.2
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 7 * glow + 2)
          ..color = Colors.white.withValues(alpha: glow * opacity),
      );
    }

    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = shader
        ..style = PaintingStyle.stroke
        ..strokeWidth = thickness,
    );
  }

  @override
  bool shouldRepaint(_GlowBorderPainter old) =>
      old.progress != progress ||
      old.opacity != opacity ||
      old.glow != glow ||
      old.colors != colors;
}

/// A light sweep that crosses a surface every few seconds, the way a highlight
/// travels over polished metal. Idle for most of its cycle so it reads as a
/// glint rather than a loading shimmer.
class SqSheen extends StatefulWidget {
  const SqSheen({
    super.key,
    required this.child,
    this.radius = AppRadii.md,
    this.period = const Duration(milliseconds: 4200),
    this.strength = 0.22,
    this.active = true,
  });

  final Widget child;
  final double radius;
  final Duration period;

  /// Peak opacity of the travelling highlight.
  final double strength;
  final bool active;

  @override
  State<SqSheen> createState() => _SqSheenState();
}

class _SqSheenState extends State<SqSheen>
    with SingleTickerProviderStateMixin {
  // See the note in [_SqGlowBorderState]: built eagerly so dispose() never
  // becomes the first thing to create the Ticker.
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
  void didUpdateWidget(SqSheen old) {
    super.didUpdateWidget(old);
    if (old.active != widget.active) _sync();
  }

  void _sync() {
    final should =
        widget.active && !MediaQuery.disableAnimationsOf(context);
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

    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(widget.radius),
              child: RepaintBoundary(
                child: AnimatedBuilder(
                  animation: _controller,
                  builder: (context, _) {
                    // The glint occupies the first third of the cycle; the
                    // rest is deliberately empty.
                    final t = const Interval(
                      0,
                      0.34,
                      curve: Curves.easeInOut,
                    ).transform(_controller.value);
                    if (t <= 0 || t >= 1) return const SizedBox.shrink();

                    return FractionallySizedBox(
                      widthFactor: 0.45,
                      alignment: Alignment(-2.2 + 4.4 * t, 0),
                      child: Transform.rotate(
                        angle: -0.35,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                Colors.white.withValues(alpha: 0),
                                Colors.white.withValues(
                                  alpha: widget.strength *
                                      math.sin(t * math.pi),
                                ),
                                Colors.white.withValues(alpha: 0),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Slow scale pulse. For anything that should look alive while it waits —
/// a ready badge, a call to action nobody has tapped yet.
class SqBreathe extends StatefulWidget {
  const SqBreathe({
    super.key,
    required this.child,
    this.scale = 0.02,
    this.period = const Duration(milliseconds: 2800),
  });

  final Widget child;

  /// How far past 1.0 the pulse travels.
  final double scale;
  final Duration period;

  @override
  State<SqBreathe> createState() => _SqBreatheState();
}

class _SqBreatheState extends State<SqBreathe>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.period);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) => Transform.scale(
          scale: 1 + widget.scale * Curves.easeInOut.transform(_controller.value),
          child: child,
        ),
        child: widget.child,
      ),
    );
  }
}
