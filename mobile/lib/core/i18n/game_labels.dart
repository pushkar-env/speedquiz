import 'package:flutter/widgets.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/utils/formatters.dart';

/// Localized display names for the server's gameplay vocabulary.
///
/// Modes and difficulties travel as stable lowercase identifiers (`speedrun`,
/// `expert`) and must stay that way — they key scoring rules, leaderboards and
/// analytics. These helpers are the single place they become words a player
/// reads, so nothing else has to know that `sudden_death` was ever a thing.
///
/// An identifier with no translation falls back to [humanizeMode], which
/// yields readable Latin text. That matters for retired modes: a run played
/// before `negative` was removed still has to render its own results screen.
String localizedMode(BuildContext context, String mode) {
  final l10n = context.l10n;
  return switch (mode) {
    'casual' => l10n.setupModeCasual,
    'speedrun' => l10n.setupModeSpeedrun,
    'survival' => l10n.setupModeSurvival,
    'daily' => l10n.dailyChallenge,
    _ => humanizeMode(mode),
  };
}

String localizedDifficulty(BuildContext context, String difficulty) {
  final l10n = context.l10n;
  return switch (difficulty) {
    'easy' => l10n.difficultyEasy,
    'medium' => l10n.difficultyMedium,
    'hard' => l10n.difficultyHard,
    'expert' => l10n.difficultyExpert,
    'adaptive' => l10n.difficultyAdaptive,
    _ => humanizeMode(difficulty),
  };
}

/// The endonym for a language code (`hi` → हिन्दी), for messages that name the
/// language a run is in.
String localizedLanguageName(String code) =>
    AppLanguage.fromCode(code).nativeLabel;

/// The word that flashes over a correct speedrun answer.
///
/// Empty for an unknown tier — the HUD renders nothing rather than a
/// placeholder, which is what a slow-but-correct answer already does.
String localizedSpeedTier(BuildContext context, String? tier) {
  final l10n = context.l10n;
  return switch (tier) {
    'blitz' => l10n.speedTierBlitz,
    'fast' => l10n.speedTierFast,
    'clean' => l10n.speedTierClean,
    'clutch' => l10n.speedTierClutch,
    _ => '',
  };
}
