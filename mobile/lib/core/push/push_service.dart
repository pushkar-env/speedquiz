import 'dart:async';
import 'dart:io' show Platform;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/config/app_config.dart';
import 'package:speedquiz/features/social/data/social_repository.dart';

/// Push notifications for challenges — the thing that makes a challenge to an
/// offline friend arrive rather than wait.
///
/// Entirely optional
/// -----------------
/// Without the four `FIREBASE_*` dart-defines, [initialize] returns
/// immediately and the app behaves as it always has. This is not a degraded
/// mode to apologise for: the in-app inbox carries every notification, so a
/// build with no Firebase project is fully functional and merely quieter.
/// Making push mandatory would mean a missing console setup breaks the build.
///
/// Tokens follow the install, not the account
/// ------------------------------------------
/// The token is registered on sign-in and released on sign-out. Skipping the
/// release would leave a shared phone receiving the previous player's
/// challenges — which is a privacy leak, not a stray notification.
@pragma('vm:entry-point')
Future<void> firebaseBackgroundHandler(RemoteMessage message) async {
  // Deliberately empty. Every message we send carries a `notification` block,
  // so the system tray renders it without the app running. This handler exists
  // because firebase_messaging requires one to be registered for background
  // delivery to be wired up at all.
}

class PushService {
  PushService(this._ref);

  final Ref _ref;

  FirebaseMessaging? _messaging;
  StreamSubscription<String>? _tokenRefresh;
  StreamSubscription<RemoteMessage>? _opened;
  String? _registeredToken;

  /// Deep links from a tapped notification, for the router to consume.
  final _deepLinks = StreamController<String>.broadcast();
  Stream<String> get deepLinks => _deepLinks.stream;

  bool get isConfigured => AppConfig.hasPushConfig;

  Future<void> initialize() async {
    if (!isConfigured || kIsWeb) return;
    if (_messaging != null) return;

    try {
      await Firebase.initializeApp(
        options: FirebaseOptions(
          apiKey: AppConfig.firebaseApiKey,
          appId: AppConfig.firebaseAppId,
          projectId: AppConfig.firebaseProjectId,
          messagingSenderId: AppConfig.firebaseSenderId,
        ),
      );

      final messaging = FirebaseMessaging.instance;
      _messaging = messaging;
      FirebaseMessaging.onBackgroundMessage(firebaseBackgroundHandler);

      // Android 13+ and iOS both gate notifications behind a runtime prompt.
      // Asked here rather than at first launch: a permission dialog makes far
      // more sense once the player has a friend who might challenge them.
      await messaging.requestPermission(alert: true, badge: true, sound: true);

      _opened = FirebaseMessaging.onMessageOpenedApp.listen(_onOpened);

      // A notification tapped while the app was dead is delivered here, once.
      final initial = await messaging.getInitialMessage();
      if (initial != null) _onOpened(initial);

      _tokenRefresh = messaging.onTokenRefresh.listen((token) {
        unawaited(_register(token));
      });
    } catch (error) {
      // A misconfigured Firebase project must not stop the app from starting.
      debugPrint('Push initialization skipped: $error');
    }
  }

  void _onOpened(RemoteMessage message) {
    final link = message.data['deep_link'];
    if (link is String && link.isNotEmpty) _deepLinks.add(link);
  }

  /// Register this device against the signed-in account.
  Future<void> registerForCurrentUser() async {
    final messaging = _messaging;
    if (messaging == null) return;
    try {
      final token = await messaging.getToken();
      if (token != null && token != _registeredToken) await _register(token);
    } catch (error) {
      debugPrint('Push token unavailable: $error');
    }
  }

  Future<void> _register(String token) async {
    try {
      await _ref.read(socialRepositoryProvider).registerDevice(
            token: token,
            platform: Platform.isIOS ? 'ios' : 'android',
            language: _languageCode(),
            // Sent from the device because the server has no other way to know
            // that 22:00 local is a different instant in Mumbai and London.
            utcOffsetMinutes: DateTime.now().timeZoneOffset.inMinutes,
            appVersion: AppConfig.appVersion,
          );
      _registeredToken = token;
    } catch (error) {
      debugPrint('Push registration failed: $error');
    }
  }

  String _languageCode() {
    // Read lazily and defensively: this runs during sign-in, and a failure to
    // resolve the language must not cost the registration.
    try {
      final locale = PlatformDispatcher.instance.locale.languageCode;
      return locale == 'hi' ? 'hi' : 'en';
    } catch (_) {
      return 'en';
    }
  }

  /// Release the token so the next player on this phone starts clean.
  Future<void> unregister() async {
    final token = _registeredToken;
    _registeredToken = null;
    if (token == null) return;
    try {
      await _ref.read(socialRepositoryProvider).unregisterDevice(token);
    } catch (_) {
      // The server retires tokens FCM rejects anyway; nothing to recover.
    }
  }

  Future<void> dispose() async {
    await _tokenRefresh?.cancel();
    await _opened?.cancel();
    if (!_deepLinks.isClosed) await _deepLinks.close();
  }
}

final pushServiceProvider = Provider<PushService>((ref) {
  final service = PushService(ref);
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});
