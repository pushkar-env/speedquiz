import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/feedback/audio_service.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/routing/deep_link_listener.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/core/theme/theme_mode_provider.dart';

class SpeedQuizApp extends ConsumerWidget {
  const SpeedQuizApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    final themeMode = ref.watch(themeModeProvider);
    // Instantiate for the app's lifetime so the static Sound facade is wired
    // before the first tap and the ambient loop can follow the setting.
    ref.watch(audioServiceProvider);

    return DeepLinkListener(
      router: router,
      child: MaterialApp.router(
        title: 'SpeedQuiz',
        debugShowCheckedModeBanner: false,
        themeMode: themeMode,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
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
