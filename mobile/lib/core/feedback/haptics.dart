import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Centralised haptics with a global kill switch.
///
/// Every call is fire-and-forget and swallows platform errors — desktop and
/// web have no vibrator, and a missing haptic must never break a tap handler.
abstract final class Haptics {
  /// Global kill switch — flip to false to silence every haptic in the app.
  static bool enabled = true;

  static bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  static void _run(Future<void> Function() action) {
    if (!enabled || !_supported) return;
    action().catchError((_) {});
  }

  /// Standard tap on any interactive surface.
  static void tap() => _run(HapticFeedback.selectionClick);

  /// Committing an action — primary buttons, confirming a dialog.
  static void press() => _run(HapticFeedback.lightImpact);

  /// A correct answer, an unlock, a personal best.
  static void success() => _run(HapticFeedback.mediumImpact);

  /// A wrong answer or a rejected action, paired with a shake.
  static void error() => _run(HapticFeedback.heavyImpact);

  /// Something crossed a threshold (streak milestone, level up).
  static void milestone() => _run(HapticFeedback.vibrate);
}
