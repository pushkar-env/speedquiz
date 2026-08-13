import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:speedquiz/app.dart';
import 'package:speedquiz/core/i18n/language_providers.dart';
import 'package:speedquiz/core/push/push_service.dart';
import 'package:speedquiz/core/settings/app_settings.dart';
import 'package:speedquiz/features/onboarding/presentation/onboarding_controller.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/core/theme/theme_mode_provider.dart';

Future<void> main() async {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // Replace the red error screen with something a player can act on.
      ErrorWidget.builder = (details) => _FatalErrorView(details: details);
      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        if (kReleaseMode) {
          debugPrint('flutter_error: ${details.exceptionAsString()}');
        }
      };

      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
      // Draw behind the system bars; AnnotatedRegion in the app tints them.
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.edgeToEdge,
      );

      // Locale data for `intl`. The localizations delegate also does this on
      // every locale change; doing it here as well means the very first frame
      // can format a date without racing the delegate.
      await initializeDateFormatting();

      final container = ProviderContainer();
      await Future.wait([
        container.read(themeModeProvider.notifier).hydrate(),
        container.read(settingsProvider.notifier).hydrate(),
        // Before the first frame: hydrating the language later would flash
        // English chrome at a Hindi player on every cold start.
        container.read(appLanguageProvider.notifier).hydrate(),
      ]);
      // After the app language resolves, because a first install with no quiz
      // language stored defaults to whatever the app itself opened in.
      await container.read(quizLanguageProvider.notifier).hydrate(
            fallback: container.read(appLanguageProvider),
          );
      // Last, and before the first frame: it installs the hook that writes a
      // first run's answers to the account, and the router asks it which
      // screen a signed-out player gets on its very first redirect.
      await container.read(onboardingControllerProvider.notifier).hydrate();

      // Push, if this build was given a Firebase project. Awaited because a
      // notification that launched the app is delivered exactly once, and
      // starting after the first frame would drop it. It is a no-op — and
      // never throws — when the FIREBASE_* defines are absent.
      await container.read(pushServiceProvider).initialize();

      runApp(
        UncontrolledProviderScope(
          container: container,
          child: const SpeedQuizApp(),
        ),
      );
    },
    (error, stack) => debugPrint('uncaught_zone_error: $error\n$stack'),
  );
}

/// Shown instead of the framework's red box when a widget throws in release.
class _FatalErrorView extends StatelessWidget {
  const _FatalErrorView({required this.details});

  final FlutterErrorDetails details;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: AppColors.backgroundDarkBottom,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('⚡', style: TextStyle(fontSize: 40)),
                const SizedBox(height: AppSpacing.md),
                const Text(
                  'Something broke on this screen.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.textPrimaryDark,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  kReleaseMode
                      ? 'Go back and try again.'
                      : details.exceptionAsString(),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppColors.textSecondaryDark,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
