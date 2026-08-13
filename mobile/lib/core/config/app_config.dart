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

  /// Firebase, for push notifications about challenges.
  ///
  /// Supplied as `--dart-define`s rather than a bundled `google-services.json`
  /// so the project builds and runs without a Firebase project at all — push
  /// is simply off, and the in-app inbox carries everything. Wiring the
  /// google-services Gradle plugin instead would make a missing JSON a build
  /// failure, which is a poor trade for an optional channel.
  ///
  /// Values come from the Firebase console (Project settings → Your apps):
  ///   --dart-define=FIREBASE_API_KEY=...
  ///   --dart-define=FIREBASE_APP_ID=1:123:android:abc
  ///   --dart-define=FIREBASE_PROJECT_ID=speedquiz-prod
  ///   --dart-define=FIREBASE_SENDER_ID=123456789
  static const firebaseApiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const firebaseAppId = String.fromEnvironment('FIREBASE_APP_ID');
  static const firebaseProjectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const firebaseSenderId = String.fromEnvironment('FIREBASE_SENDER_ID');

  static bool get hasPushConfig =>
      firebaseApiKey.isNotEmpty &&
      firebaseAppId.isNotEmpty &&
      firebaseProjectId.isNotEmpty &&
      firebaseSenderId.isNotEmpty;

  /// True when API_BASE_URL was provided at compile time (typical for store builds).
  static bool get hasCompileTimeApiBase {
    const fromEnv = String.fromEnvironment('API_BASE_URL');
    return fromEnv.isNotEmpty;
  }
}
