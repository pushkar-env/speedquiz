import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
import 'package:speedquiz/core/network/api_errors.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/routing/nav.dart';
import 'package:speedquiz/core/theme/app_motion.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/custom_topics/data/custom_topics_repository.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

class CustomTopicScreen extends ConsumerStatefulWidget {
  const CustomTopicScreen({super.key});

  @override
  ConsumerState<CustomTopicScreen> createState() => _CustomTopicScreenState();
}

class _CustomTopicScreenState extends ConsumerState<CustomTopicScreen> {
  final _createKey = GlobalKey<SqButtonState>();
  final _promptController = TextEditingController();
  final _styleController = TextEditingController();

  String _difficulty = 'medium';
  String _mode = 'casual';
  bool _preparing = false;
  String? _error;

  static const _suggestions = [
    'Elden Ring lore, but brutal',
    'Formula 1 rules and history',
    'Ancient Rome for a nerd',
    'Machine learning fundamentals',
    'Classic horror cinema',
  ];

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
      _createKey.currentState?.reject();
      setState(() => _error = 'Tell us what you want to be quizzed on.');
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _preparing = true;
      _error = null;
    });

    try {
      final result = await ref
          .read(customTopicsRepositoryProvider)
          .create(
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
          _error =
              'We could not build enough good questions for that. '
              'Try a clearer or broader topic.';
        });
        return;
      }

      Haptics.success();
      context.pushReplacement(
        Routes.quizPlay,
        extra: {
          'topicId': result.topicId,
          'topicName': result.topicName ?? result.classifiedSubject,
          'mode': _mode,
          'difficulty': _difficulty,
          'session': session,
        },
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _preparing = false;
        _error = apiErrorMessage(
          error,
          fallback: 'Could not prepare your challenge. Please try again.',
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    if (_preparing) return const _GeneratingView();

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SqBackdrop(
        intensity: 0.6,
        colors: const [AppColors.violet, AppColors.magenta, AppColors.accent],
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.sm,
                  AppSpacing.lg,
                  0,
                ),
                child: Row(
                  children: [
                    SqIconButton(
                      icon: Icons.close_rounded,
                      tooltip: 'Close',
                      onPressed: () => context.popOrGo(Routes.home),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Custom topic',
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.md,
                    AppSpacing.lg,
                    AppSpacing.lg,
                  ),
                  children: [
                    SqStagger(
                      child: Text(
                        'What do you want to\nbe quizzed on?',
                        style: theme.textTheme.headlineMedium?.copyWith(
                          height: 1.15,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SqStagger(
                      index: 1,
                      child: Text(
                        'Describe anything — games, science, lore, hobbies. '
                        'The AI writes and validates the questions.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    SqStagger(
                      index: 2,
                      child: TextField(
                        controller: _promptController,
                        maxLines: 3,
                        maxLength: 400,
                        textInputAction: TextInputAction.done,
                        style: theme.textTheme.bodyLarge,
                        onChanged: (_) {
                          if (_error != null) setState(() => _error = null);
                        },
                        decoration: const InputDecoration(
                          hintText:
                              'e.g. Ask me difficult questions about Elden '
                              'Ring lore',
                        ),
                      ),
                    ),
                    SqStagger(
                      index: 3,
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final suggestion in _suggestions)
                            _SuggestionChip(
                              label: suggestion,
                              onTap: () {
                                Haptics.tap();
                                setState(() {
                                  _promptController.text = suggestion;
                                  _error = null;
                                });
                              },
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    SqStagger(
                      index: 4,
                      child: const SqSectionHeader(title: 'Difficulty'),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    SqStagger(
                      index: 5,
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final (value, label) in _difficulties)
                            _Pill(
                              label: label,
                              selected: _difficulty == value,
                              onTap: () {
                                Haptics.tap();
                                setState(() => _difficulty = value);
                              },
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    SqStagger(
                      index: 6,
                      child: const SqSectionHeader(title: 'Mode'),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    SqStagger(
                      index: 7,
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final (value, label) in _modes)
                            _Pill(
                              label: label,
                              selected: _mode == value,
                              onTap: () {
                                Haptics.tap();
                                setState(() => _mode = value);
                              },
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    SqStagger(
                      index: 8,
                      child: const SqSectionHeader(
                        title: 'Style',
                        subtitle: 'Optional — how should the questions feel?',
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    SqStagger(
                      index: 9,
                      child: TextField(
                        controller: _styleController,
                        maxLength: 120,
                        style: theme.textTheme.bodyLarge,
                        decoration: const InputDecoration(
                          hintText: 'e.g. lore-heavy, trivia, practical',
                        ),
                      ),
                    ),
                    AnimatedSize(
                      duration: AppMotion.normal,
                      curve: AppMotion.enter,
                      child: _error == null
                          ? const SizedBox(width: double.infinity)
                          : Padding(
                              padding: const EdgeInsets.only(
                                top: AppSpacing.sm,
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Icon(
                                    Icons.error_outline_rounded,
                                    size: 17,
                                    color: AppColors.danger,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      _error!,
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(color: AppColors.danger),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                    ),
                  ],
                ),
              ),
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [p.background.withValues(alpha: 0), p.background],
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.md,
                  AppSpacing.lg,
                  AppSpacing.md,
                ),
                child: SafeArea(
                  top: false,
                  child: SqButton(
                    key: _createKey,
                    label: 'CREATE QUIZ',
                    icon: Icons.auto_awesome_rounded,
                    onPressed: _create,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Generation can take a while with a real LLM, so the wait gets its own
/// screen with rotating status copy instead of a bare spinner.
class _GeneratingView extends StatefulWidget {
  const _GeneratingView();

  @override
  State<_GeneratingView> createState() => _GeneratingViewState();
}

class _GeneratingViewState extends State<_GeneratingView>
    with SingleTickerProviderStateMixin {
  static const _stages = [
    ('🧭', 'Understanding your topic'),
    ('✍️', 'Writing candidate questions'),
    ('🔍', 'Fact-checking every answer'),
    ('🎲', 'Shuffling the good ones in'),
  ];

  late final AnimationController _controller =
      AnimationController(vsync: this, duration: const Duration(seconds: 3))
        ..addStatusListener((status) {
          if (status == AnimationStatus.completed && mounted) {
            setState(() => _stage = (_stage + 1) % _stages.length);
            _controller.forward(from: 0);
          }
        });

  int _stage = 0;

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SqBackdrop(
        colors: const [AppColors.violet, AppColors.magenta, AppColors.accent],
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 76,
                    height: 76,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: p.accent,
                      backgroundColor: p.border,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  Text(
                    'Building your quiz',
                    style: theme.textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AnimatedSwitcher(
                    duration: AppMotion.normal,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 0.4),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    ),
                    child: Row(
                      key: ValueKey(_stage),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _stages[_stage].$1,
                          style: const TextStyle(fontSize: 17),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _stages[_stage].$2,
                          style: theme.textTheme.bodyLarge,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  Text(
                    'This one runs a real model, so it takes a few seconds. '
                    'Everything after this is served instantly.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: p.textFaint,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SuggestionChip extends StatelessWidget {
  const _SuggestionChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return SqPressable(
      onTap: onTap,
      haptic: false,
      pressedScale: 0.94,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.violet.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(AppRadii.pill),
          border: Border.all(color: AppColors.violet.withValues(alpha: 0.28)),
        ),
        child: Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: p.isDark ? AppColors.violet : const Color(0xFF5B4BD8),
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return SqPressable(
      onTap: onTap,
      haptic: false,
      pressedScale: 0.94,
      child: AnimatedContainer(
        duration: AppMotion.fast,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? p.accentWash(0.18) : p.surface,
          borderRadius: BorderRadius.circular(AppRadii.pill),
          border: Border.all(
            color: selected ? p.accent : p.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: selected ? p.accent : p.textPrimary,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
