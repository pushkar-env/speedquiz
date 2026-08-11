import 'package:flutter/material.dart';
import 'package:speedquiz/core/theme/app_motion.dart';
import 'package:speedquiz/core/utils/formatters.dart';

/// A number that rolls up to its new value instead of snapping.
///
/// Used for scores, XP and coins — the roll is what makes a result screen
/// feel like a reward rather than a receipt.
class SqAnimatedCounter extends StatelessWidget {
  const SqAnimatedCounter({
    super.key,
    required this.value,
    this.style,
    this.duration = AppMotion.slow,
    this.curve = AppMotion.enter,
    this.prefix = '',
    this.suffix = '',
    this.grouped = true,
    this.textAlign,
  });

  final int value;
  final TextStyle? style;
  final Duration duration;
  final Curve curve;
  final String prefix;
  final String suffix;

  /// Thousands separators.
  final bool grouped;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: value.toDouble()),
      duration: duration,
      curve: curve,
      builder: (context, animated, _) {
        final rounded = animated.round();
        final body = grouped ? formatScore(rounded) : '$rounded';
        return Text(
          '$prefix$body$suffix',
          style: style,
          textAlign: textAlign,
        );
      },
    );
  }
}

/// A value that pops when it changes — used for the live score and streak in
/// the gameplay HUD.
class SqPopCounter extends StatefulWidget {
  const SqPopCounter({
    super.key,
    required this.value,
    this.style,
    this.grouped = true,
    this.prefix = '',
  });

  final int value;
  final TextStyle? style;
  final bool grouped;
  final String prefix;

  @override
  State<SqPopCounter> createState() => _SqPopCounterState();
}

class _SqPopCounterState extends State<SqPopCounter>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 340),
    value: 1,
  );

  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 1, end: 1.18), weight: 40),
    TweenSequenceItem(
      tween: Tween<double>(begin: 1.18, end: 1)
          .chain(CurveTween(curve: AppMotion.spring)),
      weight: 60,
    ),
  ]).animate(_controller);

  @override
  void didUpdateWidget(covariant SqPopCounter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value) {
      _controller
        ..reset()
        ..forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final body =
        widget.grouped ? formatScore(widget.value) : '${widget.value}';
    return ScaleTransition(
      scale: _scale,
      alignment: Alignment.centerLeft,
      child: Text('${widget.prefix}$body', style: widget.style),
    );
  }
}
