import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:quizverse/core/theme/app_theme.dart';
import 'package:quizverse/features/explore/presentation/explore_screen.dart';
import 'package:quizverse/shared/widgets/qv_button.dart';

class QuizSetupScreen extends ConsumerStatefulWidget {
  const QuizSetupScreen({super.key, this.initialTopicId, this.initialTopicName});

  final String? initialTopicId;
  final String? initialTopicName;

  @override
  ConsumerState<QuizSetupScreen> createState() => _QuizSetupScreenState();
}

class _QuizSetupScreenState extends ConsumerState<QuizSetupScreen> {
  String? _topicId;
  String? _topicName;
  String _difficulty = 'medium';
  String _mode = 'casual';
  bool _starting = false;

  static const _difficulties = [
    ('easy', 'Easy'),
    ('medium', 'Medium'),
    ('hard', 'Hard'),
    ('expert', 'Expert'),
  ];

  static const _modes = [
    ('casual', 'Casual', 'Endless · speed bonus · streaks', Icons.all_inclusive_rounded),
    ('speedrun', 'Speedrun', 'Global timer · auto-advance', Icons.bolt_rounded),
    ('survival', 'Survival', '3 lives · streak restores', Icons.favorite_rounded),
    ('negative', 'Negative', 'Start at 1000 · mistakes hurt', Icons.trending_down_rounded),
    ('sudden_death', 'Sudden Death', 'One miss ends the run', Icons.dangerous_rounded),
  ];

  @override
  void initState() {
    super.initState();
    _topicId = widget.initialTopicId;
    _topicName = widget.initialTopicName;
  }

  Future<void> _start() async {
    if (_topicId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pick a topic first')),
      );
      return;
    }
    setState(() => _starting = true);
    if (!mounted) return;
    await context.push(
      '/quiz/play',
      extra: {
        'topicId': _topicId,
        'topicName': _topicName,
        'mode': _mode,
        'difficulty': _difficulty,
      },
    );
    if (mounted) setState(() => _starting = false);
  }

  @override
  Widget build(BuildContext context) {
    final topics = ref.watch(topicsProvider);
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(title: const Text('New Run')),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.sm,
                AppSpacing.lg,
                AppSpacing.lg,
              ),
              children: [
                Text('Topic', style: theme.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  'What do you want to be quizzed on?',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: AppSpacing.md),
                topics.when(
                  loading: () => const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: CircularProgressIndicator(color: AppColors.accent),
                    ),
                  ),
                  error: (e, _) => QvSurface(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Could not load topics'),
                        const SizedBox(height: 8),
                        QvButton(
                          label: 'Retry',
                          onPressed: () => ref.invalidate(topicsProvider),
                        ),
                      ],
                    ),
                  ),
                  data: (items) {
                    return Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: items.map((t) {
                        final selected = t.id == _topicId;
                        return FilterChip(
                          selected: selected,
                          showCheckmark: false,
                          label: Text('${t.icon}  ${t.name}'),
                          selectedColor: AppColors.accent.withValues(alpha: 0.18),
                          checkmarkColor: AppColors.accent,
                          side: BorderSide(
                            color: selected
                                ? AppColors.accent
                                : (dark
                                    ? AppColors.borderDark
                                    : AppColors.borderLight),
                          ),
                          onSelected: (_) => setState(() {
                            _topicId = t.id;
                            _topicName = t.name;
                          }),
                        );
                      }).toList(),
                    );
                  },
                ),
                const SizedBox(height: AppSpacing.xl),
                Text('Difficulty', style: theme.textTheme.titleLarge),
                const SizedBox(height: AppSpacing.md),
                Row(
                  children: _difficulties.map((d) {
                    final selected = _difficulty == d.$1;
                    return Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(
                          right: d != _difficulties.last ? 8 : 0,
                        ),
                        child: _DiffTile(
                          label: d.$2,
                          selected: selected,
                          onTap: () => setState(() => _difficulty = d.$1),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: AppSpacing.xl),
                Text('Mode', style: theme.textTheme.titleLarge),
                const SizedBox(height: AppSpacing.md),
                ..._modes.map((m) {
                  final selected = _mode == m.$1;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: QvSurface(
                      highlighted: selected,
                      onTap: () => setState(() => _mode = m.$1),
                      child: Row(
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: (selected ? AppColors.accent : AppColors.warning)
                                  .withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(AppRadii.sm),
                            ),
                            child: Icon(
                              m.$4,
                              color: selected ? AppColors.accent : AppColors.warning,
                              size: 22,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(m.$2, style: theme.textTheme.titleMedium),
                                Text(m.$3, style: theme.textTheme.bodyMedium),
                              ],
                            ),
                          ),
                          Icon(
                            selected
                                ? Icons.check_circle_rounded
                                : Icons.circle_outlined,
                            color: selected
                                ? AppColors.accent
                                : theme.colorScheme.onSurface
                                    .withValues(alpha: 0.35),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                0,
                AppSpacing.lg,
                AppSpacing.md,
              ),
              child: QvButton(
                label: _topicName == null
                    ? 'START'
                    : 'START · ${_topicName!.toUpperCase()}',
                loading: _starting,
                onPressed: _starting ? null : _start,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DiffTile extends StatelessWidget {
  const _DiffTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: selected
          ? AppColors.accent.withValues(alpha: 0.16)
          : (dark ? AppColors.surfaceDark : AppColors.surfaceLight),
      borderRadius: BorderRadius.circular(AppRadii.sm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.sm),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(vertical: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.sm),
            border: Border.all(
              color: selected
                  ? AppColors.accent
                  : (dark ? AppColors.borderDark : AppColors.borderLight),
            ),
          ),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: selected ? AppColors.accent : null,
                  fontWeight: FontWeight.w700,
                ),
          ),
        ),
      ),
    );
  }
}
