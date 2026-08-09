import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:quizverse/core/network/api_errors.dart';
import 'package:quizverse/core/theme/app_theme.dart';
import 'package:quizverse/features/custom_topics/data/custom_topics_repository.dart';
import 'package:quizverse/shared/widgets/qv_button.dart';

class CustomTopicScreen extends ConsumerStatefulWidget {
  const CustomTopicScreen({super.key});

  @override
  ConsumerState<CustomTopicScreen> createState() => _CustomTopicScreenState();
}

class _CustomTopicScreenState extends ConsumerState<CustomTopicScreen> {
  final _promptController = TextEditingController();
  final _styleController = TextEditingController();
  String _difficulty = 'medium';
  String _mode = 'casual';
  bool _preparing = false;
  String? _error;

  static const _difficulties = [
    ('easy', 'Easy'),
    ('medium', 'Medium'),
    ('hard', 'Hard'),
    ('expert', 'Expert'),
  ];

  static const _modes = [
    ('casual', 'Casual'),
    ('speedrun', 'Speedrun'),
    ('survival', 'Survival'),
    ('negative', 'Negative'),
    ('sudden_death', 'Sudden Death'),
  ];

  @override
  void dispose() {
    _promptController.dispose();
    _styleController.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final prompt = _promptController.text.trim();
    if (prompt.length < 3) {
      setState(() => _error = 'Tell us what you want to be quizzed on');
      return;
    }

    setState(() {
      _preparing = true;
      _error = null;
    });

    try {
      final result = await ref.read(customTopicsRepositoryProvider).create(
            prompt: prompt,
            difficulty: _difficulty,
            mode: _mode,
            style: _styleController.text.trim().isEmpty
                ? null
                : _styleController.text.trim(),
          );

      if (!mounted) return;

      final session = result.session;
      if (session == null || result.topicId == null) {
        setState(() {
          _preparing = false;
          _error = "Couldn't prepare enough good questions. Try a clearer topic.";
        });
        return;
      }

      context.pushReplacement(
        '/quiz/play',
        extra: {
          'topicId': result.topicId,
          'topicName': result.topicName ?? result.classifiedSubject,
          'mode': _mode,
          'difficulty': _difficulty,
          'session': session,
        },
      );
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() {
        _preparing = false;
        _error = apiErrorMessage(
          e,
          fallback: "Couldn't prepare your challenge. Please try again.",
        );
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _preparing = false;
        _error = "Something went wrong. Please try again.";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;

    if (_preparing) {
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 56,
                    height: 56,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: AppColors.accent,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Text(
                    'Preparing your challenge…',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Crafting questions worth your time',
                    style: theme.textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Custom Topic')),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.md,
                AppSpacing.lg,
                AppSpacing.lg,
              ),
              children: [
                Text(
                  'What do you want to be quizzed on?',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  'Describe any topic — games, science, lore, hobbies…',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: AppSpacing.lg),
                TextField(
                  controller: _promptController,
                  maxLines: 3,
                  maxLength: 400,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    hintText: 'e.g. Ask me difficult questions about Elden Ring lore',
                    filled: true,
                    fillColor:
                        dark ? AppColors.surfaceDark : AppColors.surfaceLight,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadii.md),
                      borderSide: BorderSide(
                        color: dark ? AppColors.borderDark : AppColors.borderLight,
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadii.md),
                      borderSide: BorderSide(
                        color: dark ? AppColors.borderDark : AppColors.borderLight,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                Text('Difficulty', style: theme.textTheme.titleMedium),
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final (value, label) in _difficulties)
                      ChoiceChip(
                        label: Text(label),
                        selected: _difficulty == value,
                        onSelected: (_) => setState(() => _difficulty = value),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),
                Text('Mode', style: theme.textTheme.titleMedium),
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final (value, label) in _modes)
                      ChoiceChip(
                        label: Text(label),
                        selected: _mode == value,
                        onSelected: (_) => setState(() => _mode = value),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),
                Text(
                  'Style (optional)',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: _styleController,
                  maxLength: 120,
                  decoration: InputDecoration(
                    hintText: 'e.g. lore-heavy, trivia, practical',
                    filled: true,
                    fillColor:
                        dark ? AppColors.surfaceDark : AppColors.surfaceLight,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadii.md),
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    _error!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: AppColors.danger,
                    ),
                  ),
                ],
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.sm,
                AppSpacing.lg,
                AppSpacing.md,
              ),
              child: QvButton(label: 'CREATE QUIZ', onPressed: _create),
            ),
          ),
        ],
      ),
    );
  }
}
