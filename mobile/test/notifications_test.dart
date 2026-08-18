import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/push/local_notifications.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/settings/app_settings.dart';
import 'package:speedquiz/features/auth/domain/auth_models.dart';
import 'package:speedquiz/features/auth/presentation/auth_controller.dart';
import 'package:speedquiz/features/daily/domain/daily_models.dart';
import 'package:speedquiz/features/multiplayer/domain/multiplayer_models.dart';
import 'package:speedquiz/features/multiplayer/presentation/inbox_channel.dart';
import 'package:speedquiz/features/multiplayer/presentation/widgets/notification_popup.dart';
import 'package:speedquiz/features/reminders/data/reminder_scheduler.dart';
import 'package:speedquiz/features/topics/data/topics_repository.dart';

/// Cover for the two halves of the notification work that have no UI in them:
/// what a live inbox event turns into on its way to the banner, and what the
/// app decides to remind a player about.

final _en = stringsFor(AppLanguage.english);
final _hi = stringsFor(AppLanguage.hindi);

InboxEvent _event(
  AppNotificationType type, {
  Map<String, dynamic> payload = const {},
  String? matchId,
  String? deepLink,
}) {
  return InboxEvent(
    type: type,
    notificationId: 'n1',
    actorUserId: 'u2',
    matchId: matchId,
    deepLink: deepLink,
    payload: payload,
  );
}

void main() {
  group('NotificationBrief', () {
    test('names the sender the server put on the event', () {
      final brief = NotificationBrief.fromEvent(
        _event(
          AppNotificationType.friendRequest,
          payload: {'actor': 'Asha', 'request_id': 'r7'},
        ),
        fallbackActor: 'A player',
      );

      expect(brief.actorName, 'Asha');
      expect(brief.requestId, 'r7');
      expect(brief.body(_en), contains('Asha'));
    });

    test('falls back when the server sent no name', () {
      final brief = NotificationBrief.fromEvent(
        _event(AppNotificationType.friendAccepted),
        fallbackActor: 'A player',
      );

      expect(brief.actorName, 'A player');
      expect(brief.requestId, isNull);
    });

    test('reads in the language the app is set to, not the one it was sent in',
        () {
      final brief = NotificationBrief.fromEvent(
        _event(
          AppNotificationType.matchInvite,
          payload: {'actor': 'Ravi', 'topic_name': 'Cricket'},
          matchId: 'm9',
        ),
        fallbackActor: 'A player',
      );

      expect(brief.body(_en), 'Ravi challenged you to Cricket');
      expect(brief.body(_hi), isNot(brief.body(_en)));
      expect(brief.body(_hi), contains('Ravi'));
    });

    test('gives a challenge longer on screen than anything else', () {
      final invite = NotificationBrief.fromEvent(
        _event(AppNotificationType.matchInvite, matchId: 'm9'),
        fallbackActor: 'A player',
      );
      final result = NotificationBrief.fromEvent(
        _event(AppNotificationType.matchResult, matchId: 'm9'),
        fallbackActor: 'A player',
      );

      expect(invite.dwell, greaterThan(result.dwell));
    });

    test('prefers the deep link, and falls back to the match', () {
      final linked = NotificationBrief.fromEvent(
        _event(
          AppNotificationType.friendRequest,
          deepLink: Routes.friends,
        ),
        fallbackActor: 'A player',
      );
      final bare = NotificationBrief.fromEvent(
        _event(AppNotificationType.matchYourTurn, matchId: 'm9'),
        fallbackActor: 'A player',
      );
      final nowhere = NotificationBrief.fromEvent(
        _event(AppNotificationType.matchResult),
        fallbackActor: 'A player',
      );

      expect(linked.target, Routes.friends);
      expect(bare.target, Routes.matchPath('m9'));
      expect(nowhere.target, isNull);
    });

    test('every type draws a title, a body and a glyph', () {
      for (final type in AppNotificationType.values) {
        final brief = NotificationBrief.fromEvent(
          _event(type),
          fallbackActor: 'A player',
        );
        expect(brief.title(_en), isNotEmpty, reason: '$type title');
        expect(brief.body(_en), isNotEmpty, reason: '$type body');
        expect(brief.title(_hi), isNotEmpty, reason: '$type title (hi)');
        expect(brief.body(_hi), isNotEmpty, reason: '$type body (hi)');
        expect(brief.glyph, isNotEmpty, reason: '$type glyph');
      }
    });

    group('from a push', () {
      test('uses the copy the server already rendered', () {
        final brief = NotificationBrief.fromPush(
          type: 'match_invite',
          title: 'You have been challenged',
          body: 'Ravi challenged you to Cricket',
          deepLink: '/battle/match/m9',
          fallbackActor: 'A player',
        );

        expect(brief, isNotNull);
        expect(brief!.type, AppNotificationType.matchInvite);
        // Server prose wins over the locally rebuilt line — the push was
        // rendered in the language this device registered.
        expect(brief.body(_hi), 'Ravi challenged you to Cricket');
        expect(brief.title(_hi), 'You have been challenged');
        expect(brief.target, '/battle/match/m9');
      });

      test('has nothing to say about a data-only message', () {
        expect(
          NotificationBrief.fromPush(
            type: 'match_result',
            title: null,
            body: null,
            deepLink: null,
            fallbackActor: 'A player',
          ),
          isNull,
        );
      });
    });
  });

  group('ReminderScheduler', () {
    late _RecordingNotifications service;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      service = _RecordingNotifications();
    });

    ProviderContainer containerFor({int streak = 0, TopicItem? topic}) {
      return ProviderContainer(
        overrides: [
          localNotificationServiceProvider.overrideWithValue(service),
          currentUserProvider.overrideWithValue(_user(streak: streak)),
          randomTopicProvider.overrideWithValue(topic),
        ],
      );
    }

    test('arms the daily reminder for the evening', () async {
      final container = containerFor();
      addTearDown(container.dispose);

      await container.read(reminderSchedulerProvider).refresh(
            daily: _daily(completed: false),
          );

      final daily = service.scheduled[ReminderScheduler.dailyId];
      expect(daily, isNotNull);
      expect(daily!.when.hour, ReminderScheduler.dailyHour);
      expect(daily.when.isAfter(DateTime.now()), isTrue);
      expect(daily.deepLink, Routes.home);
    });

    test('skips today once today has been played', () async {
      final container = containerFor();
      addTearDown(container.dispose);

      await container.read(reminderSchedulerProvider).refresh(
            daily: _daily(completed: true),
          );

      final daily = service.scheduled[ReminderScheduler.dailyId]!;
      final tomorrow = DateTime.now().add(const Duration(days: 1));
      expect(
        DateTime(daily.when.year, daily.when.month, daily.when.day),
        DateTime(tomorrow.year, tomorrow.month, tomorrow.day),
      );
    });

    test('says nothing about a streak there is none of', () async {
      final container = containerFor();
      addTearDown(container.dispose);

      await container
          .read(reminderSchedulerProvider)
          .refresh(daily: _daily(completed: false));

      expect(service.scheduled, isNot(contains(ReminderScheduler.streakId)));
      expect(service.cancelled, contains(ReminderScheduler.streakId));
    });

    test('says nothing about a streak that is already safe', () async {
      final container = containerFor(streak: 12);
      addTearDown(container.dispose);

      await container
          .read(reminderSchedulerProvider)
          .refresh(daily: _daily(completed: true));

      expect(service.scheduled, isNot(contains(ReminderScheduler.streakId)));
      expect(service.cancelled, contains(ReminderScheduler.streakId));
    });

    test('names a topic in the comeback nudge when it has one', () async {
      final container = containerFor(topic: _topic('Cricket'));
      addTearDown(container.dispose);

      await container.read(reminderSchedulerProvider).refresh();

      final comeback = service.scheduled[ReminderScheduler.comebackId]!;
      final due = DateTime.now()
          .add(const Duration(days: ReminderScheduler.comebackAfterDays));
      expect(
        DateTime(comeback.when.year, comeback.when.month, comeback.when.day),
        DateTime(due.year, due.month, due.day),
      );
      expect(comeback.when.hour, ReminderScheduler.comebackHour);
      expect(comeback.body, contains('Cricket'));
      expect(comeback.deepLink, Routes.quizSetup);
    });

    test('falls back to generic copy with no topic banked', () async {
      final container = containerFor();
      addTearDown(container.dispose);

      await container.read(reminderSchedulerProvider).refresh();

      final comeback = service.scheduled[ReminderScheduler.comebackId]!;
      expect(comeback.body, _en.reminderComebackBody);
    });

    test('switching reminders off takes the armed ones down with it',
        () async {
      final container = containerFor(streak: 4);
      addTearDown(container.dispose);
      await container.read(settingsProvider.notifier).setReminders(false);

      await container
          .read(reminderSchedulerProvider)
          .refresh(daily: _daily(completed: false));

      expect(service.cancelledAll, isTrue);
      expect(service.scheduled, isEmpty);
    });

    test('does nothing at all when the plugin never came up', () async {
      service.ready = false;
      final container = containerFor(streak: 4);
      addTearDown(container.dispose);

      await container
          .read(reminderSchedulerProvider)
          .refresh(daily: _daily(completed: false));

      expect(service.scheduled, isEmpty);
      expect(service.cancelledAll, isFalse);
    });
  });
}

/// A [LocalNotificationService] that records instead of touching the platform.
class _RecordingNotifications extends LocalNotificationService {
  final Map<int, ({DateTime when, String title, String body, String? deepLink})>
      scheduled = {};
  final Set<int> cancelled = {};
  bool cancelledAll = false;
  bool ready = true;

  @override
  bool get isReady => ready;

  @override
  Future<bool> ensurePermission() async => true;

  @override
  Future<void> schedule({
    required int id,
    required DateTime when,
    required String title,
    required String body,
    String? deepLink,
  }) async {
    scheduled[id] = (when: when, title: title, body: body, deepLink: deepLink);
  }

  @override
  Future<void> cancel(int id) async => cancelled.add(id);

  @override
  Future<void> cancelAll() async => cancelledAll = true;
}

AuthUser _user({required int streak}) => AuthUser(
      id: 'u1',
      username: 'player',
      isGuest: false,
      isPremium: false,
      level: 3,
      xp: 400,
      coins: 0,
      currentStreak: streak,
      dailyStreak: streak,
      onboardingCompleted: true,
      themePreference: 'dark',
      avatarId: 'a1',
    );

DailyChallengeInfo _daily({required bool completed}) =>
    DailyChallengeInfo.fromJson({
      'id': 'd1',
      'challenge_date': '2026-08-18',
      'title': 'Daily',
      'topic_id': 't1',
      'topic_name': 'General',
      'difficulty': 'medium',
      'question_count': 10,
      'status': completed ? 'completed' : 'available',
    });

TopicItem _topic(String name) => TopicItem(
      id: 't1',
      name: name,
      icon: '🏏',
      questionCount: 120,
    );
