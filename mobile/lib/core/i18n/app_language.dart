import 'dart:ui';

/// Writing systems the app renders, insofar as they need different treatment.
enum SqScript {
  latin,

  /// Needs a font fallback, looser leading, and no negative tracking. See
  /// `AppTheme`.
  devanagari,
}

/// A language SpeedQuiz ships in.
///
/// The app has **two** independent language settings and this enum names the
/// values for both:
///
/// * **App language** — the chrome: buttons, headers, toasts. Changed in
///   Profile → Settings, applies instantly across the app.
/// * **Quiz language** — the language questions are *written in*. Chosen per
///   run on the setup screen, because "I read the UI in Hindi" and "quiz me in
///   Hindi" are genuinely different preferences: plenty of players want Hindi
///   chrome over English questions for exam prep, and the reverse is common
///   for someone practising their Hindi reading.
///
/// Adding a language is: a value here, a `SqStrings` implementation, and a
/// server-side entry in `app.core.languages`. Nothing else switches on the
/// language, so nothing else has to change.
enum AppLanguage {
  english(
    code: 'en',
    label: 'English',
    nativeLabel: 'English',
    script: SqScript.latin,
  ),

  /// Devanagari script. See `AppTheme` for the font fallback and the type
  /// metrics it needs — the bundled display faces have no Devanagari glyphs.
  hindi(
    code: 'hi',
    label: 'Hindi',
    nativeLabel: 'हिन्दी',
    script: SqScript.devanagari,
  );

  const AppLanguage({
    required this.code,
    required this.label,
    required this.nativeLabel,
    required this.script,
  });

  /// BCP-47 primary subtag. What goes over the wire and into storage.
  final String code;

  /// English name — used where the current UI language should not change the
  /// label (analytics, debug surfaces).
  final String label;

  /// The endonym. What a picker shows, so a player who cannot read the current
  /// language can still find their own.
  final String nativeLabel;

  /// Writing system. Type metrics are a property of the script, not the
  /// language — a second Devanagari language would need the same treatment.
  final SqScript script;

  Locale get locale => Locale(code);

  static const fallback = AppLanguage.english;

  /// Parses anything: a stored code, a server value, a full locale tag.
  ///
  /// Unknown input resolves to [fallback] rather than throwing. A language the
  /// build no longer ships (or a corrupt preference) must not brick launch.
  static AppLanguage fromCode(String? raw, {AppLanguage? orElse}) {
    final fallbackValue = orElse ?? fallback;
    if (raw == null) return fallbackValue;
    final primary = raw.trim().toLowerCase().replaceAll('_', '-').split('-').first;
    if (primary.isEmpty) return fallbackValue;
    for (final language in AppLanguage.values) {
      if (language.code == primary) return language;
    }
    return fallbackValue;
  }

  /// The best match for the device's preferred locales.
  ///
  /// Walks the list in order — a device set to `[mr, hi, en]` gets Hindi, not
  /// English, because Hindi is the earlier of the two we actually support.
  static AppLanguage fromSystem(List<Locale> preferred) {
    for (final locale in preferred) {
      for (final language in AppLanguage.values) {
        if (language.code == locale.languageCode.toLowerCase()) return language;
      }
    }
    return fallback;
  }

  static List<Locale> get supportedLocales =>
      AppLanguage.values.map((l) => l.locale).toList(growable: false);
}
