import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

    return DeepLinkListener(
      router: router,
      child: MaterialApp.router(
        title: 'SpeedQuiz',
        debugShowCheckedModeBanner: false,
        themeMode: themeMode,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        routerConfig: router,
      ),
    );
  }
}
