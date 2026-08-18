import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/feedback/audio_service.dart';
import 'package:speedquiz/core/push/local_notifications.dart';
import 'package:speedquiz/core/push/push_service.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/i18n/language_providers.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/routing/deep_link_listener.dart';
import 'package:speedquiz/features/auth/presentation/auth_controller.dart';
import 'package:speedquiz/features/multiplayer/presentation/inbox_channel.dart';
import 'package:speedquiz/features/multiplayer/presentation/widgets/notification_popup.dart';
import 'package:speedquiz/features/reminders/data/reminder_scheduler.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/core/theme/theme_mode_provider.dart';

/// Every tapped-notification deep link, from both sources, as one stream.
///
/// A push and an on-device reminder both hand back an in-app path and both
/// want the same navigation; the router should not have to care which of the
/// two produced it. Merged here rather than inside either service so neither
/// has to know the other exists.
final notificationLinksProvider = Provider<Stream<String>>((ref) {
  final merged = StreamController<String>.broadcast();
  final subscriptions = <StreamSubscription<String>>[
    ref.watch(pushServiceProvider).deepLinks.listen(merged.add),
    ref.watch(localNotificationServiceProvider).deepLinks.listen(merged.add),
  ];
  ref.onDispose(() {
    for (final subscription in subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(merged.close());
  });
  return merged.stream;
});

class SpeedQuizApp extends ConsumerWidget {
  const SpeedQuizApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    final themeMode = ref.watch(themeModeProvider);
    // Watched, not read: changing the app language rebuilds MaterialApp, which
    // swaps the Localizations scope and re-renders every screen in place. No
    // restart, no route reset, no lost quiz.
    final language = ref.watch(appLanguageProvider);

    // A signed-in account carries its own language preferences. They apply
    // only to a device that has never chosen one of its own — see
    // `AppLanguageNotifier.adoptFromProfile` for why signing in must not
    // override a deliberate local choice.
    ref.listen(currentUserProvider, (previous, next) {
      if (next == null) {
        // Signed out. Release the push token so the next player on this phone
        // does not receive the previous one's challenges, and close the inbox
        // socket — it is authenticated as the account that just left.
        unawaited(ref.read(pushServiceProvider).unregister());
        ref.invalidate(inboxChannelProvider);
        // Same reasoning for anything already on screen or already on the
        // clock: a banner and a "your streak ends tonight" both belong to the
        // account that just left the device.
        NotificationPopup.clear();
        unawaited(ref.read(reminderSchedulerProvider).cancelAll());
        return;
      }
      if (previous?.id == next.id) return;
      // A different account on the same install: the old channel is holding
      // the previous player's stream.
      if (previous != null) ref.invalidate(inboxChannelProvider);
      ref.read(appLanguageProvider.notifier).adoptFromProfile(next.appLanguage);
      ref
          .read(quizLanguageProvider.notifier)
          .adoptFromProfile(next.quizLanguage);
      // Registered per account, not per launch: the token identifies the
      // install and has to be attached to whoever is signed in on it now.
      unawaited(ref.read(pushServiceProvider).registerForCurrentUser());
    });
    // Instantiate for the app's lifetime so the static Sound facade is wired
    // before the first tap and the ambient loop can follow the setting.
    ref.watch(audioServiceProvider);

    return DeepLinkListener(
      router: router,
      pushLinks: ref.watch(notificationLinksProvider),
      child: MaterialApp.router(
        title: 'SpeedQuiz',
        debugShowCheckedModeBanner: false,
        themeMode: themeMode,
        theme: AppTheme.light(script: language.script),
        darkTheme: AppTheme.dark(script: language.script),
        locale: language.locale,
        supportedLocales: AppLanguage.supportedLocales,
        localizationsDelegates: const [
          SqLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        routerConfig: router,
        builder: (context, child) {
          // Keep the system bars in sync with the resolved brightness, and
          // cap text scaling so gameplay HUDs never overflow at 200%.
          final brightness = Theme.of(context).brightness;
          final scale = MediaQuery.textScalerOf(context)
              .clamp(minScaleFactor: 0.85, maxScaleFactor: 1.35);

          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: AppTheme.overlayStyle(brightness),
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: scale),
              child: child ?? const SizedBox.shrink(),
            ),
          );
        },
      ),
    );
  }
}
