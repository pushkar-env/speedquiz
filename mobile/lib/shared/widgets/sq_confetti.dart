import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:speedquiz/core/theme/app_theme.dart';

/// Lightweight custom-painted confetti burst — no plugin, no image assets.
///
/// Particles are generated once per burst and advanced by a single ticker
/// that stops itself when the animation completes, so an idle result screen
/// costs nothing.
class SqConfetti extends StatefulWidget {
  const SqConfetti({
    super.key,
    required this.play,
    this.particleCount = 70,
    this.duration = const Duration(milliseconds: 2600),
    this.colors,
    this.origin = const Alignment(0, -0.55),
  });

  /// Flip to true to fire a burst. Flipping back and forth re-fires.
  final bool play;
  final int particleCount;
  final Duration duration;
  final List<Color>? colors;

  /// Where the burst originates, in alignment space.
  final Alignment origin;

  @override
  State<SqConfetti> createState() => _SqConfettiState();
}

class _SqConfettiState extends State<SqConfetti>
    with SingleTickerProviderStateMixin {
  // Built eagerly, not lazily: a `late final` initialiser that only runs on a
  // burst would be evaluated for the first time inside dispose(), and creating
  // a Ticker there looks up TickerMode on an already-deactivated element.
  late final AnimationController _controller;

  List<_Particle> _particles = const [];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    // Deferred: _fire reads MediaQuery, which cannot be looked up in initState.
    if (widget.play) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _fire());
    }
  }

  @override
  void didUpdateWidget(covariant SqConfetti oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.play && !oldWidget.play) _fire();
  }

  void _fire() {
    if (!mounted) return;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return;
    final palette = widget.colors ??
        const [
          AppColors.accent,
          AppColors.cyan,
          AppColors.gold,
          AppColors.violet,
          AppColors.magenta,
        ];
    final random = math.Random();
    final particles = List.generate(widget.particleCount, (i) {
      // Fan the burst upward and outward, with a few stragglers.
      final angle = -math.pi / 2 + (random.nextDouble() - 0.5) * math.pi * 1.15;
      final speed = 0.55 + random.nextDouble() * 0.85;
      return _Particle(
        angle: angle,
        speed: speed,
        size: 5 + random.nextDouble() * 7,
        color: palette[i % palette.length],
        spin: (random.nextDouble() - 0.5) * 10,
        drift: (random.nextDouble() - 0.5) * 0.35,
        delay: random.nextDouble() * 0.18,
        rectangular: random.nextBool(),
      );
    });

    setState(() => _particles = particles);
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
    if (_particles.isEmpty) return const SizedBox.shrink();

    return IgnorePointer(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            if (_controller.isDismissed) return const SizedBox.shrink();
            return CustomPaint(
              size: Size.infinite,
              painter: _ConfettiPainter(
                progress: _controller.value,
                particles: _particles,
                origin: widget.origin,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _Particle {
  const _Particle({
    required this.angle,
    required this.speed,
    required this.size,
    required this.color,
    required this.spin,
    required this.drift,
    required this.delay,
    required this.rectangular,
  });

  final double angle;
  final double speed;
  final double size;
  final Color color;
  final double spin;
  final double drift;
  final double delay;
  final bool rectangular;
}

class _ConfettiPainter extends CustomPainter {
  const _ConfettiPainter({
    required this.progress,
    required this.particles,
    required this.origin,
  });

  final double progress;
  final List<_Particle> particles;
  final Alignment origin;

  @override
  void paint(Canvas canvas, Size size) {
    final start = origin.alongSize(size);
    final reach = size.height * 0.95;
    final gravity = size.height * 1.45;
    final paint = Paint();

    for (final particle in particles) {
      // Each particle runs on its own delayed 0..1 timeline.
      final t = ((progress - particle.delay) / (1 - particle.delay))
          .clamp(0.0, 1.0);
      if (t <= 0) continue;

      final vx = math.cos(particle.angle) * particle.speed;
      final vy = math.sin(particle.angle) * particle.speed;

      final dx = vx * reach * t + particle.drift * size.width * t * t;
      final dy = vy * reach * t + 0.5 * gravity * t * t;

      final position = start + Offset(dx, dy);
      if (position.dy > size.height + 40) continue;

      // Fade out over the last third of the flight.
      final fade = t < 0.66 ? 1.0 : 1 - ((t - 0.66) / 0.34);
      paint.color = particle.color.withValues(alpha: fade.clamp(0.0, 1.0));

      canvas.save();
      canvas.translate(position.dx, position.dy);
      canvas.rotate(particle.spin * t);
      if (particle.rectangular) {
        canvas.drawRect(
          Rect.fromCenter(
            center: Offset.zero,
            width: particle.size,
            height: particle.size * 0.55,
          ),
          paint,
        );
      } else {
        canvas.drawCircle(Offset.zero, particle.size * 0.4, paint);
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) => old.progress != progress;
}
