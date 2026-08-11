import 'package:flutter/material.dart';

/// Motion tokens. One vocabulary for every animation in the app so timings
/// feel like a single product rather than a pile of magic numbers.
abstract final class AppMotion {
  /// Micro-feedback: press states, ripples, colour swaps.
  static const Duration instant = Duration(milliseconds: 120);

  /// Default UI transition: chips, cards, inline reveals.
  static const Duration fast = Duration(milliseconds: 200);

  /// Standard: expands, list item entrances, sheet content.
  static const Duration normal = Duration(milliseconds: 320);

  /// Route transitions and larger surface changes.
  static const Duration page = Duration(milliseconds: 380);

  /// Celebratory / hero beats: score reveal, confetti, unlocks.
  static const Duration slow = Duration(milliseconds: 700);

  /// Ambient loops (background aurora, idle pulses).
  static const Duration ambient = Duration(milliseconds: 6000);

  /// Decelerate — the workhorse for anything entering the screen.
  static const Curve enter = Curves.easeOutCubic;

  /// Accelerate — for anything leaving.
  static const Curve exit = Curves.easeInCubic;

  /// Symmetric ease for state changes that stay on screen.
  static const Curve standard = Curves.easeInOutCubic;

  /// Overshoot with a settle — buttons, badges, score pops.
  static const Curve spring = Curves.easeOutBack;

  /// Snappy emphasis for gameplay feedback.
  static const Curve emphasized = Cubic(0.2, 0, 0, 1);

  /// Per-item delay when staggering a list or grid.
  static const Duration stagger = Duration(milliseconds: 55);

  /// Cap on stagger index so long lists never feel slow.
  static const int maxStaggerIndex = 8;
}
