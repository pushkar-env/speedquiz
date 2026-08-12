import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Router-aware back navigation.
///
/// A screen can be reached two ways: pushed on top of something
/// (`context.push`), or entered as the *only* page in the stack — `context.go`
/// replaces the whole match list, and so do deep links and cold starts.
/// `Navigator.maybePop()` only handles the first case; in the second it
/// silently does nothing, which is what left the close buttons dead and let
/// the Android back button fall through to the launcher.
extension SqNavigation on BuildContext {
  /// Pop when there is something to pop, otherwise land on [fallback].
  ///
  /// Uses [GoRouter] rather than [Navigator] so the router's match list stays
  /// in step with the navigator stack.
  void popOrGo(String fallback) {
    final router = GoRouter.of(this);
    if (router.canPop()) {
      router.pop();
    } else {
      router.go(fallback);
    }
  }
}

/// Makes the Android system back button behave on a screen that might be the
/// only page in the stack.
///
/// Wrap any destination reachable by `context.go` (results, setup, share
/// cards). Back then walks to [fallback] instead of closing the app.
class SqBackGuard extends StatelessWidget {
  const SqBackGuard({
    super.key,
    required this.fallback,
    required this.child,
    this.onBack,
  });

  /// Where back lands when this screen is the bottom of the stack.
  final String fallback;

  /// Overrides the whole behaviour — for screens that need to confirm first.
  final VoidCallback? onBack;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Always intercept: only the callback knows whether a pop is possible,
      // and routing the fallback ourselves keeps both paths identical.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (onBack != null) {
          onBack!();
          return;
        }
        context.popOrGo(fallback);
      },
      child: child,
    );
  }
}
