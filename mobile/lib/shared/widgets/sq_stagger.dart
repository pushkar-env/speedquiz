import 'dart:async';

import 'package:flutter/material.dart';
import 'package:speedquiz/core/theme/app_motion.dart';

/// Fade + rise entrance for a single item, delayed by its [index] so a list
/// or grid cascades in instead of appearing all at once.
///
/// Safe on long lists: the delay saturates at [AppMotion.maxStaggerIndex].
class SqStagger extends StatefulWidget {
  const SqStagger({
    super.key,
    required this.child,
    this.index = 0,
    this.offset = 18,
    this.duration = AppMotion.normal,
    this.delay = Duration.zero,
  });

  final Widget child;
  final int index;

  /// Vertical travel in logical pixels.
  final double offset;
  final Duration duration;

  /// Extra delay on top of the per-index stagger.
  final Duration delay;

  @override
  State<SqStagger> createState() => _SqStaggerState();
}

class _SqStaggerState extends State<SqStagger>
    with SingleTickerProviderStateMixin {
  // Eager, never `late`-lazy: with reduce-motion on, build returns the child
  // without touching the controller, so a lazy initialiser would run for the
  // first time inside dispose() and create a Ticker on a dead element.
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  Timer? _entrance;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: Offset(0, widget.offset / 100),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: AppMotion.enter));

    final steps = widget.index.clamp(0, AppMotion.maxStaggerIndex);
    final wait = widget.delay + AppMotion.stagger * steps;
    if (wait <= Duration.zero) {
      _controller.forward();
      return;
    }
    // A real Timer (not Future.delayed) so it can be cancelled on dispose —
    // otherwise a fast-scrolling list leaves callbacks pending after unmount.
    _entrance = Timer(wait, () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _entrance?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Honour the platform reduce-motion setting.
    if (MediaQuery.disableAnimationsOf(context)) return widget.child;

    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}

/// Applies [SqStagger] to each child of a column-style list.
List<Widget> staggered(
  List<Widget> children, {
  int startIndex = 0,
  Duration delay = Duration.zero,
}) {
  return [
    for (var i = 0; i < children.length; i++)
      SqStagger(
        index: startIndex + i,
        delay: delay,
        child: children[i],
      ),
  ];
}
