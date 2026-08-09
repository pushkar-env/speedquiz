import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:quizverse/core/routing/app_router.dart';
import 'package:quizverse/core/theme/app_theme.dart';
import 'package:quizverse/core/theme/theme_mode_provider.dart';

class QuizVerseApp extends ConsumerWidget {
  const QuizVerseApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    final themeMode = ref.watch(themeModeProvider);

    return MaterialApp.router(
      title: 'QuizVerse',
      debugShowCheckedModeBanner: false,
      themeMode: themeMode,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      routerConfig: router,
    );
  }
}
