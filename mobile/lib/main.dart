import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:quizverse/app.dart';
import 'package:quizverse/core/theme/theme_mode_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);
  final container = ProviderContainer();
  await container.read(themeModeProvider.notifier).hydrate();
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const QuizVerseApp(),
    ),
  );
}
