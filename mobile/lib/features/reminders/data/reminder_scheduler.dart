import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/i18n/language_providers.dart';
import 'package:speedquiz/core/push/local_notifications.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/settings/app_settings.dart';
import 'package:speedquiz/features/auth/presentation/auth_controller.dart';
import 'package:speedquiz/features/daily/domain/daily_models.dart';
import 'package:speedquiz/features/topics/data/topics_repository.dart';

/// What the app reminds a player about, and when.
///
/// Three reminders, at most two of which can land on any one day:
///
/// * **Daily challenge**, early evening — the core loop. Skipped entirely once
///   today's is played, which is why this is re-derived rather than left
///   repeating on the system's clock.
/// * **Streak at risk**, later that evening — only when there is a streak to
///   lose and it is still losable. This is the one with real stakes, so it is
///   also the one held back until it is true.
/// * **Come back**, a few days out, naming a topic they can actually play.
///   Pushed further out every time the app opens, so it only ever fires for
///   someone who has genuinely gone quiet.
///
/// Everything is re-armed from scratch on each [refresh]. Rescheduling the
/// same id replaces the pending one, so this is idempotent and can be called
/// as often as the app likes.
class ReminderScheduler {
  ReminderScheduler(this._ref);

  final Ref _ref;

  /// Stable ids. Reusing one replaces its pending reminder rather than
  /// stacking a second copy.
  static const dailyId = 4001;
  static const streakId = 4002;
  static const comebackId = 4003;

  /// Early evening: after work and school, before anyone is asleep.
  static const dailyHour = 19;

  /// Late enough to be a last call, early enough to still act on.
  static const streakHour = 21;

  static const comebackHour = 18;
  static const comebackAfterDays = 3;

  /// Re-arm every reminder.
  ///
  /// [daily] is what today's challenge is actually doing. Pass null when it is
  /// not known — an app resume onto a tab that never fetched it — and the
  /// unplayed case is assumed, which errs toward one extra reminder rather
  /// than a silently dropped streak.
  Future<void> refresh({DailyChallengeInfo? daily}) async {
    final service = _ref.read(localNotificationServiceProvider);
    if (!service.isReady) return;

    if (!_ref.read(settingsProvider).remindersEnabled) {
      await service.cancelAll();
      return;
    }

    // Asked for here rather than at startup, and only once the player has put
    // something on the board. A notification prompt on a cold first launch is
    // the one most likely to be denied — and on Android 13+ a denial is close
    // to final. Push asks the same question when Battle is opened; whichever
    // gets there first is the one the player sees, and the other reads back
    // the answer without showing anything.
    final user = _ref.read(currentUserProvider);
    if ((user?.xp ?? 0) > 0 || (user?.dailyStreak ?? 0) > 0) {
      await service.ensurePermission();
    }

    final l10n = stringsFor(_ref.read(appLanguageProvider));
    final now = DateTime.now();
    final dailyDone = daily?.isCompleted ?? false;

    await Future.wait([
      _scheduleDaily(service, l10n, now: now, done: dailyDone),
      _scheduleStreak(service, l10n, now: now, dailyDone: dailyDone),
      _scheduleComeback(service, l10n, now: now),
    ]);
  }

  /// Stop reminding. For signing out, and for switching the setting off —
  /// the next player on this phone is not the one who set a streak.
  Future<void> cancelAll() =>
      _ref.read(localNotificationServiceProvider).cancelAll();

  Future<void> _scheduleDaily(
    LocalNotificationService service,
    SqStrings l10n, {
    required DateTime now,
    required bool done,
  }) async {
    // Today is spoken for either way: played, or the hour has passed and the
    // player is demonstrably holding the phone right now.
    final today = _at(now, dailyHour);
    final when = (done || !today.isAfter(now))
        ? _at(now.add(const Duration(days: 1)), dailyHour)
        : today;

    await service.schedule(
      id: dailyId,
      when: when,
      title: l10n.reminderDailyTitle,
      body: l10n.reminderDailyBody,
      deepLink: Routes.home,
    );
  }

  Future<void> _scheduleStreak(
    LocalNotificationService service,
    SqStrings l10n, {
    required DateTime now,
    required bool dailyDone,
  }) async {
    final streak = _ref.read(currentUserProvider)?.dailyStreak ?? 0;
    final when = _at(now, streakHour);

    // Nothing at stake, already safe, or too late to act on it: a "your streak
    // is ending" that arrives after it already ended is the worst version of
    // this notification.
    if (streak < 1 || dailyDone || !when.isAfter(now)) {
      await service.cancel(streakId);
      return;
    }

    await service.schedule(
      id: streakId,
      when: when,
      title: l10n.reminderStreakTitle,
      body: l10n.reminderStreakBody(streak),
      deepLink: Routes.home,
    );
  }

  Future<void> _scheduleComeback(
    LocalNotificationService service,
    SqStrings l10n, {
    required DateTime now,
  }) async {
    final topic = _ref.read(randomTopicProvider);

    await service.schedule(
      id: comebackId,
      when: _at(
        now.add(const Duration(days: comebackAfterDays)),
        comebackHour,
      ),
      title: l10n.reminderComebackTitle,
      body: topic == null
          ? l10n.reminderComebackBody
          : l10n.reminderComebackBodyTopic(topic.name),
      // Setup rather than Home: this one already names a quiz, so the tap
      // should land on the screen that starts one.
      deepLink: Routes.quizSetup,
    );
  }

  /// [hour] o'clock on [day], in local time.
  static DateTime _at(DateTime day, int hour) =>
      DateTime(day.year, day.month, day.day, hour);
}

final reminderSchedulerProvider = Provider<ReminderScheduler>((ref) {
  return ReminderScheduler(ref);
});
