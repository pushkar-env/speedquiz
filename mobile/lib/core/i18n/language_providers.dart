import 'dart:async';
import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speedquiz/core/i18n/app_language.dart';
import 'package:speedquiz/features/profile/data/profile_repository.dart';

/// Preference keys. Both live on the device, not only on the account: the app
/// has to open in the right language before it knows who is signed in.
const _appLanguageKey = 'settings_app_language';
const _quizLanguageKey = 'settings_quiz_language';

/// Language of the app chrome. Changed in Profile → Settings.
class AppLanguageNotifier extends StateNotifier<AppLanguage> {
  AppLanguageNotifier(this._ref) : super(AppLanguage.fallback);

  final Ref _ref;

  /// False until the player has chosen a language *or* we have read one back
  /// from storage. While false, a signed-in account's stored preference is
  /// allowed to win; after that, the device's explicit choice always does.
  bool _chosen = false;

  bool get hasExplicitChoice => _chosen;

  /// Reads the stored language, or infers one from the device.
  ///
  /// Called before `runApp` so the first frame is already correct — hydrating
  /// later would flash English chrome at a Hindi player on every cold start.
  Future<void> hydrate({List<Locale>? systemLocales}) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_appLanguageKey);
    if (stored != null) {
      state = AppLanguage.fromCode(stored);
      _chosen = true;
      return;
    }
    // No stored choice: follow the device. Someone whose phone is in Hindi
    // should not have to find a setting to read the app in Hindi.
    state = AppLanguage.fromSystem(
      systemLocales ?? PlatformDispatcher.instance.locales,
    );
  }

  Future<void> setLanguage(AppLanguage language) async {
    if (state == language && _chosen) return;
    state = language;
    _chosen = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_appLanguageKey, language.code);
    unawaited(_syncToProfile(language));
  }

  /// Adopts the language stored on the signed-in account.
  ///
  /// Only when this device has no explicit choice of its own — otherwise
  /// signing in on a phone deliberately set to Hindi would silently flip it
  /// back to whatever language was used on some other device.
  Future<void> adoptFromProfile(String? code) async {
    if (_chosen || code == null) return;
    final language = AppLanguage.fromCode(code);
    if (language == state) return;
    state = language;
  }

  /// Best-effort mirror to the account so a reinstall lands in the same
  /// language. Never blocks or surfaces a failure: this is a convenience, and
  /// the device preference is already saved.
  Future<void> _syncToProfile(AppLanguage language) async {
    try {
      await _ref
          .read(profileRepositoryProvider)
          .update(appLanguage: language.code);
    } catch (_) {
      // Offline, signed out, or a server that predates the field.
    }
  }
}

final appLanguageProvider =
    StateNotifierProvider<AppLanguageNotifier, AppLanguage>((ref) {
  return AppLanguageNotifier(ref);
});

/// Language questions are written in.
///
/// Independent of the app language on purpose: reading the UI in Hindi while
/// practising English questions (or the reverse) is a real, common combination.
/// This holds the *default* the setup screen preselects — the authoritative
/// value for a run is the one the session was created with, which the server
/// stores on the session.
class QuizLanguageNotifier extends StateNotifier<AppLanguage> {
  QuizLanguageNotifier(this._ref) : super(AppLanguage.fallback);

  final Ref _ref;

  bool _chosen = false;

  bool get hasExplicitChoice => _chosen;

  /// [fallback] is the resolved app language: on a fresh install, quizzing in
  /// the language you read the app in is the better guess than defaulting
  /// everyone to English.
  Future<void> hydrate({AppLanguage? fallback}) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_quizLanguageKey);
    if (stored != null) {
      state = AppLanguage.fromCode(stored);
      _chosen = true;
      return;
    }
    state = fallback ?? AppLanguage.fallback;
  }

  Future<void> setLanguage(AppLanguage language) async {
    if (state == language && _chosen) return;
    state = language;
    _chosen = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_quizLanguageKey, language.code);
    unawaited(_syncToProfile(language));
  }

  Future<void> adoptFromProfile(String? code) async {
    if (_chosen || code == null) return;
    state = AppLanguage.fromCode(code);
  }

  Future<void> _syncToProfile(AppLanguage language) async {
    try {
      await _ref
          .read(profileRepositoryProvider)
          .update(quizLanguage: language.code);
    } catch (_) {
      // Same as above — the run itself carries the language regardless.
    }
  }
}

final quizLanguageProvider =
    StateNotifierProvider<QuizLanguageNotifier, AppLanguage>((ref) {
  return QuizLanguageNotifier(ref);
});
