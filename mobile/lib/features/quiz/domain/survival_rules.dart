/// Client mirror of the server's survival tuning.
///
/// The server (`backend/app/services/survival.py`) is authoritative for every
/// number that decides a score, a life or a clock. These exist so the HUD can
/// explain the run while it is happening: the player needs to know they are on
/// their last life *before* they answer, and how close the next comeback is.
/// If a value here ever drifts from the server, play stays correct — the
/// display reconciles on the next answer.
abstract final class SurvivalRules {
  /// Lives a run opens with, and the ceiling a comeback restores to
  /// (`START_LIVES` / `MAX_LIVES`).
  static const int startLives = 3;
  static const int maxLives = 3;

  /// Streak that earns the first life back (`REGAIN_BASE_STREAK`), and how
  /// much each life already regained adds to the next (`REGAIN_STEP`).
  static const int regainBaseStreak = 7;
  static const int regainStep = 4;

  /// At or below this many lives, every answer pays the last-stand multiplier.
  static const int lastStandLives = 1;

  /// The multiplier itself (`LAST_STAND_MULTIPLIER`), for the HUD callout.
  static const double lastStandMultiplier = 1.5;

  /// Every Nth correct answer pays a checkpoint bonus (`CHECKPOINT_EVERY`).
  static const int checkpointEvery = 10;

  /// Streak needed for the next life, given how many are already regained.
  static int streakForNextLife(int livesRegained) =>
      regainBaseStreak + (livesRegained < 0 ? 0 : livesRegained) * regainStep;

  /// True while the player is one mistake from the end of the run.
  static bool isLastStand(int? lives) =>
      lives != null && lives > 0 && lives <= lastStandLives;

  /// Correct answers still to go before the next checkpoint bonus.
  static int answersToCheckpoint(int correctCount) {
    final into = correctCount % checkpointEvery;
    return into == 0 ? checkpointEvery : checkpointEvery - into;
  }
}
