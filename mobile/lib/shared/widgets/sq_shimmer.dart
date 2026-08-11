import 'package:flutter/material.dart';
import 'package:speedquiz/core/theme/app_theme.dart';

/// Sweeping highlight used for loading skeletons.
///
/// One controller drives the whole subtree, so a screen full of placeholders
/// costs a single ticker.
class SqShimmer extends StatefulWidget {
  const SqShimmer({super.key, required this.child, this.enabled = true});

  final Widget child;
  final bool enabled;

  @override
  State<SqShimmer> createState() => _SqShimmerState();
}

class _SqShimmerState extends State<SqShimmer>
    with SingleTickerProviderStateMixin {
  // Eager, not lazy — see the note in SqConfetti: a controller first created
  // inside dispose() would try to read TickerMode off a dead element.
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    if (widget.enabled) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant SqShimmer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.enabled && _controller.isAnimating) {
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
    if (!widget.enabled || MediaQuery.disableAnimationsOf(context)) {
      return widget.child;
    }
    final p = context.sq;
    final highlight = (p.isDark ? Colors.white : Colors.black)
        .withValues(alpha: p.isDark ? 0.07 : 0.05);

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return ShaderMask(
            blendMode: BlendMode.srcATop,
            shaderCallback: (bounds) {
              final dx = bounds.width * (_controller.value * 2 - 0.5);
              return LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  Colors.transparent,
                  highlight,
                  Colors.transparent,
                ],
                stops: const [0.35, 0.5, 0.65],
                transform: _SlideGradient(dx / bounds.width),
              ).createShader(bounds);
            },
            child: child,
          );
        },
        child: widget.child,
      ),
    );
  }
}

class _SlideGradient extends GradientTransform {
  const _SlideGradient(this.ratio);

  final double ratio;

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(bounds.width * ratio, 0, 0);
  }
}

/// Grey block placeholder. Compose these inside a [SqShimmer].
class SqSkeleton extends StatelessWidget {
  const SqSkeleton({
    super.key,
    this.width,
    this.height = 14,
    this.radius = AppRadii.sm,
  });

  const SqSkeleton.circle({super.key, required double size})
      : width = size,
        height = size,
        radius = AppRadii.pill;

  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final p = context.sq;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: p.isDark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.black.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// Card-shaped skeleton matching [SqSurface] geometry.
class SqSkeletonCard extends StatelessWidget {
  const SqSkeletonCard({super.key, this.height = 76, this.lines = 2});

  final double height;
  final int lines;

  @override
  Widget build(BuildContext context) {
    final p = context.sq;
    return Container(
      height: height,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: p.border),
      ),
      child: Row(
        children: [
          const SqSkeleton(width: 44, height: 44, radius: AppRadii.sm),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < lines; i++) ...[
                  if (i > 0) const SizedBox(height: 8),
                  SqSkeleton(width: i == 0 ? 130 : 90, height: i == 0 ? 13 : 11),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
