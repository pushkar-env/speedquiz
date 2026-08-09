import 'package:flutter/foundation.dart';

abstract final class AppConfig {
  /// Override for release / device builds:
  /// `flutter run --dart-define=API_BASE_URL=https://api.quizverse.app`
  /// or `flutter build appbundle --dart-define=API_BASE_URL=...`
  static String get apiBaseUrl {
    const fromEnv = String.fromEnvironment('API_BASE_URL');
    if (fromEnv.isNotEmpty) return fromEnv;
    // Android emulator reaches host machine via 10.0.2.2.
    if (kIsWeb) return 'http://localhost:8000';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'http://10.0.2.2:8000';
      default:
        return 'http://localhost:8000';
    }
  }

  static const apiPrefix = '/api/v1';

  /// True when API_BASE_URL was provided at compile time (typical for store builds).
  static bool get hasCompileTimeApiBase {
    const fromEnv = String.fromEnvironment('API_BASE_URL');
    return fromEnv.isNotEmpty;
  }
}
