import 'package:flutter/material.dart';
import 'package:speedquiz/core/theme/app_theme.dart';

/// The SpeedQuiz brand mark: a gradient squircle with a bolt.
class SqLogoMark extends StatelessWidget {
  const SqLogoMark({super.key, this.size = 84, this.glow = true});

  final double size;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: AppColors.brandGradient,
        borderRadius: BorderRadius.circular(size * 0.3),
        boxShadow: glow
            ? AppShadows.glow(AppColors.accent, strength: 0.42)
            : null,
      ),
      child: Icon(
        Icons.bolt_rounded,
        size: size * 0.56,
        color: const Color(0xFF04110C),
      ),
    );
  }
}

/// The wordmark, painted with the brand gradient.
class SqWordmark extends StatelessWidget {
  const SqWordmark({super.key, this.fontSize = 40, this.gradient = true});

  final double fontSize;
  final bool gradient;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.displaySmall?.copyWith(
          fontSize: fontSize,
          fontWeight: FontWeight.w700,
          letterSpacing: -1.6,
          height: 1,
        );

    const text = Text(
      'SPEEDQUIZ',
      textAlign: TextAlign.center,
    );

    if (!gradient) return DefaultTextStyle.merge(style: style, child: text);

    return ShaderMask(
      shaderCallback: (bounds) => AppColors.brandGradient.createShader(bounds),
      blendMode: BlendMode.srcIn,
      child: Text(
        'SPEEDQUIZ',
        textAlign: TextAlign.center,
        style: style?.copyWith(color: Colors.white),
      ),
    );
  }
}

/// Slow vertical float, used to keep the landing/splash mark alive.
class SqFloat extends StatefulWidget {
  const SqFloat({
    super.key,
    required this.child,
    this.amplitude = 6,
    this.period = const Duration(milliseconds: 3600),
  });

  final Widget child;
  final double amplitude;
  final Duration period;

  @override
  State<SqFloat> createState() => _SqFloatState();
}

class _SqFloatState extends State<SqFloat> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.period,
  );

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
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_controller.value);
        return Transform.translate(
          offset: Offset(0, -widget.amplitude * t),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}
