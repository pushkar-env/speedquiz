import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// On-device notifications: the reminders the app schedules for itself.
///
/// How this differs from [PushService]
/// -----------------------------------
/// Push carries things *other players* did — a challenge, a friend request —
/// and needs a Firebase project and a server to send it. This carries things
/// the *app* wants to say to the player who installed it: today's challenge is
/// still unplayed, a streak is about to lapse, it has been a few days. Nothing
/// leaves the device and nothing has to be configured, so these work on every
/// build including one with no `FIREBASE_*` defines at all.
///
/// Everything here fails soft. A phone that denies the permission, an OEM that
/// throttles alarms, a locale whose timezone name the tz database does not
/// recognise: each of those costs a reminder, and none of them may cost a
/// launch.
class LocalNotificationService {
  LocalNotificationService();

  /// Reminders share one channel so a player who finds them annoying can
  /// silence the lot from system settings without also losing challenges.
  static const channelId = 'speedquiz_reminders';

  /// Challenges, friend requests, results — the channel `MainActivity` creates
  /// and the FCM sender targets.
  ///
  /// Deliberately the *same* id rather than a second one of our own: a message
  /// that arrives over the socket and the identical message arriving as a push
  /// should land in one place in system settings, so silencing it means
  /// silencing it. Changing this string means changing it in three places —
  /// here, `MainActivity.kt`, and `backend/app/push/fcm.py`.
  static const socialChannelId = 'speedquiz_multiplayer';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  final StreamController<String> _deepLinks =
      StreamController<String>.broadcast();

  /// Deep links from a tapped reminder, for the router to consume — the same
  /// contract as `PushService.deepLinks`.
  Stream<String> get deepLinks => _deepLinks.stream;

  bool _ready = false;
  bool get isReady => _ready;

  bool _permissionAsked = false;

  /// Only Android and iOS ship reminders. The plugin supports more, but the
  /// app does not, and pretending otherwise means untestable branches.
  bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Future<void> initialize() async {
    if (_ready || !_supported) return;

    try {
      await _initializeTimeZone();

      await _plugin.initialize(
        settings: const InitializationSettings(
          // The launcher icon rather than a dedicated monochrome asset: a
          // missing drawable is a crash at notify time on Android, and that
          // would be a crash nobody sees until a reminder actually fires.
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(
            // Asked for in context by [ensurePermission], not on first launch.
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
        onDidReceiveNotificationResponse: _onTap,
      );

      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(
            const AndroidNotificationChannel(
              channelId,
              'Reminders',
              description: 'Daily challenge, streaks, and nudges to play.',
              importance: Importance.defaultImportance,
            ),
          );

      // A reminder tapped while the app was dead is delivered here, once.
      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp ?? false) {
        _emit(launch?.notificationResponse?.payload);
      }

      _ready = true;
    } catch (error) {
      debugPrint('Local notifications unavailable: $error');
    }
  }

  /// Point the tz database at the phone's actual zone.
  ///
  /// `zonedSchedule` needs a real location, not a fixed offset: "19:00" has to
  /// still be 19:00 after a DST boundary, and half the world's offsets are not
  /// whole hours. UTC is the fallback — reminders at the wrong hour are worse
  /// than none, so a zone we cannot resolve disables scheduling below rather
  /// than guessing.
  Future<void> _initializeTimeZone() async {
    tz_data.initializeTimeZones();
    final info = await FlutterTimezone.getLocalTimezone();
    tz.setLocalLocation(tz.getLocation(info.identifier));
  }

  void _onTap(NotificationResponse response) => _emit(response.payload);

  void _emit(String? payload) {
    if (payload == null || payload.isEmpty || _deepLinks.isClosed) return;
    _deepLinks.add(payload);
  }

  /// Ask for the notification permission, in context.
  ///
  /// Shares a decision with push on both platforms — Android 13+ has one
  /// `POST_NOTIFICATIONS` grant and iOS one authorization — so whichever of
  /// the two asks first is the one the player sees, and the second is a no-op
  /// that reads back the existing answer.
  Future<bool> ensurePermission() async {
    if (!_ready) return false;
    if (_permissionAsked) return true;
    _permissionAsked = true;

    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final granted = await _plugin
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
        return granted ?? false;
      }
      final granted = await _plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
      return granted ?? false;
    } catch (error) {
      debugPrint('Local notification permission request failed: $error');
      return false;
    }
  }

  /// Put one reminder on the clock, replacing any earlier one with the same id.
  ///
  /// Deliberately one-shot. The plugin can repeat a wall-clock time daily, but
  /// a repeat cannot skip a day, so a player who already played today would be
  /// reminded to anyway — and a player who has stopped opening the app would
  /// be pinged at 19:00 forever. `ReminderScheduler` re-arms these on every
  /// app open instead, which is both accurate and self-limiting.
  Future<void> schedule({
    required int id,
    required DateTime when,
    required String title,
    required String body,
    String? deepLink,
  }) async {
    if (!_ready) return;

    final at = tz.TZDateTime.from(when.toUtc(), tz.local);
    // A time already gone would fire immediately, which reads as a bug rather
    // than a reminder. Callers compute forward, but clock skew and a slow
    // start can still land us here.
    if (!at.isAfter(tz.TZDateTime.now(tz.local))) return;

    try {
      await _plugin.zonedSchedule(
        id: id,
        title: title,
        body: body,
        scheduledDate: at,
        payload: deepLink,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            'Reminders',
            channelDescription: 'Daily challenge, streaks, and nudges to play.',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
          ),
          iOS: DarwinNotificationDetails(),
        ),
        // Inexact on purpose. Exact alarms need `SCHEDULE_EXACT_ALARM`, which
        // Play restricts to apps whose core function is alarms and which the
        // user can revoke anyway — and a nudge to play a quiz does not care
        // about a few minutes either way.
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
    } catch (error) {
      debugPrint('Could not schedule reminder $id: $error');
    }
  }

  /// Post a notification right now.
  ///
  /// For something that has already happened and that the player is not
  /// looking at — an inbox event that arrived over the socket while the app
  /// was in the background. See `MainShell._onInboxEvent` for when that is the
  /// right thing to do and when it would double up with push.
  Future<void> showNow({
    required int id,
    required String title,
    required String body,
    String? deepLink,
  }) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        payload: deepLink,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            socialChannelId,
            'Multiplayer',
            channelDescription: 'Challenges, friend requests and results.',
            // Higher than a reminder: a challenge has a lobby waiting on it.
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
      );
    } catch (error) {
      debugPrint('Could not post notification $id: $error');
    }
  }

  Future<void> cancel(int id) async {
    if (!_ready) return;
    try {
      await _plugin.cancel(id: id);
    } catch (error) {
      debugPrint('Could not cancel reminder $id: $error');
    }
  }

  Future<void> cancelAll() async {
    if (!_ready) return;
    try {
      await _plugin.cancelAll();
    } catch (error) {
      debugPrint('Could not cancel reminders: $error');
    }
  }

  Future<void> dispose() async {
    if (!_deepLinks.isClosed) await _deepLinks.close();
  }
}

final localNotificationServiceProvider =
    Provider<LocalNotificationService>((ref) {
  final service = LocalNotificationService();
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});
