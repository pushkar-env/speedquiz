import 'package:flutter/widgets.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:speedquiz/core/i18n/app_language.dart';
import 'package:speedquiz/core/i18n/sq_strings.dart';
import 'package:speedquiz/core/i18n/sq_strings_en.dart';
import 'package:speedquiz/core/i18n/sq_strings_hi.dart';

export 'package:speedquiz/core/i18n/app_language.dart';
export 'package:speedquiz/core/i18n/sq_strings.dart';

/// Resolves an [AppLanguage] to its string table.
///
/// Const instances, so switching language allocates nothing and the whole cost
/// of a change is the rebuild itself.
SqStrings stringsFor(AppLanguage language) => switch (language) {
      AppLanguage.english => const SqStringsEn(),
      AppLanguage.hindi => const SqStringsHi(),
    };

/// Publishes [SqStrings] into the widget tree via `Localizations`.
///
/// Going through the framework rather than a bare Riverpod read means anything
/// with a `BuildContext` — including code that has no `WidgetRef`, like a
/// `showDialog` builder or a `GoRouter` error page — can reach the strings, and
/// widget tests can pump a locale without standing up a provider container.
class SqLocalizations {
  const SqLocalizations._();

  static const LocalizationsDelegate<SqStrings> delegate =
      _SqLocalizationsDelegate();

  /// The strings for the nearest `Localizations` scope.
  ///
  /// Falls back to English instead of throwing: a missing scope is a wiring
  /// bug, and shipping English chrome beats a red screen in a player's hands.
  static SqStrings of(BuildContext context) =>
      Localizations.of<SqStrings>(context, SqStrings) ?? const SqStringsEn();
}

class _SqLocalizationsDelegate extends LocalizationsDelegate<SqStrings> {
  const _SqLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) =>
      AppLanguage.values.any((l) => l.code == locale.languageCode);

  @override
  Future<SqStrings> load(Locale locale) async {
    final language = AppLanguage.fromCode(locale.languageCode);
    // The framework awaits this on every locale change, which makes it the
    // right place to prepare `intl`: month names and number grouping come from
    // locale data that must be loaded before the first `DateFormat`, and a
    // widget that formats a date has no async point of its own to do it in.
    await initializeDateFormatting(language.code);
    Intl.defaultLocale = language.code;
    return stringsFor(language);
  }

  @override
  bool shouldReload(_SqLocalizationsDelegate old) => false;
}

extension SqLocalizationsX on BuildContext {
  /// The active string table. `context.l10n.settingsTitle`.
  SqStrings get l10n => SqLocalizations.of(this);

  /// The active app language, for the rare widget that needs the language
  /// itself (a picker's checkmark, a locale-aware formatter).
  AppLanguage get appLanguage => l10n.language;

  /// Extra vertical room a **fixed-height** row needs in the active script.
  ///
  /// Devanagari sets on a taller line box than Latin (see `AppTheme`), so a
  /// carousel or chip rail pinned to a pixel height that fits English will
  /// overflow by a few pixels in Hindi. Anything that hard-codes a height and
  /// contains text should add this.
  ///
  /// Text that can simply grow does not need it — this is only for the places
  /// where a `SizedBox` or `AnimatedContainer` fixes the height on purpose.
  double get scriptExtraHeight =>
      appLanguage.script == SqScript.devanagari ? 12 : 0;
}
