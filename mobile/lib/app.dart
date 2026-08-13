import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/feedback/audio_service.dart';
import 'package:speedquiz/core/push/push_service.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/i18n/language_providers.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/routing/deep_link_listener.dart';
import 'package:speedquiz/features/auth/presentation/auth_controller.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/core/theme/theme_mode_provider.dart';

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
        // does not receive the previous one's challenges.
        unawaited(ref.read(pushServiceProvider).unregister());
        return;
      }
      if (previous?.id == next.id) return;
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
      pushLinks: ref.watch(pushServiceProvider).deepLinks,
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
