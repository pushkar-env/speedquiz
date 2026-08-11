import 'package:flutter/foundation.dart';

abstract final class AppConfig {
  /// Override for release / device builds:
  /// `flutter run --dart-define=API_BASE_URL=https://api.speedquiz.app`
  /// or `flutter build appbundle --dart-define=API_BASE_URL=...`
  static String get apiBaseUrl {
    const fromEnv = String.fromEnvironment('API_BASE_URL');
    if (fromEnv.isNotEmpty) {
      return fromEnv.endsWith('/') ? fromEnv.substring(0, fromEnv.length - 1) : fromEnv;
    }
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

  /// Shown in Profile. Keep in sync with `pubspec.yaml`, or override per build
  /// with `--dart-define=APP_VERSION=1.2.0`.
  static const appVersion = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: '0.1.0',
  );

  /// Google Cloud **Web** OAuth client ID (serverClientId for ID tokens).
  /// Pass via `--dart-define=GOOGLE_SERVER_CLIENT_ID=....apps.googleusercontent.com`
  static const googleServerClientId = String.fromEnvironment(
    'GOOGLE_SERVER_CLIENT_ID',
  );

  static bool get hasGoogleSignInConfig => googleServerClientId.isNotEmpty;

  /// True when API_BASE_URL was provided at compile time (typical for store builds).
  static bool get hasCompileTimeApiBase {
    const fromEnv = String.fromEnvironment('API_BASE_URL');
    return fromEnv.isNotEmpty;
  }
}
