import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/theme/app_theme.dart';

/// A living flame, for anything that represents a streak.
///
/// The 🔥 emoji it replaces is a still image, and a streak is the one number in
/// the app the player is actively trying to keep alive — it should look like it
/// could go out.
///
/// Built from a small set of hand-authored silhouettes that the painter
/// cross-fades and morphs between, rather than a sprite sheet: it stays crisp
/// at any size, tints itself from the theme, and costs no asset bytes. Three
/// layers move at different rates (outer body, inner core, rising embers) so
/// the loop never reads as a loop.
///
/// Set [alive] to false for a broken streak — the flame collapses to a dim
/// ember and stops ticking.
class SqFlame extends StatefulWidget {
  const SqFlame({
    super.key,
    this.size = 16,
    this.alive = true,
    this.intensity = 1.0,
  });

  final double size;

  /// False renders a cold ember and stops the ticker.
  final bool alive;

  /// Scales flicker amplitude. A long streak can burn harder.
  final double intensity;

  @override
  State<SqFlame> createState() => _SqFlameState();
}

class _SqFlameState extends State<SqFlame>
    with SingleTickerProviderStateMixin {
  // Eager for the same reason as the other animated primitives: with
  // reduce-motion on, dispose() must not be the first thing to build a Ticker.
  late final AnimationController _controller;
  bool _ticking = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      // Deliberately not a round number — a fire that repeats on the beat
      // looks mechanical.
      duration: const Duration(milliseconds: 1730),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(SqFlame old) {
    super.didUpdateWidget(old);
    if (old.alive != widget.alive) _sync();
  }

  void _sync() {
    final should = widget.alive && !MediaQuery.disableAnimationsOf(context);
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
    final ember = context.sq.textFaint;

    _FlamePainter painterAt(double phase) => _FlamePainter(
          phase: phase,
          alive: widget.alive,
          intensity: widget.intensity,
          ember: ember,
        );

    return RepaintBoundary(
      child: Semantics(
        label: widget.alive
            ? context.l10n.streakActive
            : context.l10n.streakInactive,
        child: SizedBox(
          width: widget.size,
          height: widget.size * 1.18,
          child: _ticking
              ? AnimatedBuilder(
                  animation: _controller,
                  builder: (context, _) =>
                      CustomPaint(painter: painterAt(_controller.value)),
                )
              // A still frame caught mid-flicker looks more like fire than a
              // symmetric one does.
              : CustomPaint(painter: painterAt(0.32)),
        ),
      ),
    );
  }
}

/// The flame silhouette at `phase`, for a box of `size`.
///
/// Exposed so tests can assert the shape fills its box: the failure mode that
/// matters is a body that occupies half its width and renders as a candle
/// wick, and that is invisible to a test which only checks the widget exists.
/// Rasterising instead would be the obvious approach, but the painter's
/// `MaskFilter.blur` halo needs GPU raster that the headless test engine does
/// not provide.
@visibleForTesting
Path debugFlameSilhouette(Size size, {double phase = 0.32}) {
  final (tip, waist, lean) = _FlamePainter._sample(phase);
  return _FlamePainter.bodyPath(size, tip, waist, lean, 1);
}

class _FlamePainter extends CustomPainter {
  const _FlamePainter({
    required this.phase,
    required this.alive,
    required this.intensity,
    required this.ember,
  });

  final double phase;
  final bool alive;
  final double intensity;
  final Color ember;

  /// Silhouette keyframes as (tipHeight, waistWidth, lean). The painter walks
  /// between them continuously, so four frames yield a smooth cycle.
  ///
  /// `waistWidth` is a fraction of the full box width and gets halved for each
  /// flank, so 0.9 fills ~90% of the box. Earlier values near 0.5 left the
  /// flame occupying half its width and reading as a thin candle rather than
  /// fire — at a 13px chip that difference is the whole silhouette.
  static const _frames = <(double, double, double)>[
    (0.98, 0.92, 0.00),
    (0.86, 1.00, 0.06),
    (0.94, 0.88, -0.05),
    (0.82, 1.02, 0.03),
  ];

  static (double, double, double) _sample(double t) {
    final scaled = t * _frames.length;
    final i = scaled.floor() % _frames.length;
    final next = (i + 1) % _frames.length;
    // Smoothstep between frames so the silhouette eases rather than snaps.
    final raw = scaled - scaled.floor();
    final f = raw * raw * (3 - 2 * raw);
    final a = _frames[i];
    final b = _frames[next];
    return (
      a.$1 + (b.$1 - a.$1) * f,
      a.$2 + (b.$2 - a.$2) * f,
      a.$3 + (b.$3 - a.$3) * f,
    );
  }

  /// One teardrop flame body, built from the sampled silhouette.
  static Path bodyPath(
    Size size,
    double tip,
    double waist,
    double lean,
    double scale,
  ) {
    final w = size.width;
    final h = size.height;
    final cx = w / 2 + lean * w * 0.16;
    final top = h * (1 - tip * scale);
    final halfWaist = w * waist * 0.5 * scale;
    final baseY = h * 0.98;

    final span = baseY - top;

    return Path()
      ..moveTo(cx, top)
      // Right flank: narrow at the tip, widest just below centre, then curls
      // under to a broad rounded base — a teardrop, not a candle wick.
      ..cubicTo(
        cx + halfWaist * 0.55, top + span * 0.22,
        cx + halfWaist, top + span * 0.55,
        cx + halfWaist * 0.92, baseY - span * 0.12,
      )
      // Base: a full round bottom, which is what reads as "fire" at 13px.
      ..cubicTo(
        cx + halfWaist * 0.86, baseY + span * 0.10,
        cx - halfWaist * 0.86, baseY + span * 0.10,
        cx - halfWaist * 0.92, baseY - span * 0.12,
      )
      // Left flank back up to the tip.
      ..cubicTo(
        cx - halfWaist, top + span * 0.55,
        cx - halfWaist * 0.55, top + span * 0.22,
        cx, top,
      )
      ..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    if (!alive) {
      // Cold streak: a dim, still ember. No flame, no motion.
      final (tip, waist, lean) = _sample(0.2);
      canvas.drawPath(
        bodyPath(size, tip * 0.55, waist, lean, 1),
        Paint()..color = ember.withValues(alpha: 0.45),
      );
      return;
    }

    final rect = Offset.zero & size;
    final (tip, waist, lean) = _sample(phase);
    final amp = intensity.clamp(0.0, 2.0);

    // Outer body — the orange mass.
    final outer = bodyPath(size, tip, waist, lean * amp, 1);
    canvas.drawPath(
      outer,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            Color(0xFFFF4D2D),
            AppColors.gold,
            Color(0xFFFFE29A),
          ],
          stops: [0.0, 0.55, 1.0],
        ).createShader(rect),
    );

    // Halo, so the flame throws light rather than sitting flat on the surface.
    canvas.drawPath(
      outer,
      Paint()
        ..color = AppColors.gold.withValues(alpha: 0.30)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, size.width * 0.22),
    );

    // Inner core — runs a half-cycle out of phase with the body, which is what
    // makes the fire look like it is churning instead of pulsing.
    final (coreTip, coreWaist, coreLean) = _sample((phase + 0.5) % 1.0);
    canvas.drawPath(
      bodyPath(size, coreTip * 0.62, coreWaist * 0.62, coreLean * amp, 1),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xFFFFF3C4), Color(0xFFFFFFFF)],
        ).createShader(rect),
    );

    // Two embers rising and fading on their own loops.
    for (var i = 0; i < 2; i++) {
      final t = (phase * (1.4 + i * 0.5) + i * 0.5) % 1.0;
      final ex = size.width * (0.36 + 0.28 * i) +
          math.sin(t * math.pi * 2 + i) * size.width * 0.08;
      final ey = size.height * (0.72 - t * 0.72);
      final alpha = (1 - t) * 0.75;
      if (alpha <= 0.02) continue;
      canvas.drawCircle(
        Offset(ex, ey),
        size.width * 0.045 * (1 - t * 0.4),
        Paint()..color = AppColors.gold.withValues(alpha: alpha),
      );
    }
  }

  @override
  bool shouldRepaint(_FlamePainter old) =>
      old.phase != phase ||
      old.alive != alive ||
      old.intensity != intensity ||
      old.ember != ember;
}
