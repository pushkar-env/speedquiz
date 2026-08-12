/// Client mirror of the server's speedrun tuning.
///
/// The server (`backend/app/services/speedrun.py`) is authoritative for every
/// number that decides a score or a clock. These exist so the HUD can draw the
/// run *between* round trips: the clock has to keep draining while the player
/// reads, and the verdict flash has to last exactly as long as the time the
/// server charges for it. If a value here ever drifts from the server, play
/// stays correct — the display just reconciles on the next answer.
abstract final class SpeedrunRules {
  /// How long a verdict stays on screen. Mirrors `FEEDBACK_BURN_MS`, which is
  /// what the server takes off the clock for it.
  static const int flashMs = 800;

  /// Ceiling on banked time (`CLOCK_CAP_MS`). Denominator for the drain bar.
  static const int clockCapMs = 60000;

  /// Below this the run is in trouble: the HUD goes red and starts ticking.
  static const int dangerMs = 10000;

  /// Pre-run "3 · 2 · 1 · GO" beats. Long enough to land, short enough that
  /// nobody taps through it.
  static const int countdownBeatMs = 500;
  static const int goBeatMs = 400;

  /// Streak that lights up overdrive (`OVERDRIVE_STREAK`).
  static const int overdriveStreak = 5;

  /// The `speed_tier` values the server reports on a correct answer.
  ///
  /// The words a player sees live in `core/i18n/game_labels.dart` — these are
  /// the wire identifiers, which never change with language.
  static const Set<String> speedTiers = {'blitz', 'fast', 'clean', 'clutch'};
}
