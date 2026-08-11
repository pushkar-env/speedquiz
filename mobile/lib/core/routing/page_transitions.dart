import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:speedquiz/core/theme/app_motion.dart';

/// Shared-axis style transition: the incoming page rises and fades in while
/// the outgoing page sinks slightly and fades out. Used for pushes off the
/// shell (quiz setup, play, results).
CustomTransitionPage<T> sqSharedAxisPage<T>({
  required Widget child,
  required GoRouterState state,
  Duration duration = AppMotion.page,
}) {
  return CustomTransitionPage<T>(
    key: state.pageKey,
    child: child,
    transitionDuration: duration,
    reverseTransitionDuration: AppMotion.normal,
    transitionsBuilder: (context, animation, secondary, child) {
      if (MediaQuery.disableAnimationsOf(context)) return child;

      final enter = CurvedAnimation(
        parent: animation,
        curve: AppMotion.emphasized,
        reverseCurve: AppMotion.exit,
      );
      final leave = CurvedAnimation(
        parent: secondary,
        curve: AppMotion.emphasized,
        reverseCurve: AppMotion.exit,
      );

      return FadeTransition(
        opacity: enter,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.045),
            end: Offset.zero,
          ).animate(enter),
          child: SlideTransition(
            position: Tween<Offset>(
              begin: Offset.zero,
              end: const Offset(0, -0.025),
            ).animate(leave),
            child: FadeTransition(
              opacity: Tween<double>(begin: 1, end: 0.4).animate(leave),
              child: child,
            ),
          ),
        ),
      );
    },
  );
}

/// Fade-through: no directional motion, for peer destinations and for
/// screens the user "arrives at" rather than navigates into (splash, landing).
CustomTransitionPage<T> sqFadeThroughPage<T>({
  required Widget child,
  required GoRouterState state,
  Duration duration = AppMotion.page,
}) {
  return CustomTransitionPage<T>(
    key: state.pageKey,
    child: child,
    transitionDuration: duration,
    reverseTransitionDuration: AppMotion.normal,
    transitionsBuilder: (context, animation, secondary, child) {
      if (MediaQuery.disableAnimationsOf(context)) return child;

      final enter = CurvedAnimation(
        parent: animation,
        curve: const Interval(0.3, 1, curve: AppMotion.enter),
      );
      return FadeTransition(
        opacity: enter,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.985, end: 1).animate(enter),
          child: child,
        ),
      );
    },
  );
}

/// Modal-style transition for full-screen sheets pushed from the bottom.
CustomTransitionPage<T> sqModalPage<T>({
  required Widget child,
  required GoRouterState state,
}) {
  return CustomTransitionPage<T>(
    key: state.pageKey,
    child: child,
    transitionDuration: AppMotion.page,
    reverseTransitionDuration: AppMotion.normal,
    transitionsBuilder: (context, animation, secondary, child) {
      if (MediaQuery.disableAnimationsOf(context)) return child;

      final curved = CurvedAnimation(
        parent: animation,
        curve: AppMotion.emphasized,
        reverseCurve: AppMotion.exit,
      );
      return SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.16),
          end: Offset.zero,
        ).animate(curved),
        child: FadeTransition(opacity: curved, child: child),
      );
    },
  );
}
