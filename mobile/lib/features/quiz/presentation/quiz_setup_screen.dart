import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
import 'package:speedquiz/core/network/api_errors.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/routing/nav.dart';
import 'package:speedquiz/core/theme/app_motion.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/topics/data/topics_repository.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

class QuizSetupScreen extends ConsumerStatefulWidget {
  const QuizSetupScreen({
    super.key,
    this.initialTopicId,
    this.initialTopicName,
  });

  final String? initialTopicId;
  final String? initialTopicName;

  @override
  ConsumerState<QuizSetupScreen> createState() => _QuizSetupScreenState();
}

class _QuizSetupScreenState extends ConsumerState<QuizSetupScreen> {
  final _startKey = GlobalKey<SqButtonState>();
  final _topicSectionKey = GlobalKey();
  final _scrollController = ScrollController();

  String? _topicId;
  String? _topicName;
  String _difficulty = 'medium';
  String _mode = 'casual';
  bool _starting = false;

  bool get _adaptive => _difficulty == 'adaptive';

  static const _difficulties = [
    ('easy', 'Easy', '🌱'),
    ('medium', 'Medium', '⚖️'),
    ('hard', 'Hard', '🔥'),
    ('expert', 'Expert', '💀'),
    ('adaptive', 'Adaptive', '🎯'),
  ];

  static const _modes = [
    (
      'casual',
      'Casual',
      'Endless run with speed bonuses and streak multipliers',
      Icons.all_inclusive_rounded,
      AppColors.accent,
    ),
    (
      'speedrun',
      'Speedrun',
      'One global timer, questions auto-advance',
      Icons.bolt_rounded,
      AppColors.gold,
    ),
    (
      'survival',
      'Survival',
      'Three lives — a streak earns one back',
      Icons.favorite_rounded,
      AppColors.magenta,
    ),
    (
      'negative',
      'Negative',
      'Start at 1000, every mistake costs you',
      Icons.trending_down_rounded,
      AppColors.violet,
    ),
    (
      'sudden_death',
      'Sudden Death',
      'One wrong answer ends the run',
      Icons.dangerous_rounded,
      AppColors.danger,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _topicId = widget.initialTopicId;
    _topicName = widget.initialTopicName;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _select(TopicItem topic) {
    Haptics.tap();
    setState(() {
      _topicId = topic.id;
      _topicName = topic.name;
    });
  }

  void _selectRandom() {
    final topic = ref.read(randomTopicProvider);
    if (topic == null) {
      SqToast.warning(context, 'No topic has questions ready yet.');
      return;
    }
    Haptics.success();
    setState(() {
      _topicId = topic.id;
      _topicName = topic.name;
    });
    SqToast.info(context, '🎲 ${topic.name} it is.');
  }

  Future<void> _start() async {
    if (_topicId == null) {
      // Reject inline instead of interrupting with a modal.
      _startKey.currentState?.reject();
      SqToast.warning(context, 'Pick a topic to start your run.');
      final ctx = _topicSectionKey.currentContext;
      if (ctx != null) {
        await Scrollable.ensureVisible(
          ctx,
          duration: AppMotion.normal,
          curve: AppMotion.enter,
          alignment: 0.05,
        );
      }
      return;
    }

    setState(() => _starting = true);
    await context.push(
      Routes.quizPlay,
      extra: {
        'topicId': _topicId,
        'topicName': _topicName,
        'mode': _mode,
        'difficulty': _adaptive ? 'medium' : _difficulty,
        'adaptive': _adaptive,
      },
    );
    if (mounted) setState(() => _starting = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final topics = ref.watch(topicsProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SqBackdrop(
        intensity: 0.55,
        child: SafeArea(
          child: Column(
            children: [
              _SetupHeader(mode: _mode, difficulty: _difficulty),
              Expanded(
                child: ListView(
                  controller: _scrollController,
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.sm,
                    AppSpacing.lg,
                    AppSpacing.lg,
                  ),
                  children: [
                    SqStagger(
                      key: _topicSectionKey,
                      child: const SqSectionHeader(
                        title: 'Topic',
                        subtitle: 'What do you want to be quizzed on?',
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    SqStagger(
                      index: 1,
                      child: topics.when(
                        loading: () => const SqShimmer(
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              SqSkeleton(width: 110, height: 40, radius: 999),
                              SqSkeleton(width: 92, height: 40, radius: 999),
                              SqSkeleton(width: 128, height: 40, radius: 999),
                              SqSkeleton(width: 104, height: 40, radius: 999),
                            ],
                          ),
                        ),
                        error: (error, _) => SqErrorState(
                          title: 'Could not load topics',
                          message: apiErrorMessage(error),
                          onRetry: () => ref.invalidate(topicsProvider),
                        ),
                        data: (items) => _TopicPicker(
                          items: items,
                          selectedId: _topicId,
                          onSelect: _select,
                          onCustom: () => context.push(Routes.customTopic),
                          onRandom: _selectRandom,
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    SqStagger(
                      index: 2,
                      child: SqSectionHeader(
                        title: 'Difficulty',
                        subtitle: _adaptive
                            ? 'The game tunes itself to your skill as you play'
                            : 'Pick a fixed band, or let Adaptive decide',
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    SqStagger(
                      index: 3,
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final (value, label, glyph) in _difficulties)
                            _Choice(
                              label: '$glyph  $label',
                              selected: _difficulty == value,
                              onTap: () {
                                Haptics.tap();
                                setState(() => _difficulty = value);
                              },
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    SqStagger(
                      index: 4,
                      child: const SqSectionHeader(
                        title: 'Mode',
                        subtitle: 'Every mode scores differently',
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    for (var i = 0; i < _modes.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: SqStagger(
                          index: 5 + i,
                          child: _ModeCard(
                            title: _modes[i].$2,
                            subtitle: _modes[i].$3,
                            icon: _modes[i].$4,
                            tint: _modes[i].$5,
                            selected: _mode == _modes[i].$1,
                            onTap: () {
                              Haptics.tap();
                              setState(() => _mode = _modes[i].$1);
                            },
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              // Sticky CTA over a soft fade so content scrolls under it.
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
                    key: _startKey,
                    label: _topicName == null
                        ? 'PICK A TOPIC'
                        : 'START · ${_topicName!.toUpperCase()}',
                    icon: Icons.play_arrow_rounded,
                    loading: _starting,
                    onPressed: _starting ? null : _start,
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

class _SetupHeader extends StatelessWidget {
  const _SetupHeader({required this.mode, required this.difficulty});

  final String mode;
  final String difficulty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
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
            // Setup is also entered with `go` (from results → NEW RUN), where
            // there is nothing to pop — fall through to Home instead of
            // becoming a dead button.
            onPressed: () => context.popOrGo(Routes.home),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('New run', style: theme.textTheme.titleLarge),
                Text(
                  '${humanizeMode(mode)} · ${humanizeMode(difficulty)}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Topic picker grouped by category, so a long catalog stays scannable
/// instead of collapsing into one undifferentiated wall of chips.
class _TopicPicker extends StatelessWidget {
  const _TopicPicker({
    required this.items,
    required this.selectedId,
    required this.onSelect,
    required this.onCustom,
    required this.onRandom,
  });

  final List<TopicItem> items;
  final String? selectedId;
  final ValueChanged<TopicItem> onSelect;
  final VoidCallback onCustom;
  final VoidCallback onRandom;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final playable = items.where((t) => t.isPlayable).toList();

    if (playable.isEmpty) {
      return SqEmptyState(
        icon: '🌱',
        title: 'Bank still filling',
        message: 'No topic has questions ready yet. Build your own instead.',
        action: SqButton(
          label: 'CREATE CUSTOM TOPIC',
          expand: false,
          icon: Icons.auto_awesome_rounded,
          onPressed: onCustom,
        ),
      );
    }

    final groups = groupTopics(playable);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _ActionChip(
                label: 'Random topic',
                glyph: '🎲',
                tint: AppColors.violet,
                onTap: onRandom,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _ActionChip(
                label: 'Custom topic',
                glyph: '✨',
                tint: AppColors.magenta,
                onTap: onCustom,
              ),
            ),
          ],
        ),
        for (final group in groups) ...[
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Text(group.category.icon, style: const TextStyle(fontSize: 13)),
              const SizedBox(width: 6),
              Text(
                group.category.name.toUpperCase(),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: p.textFaint,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final topic in group.topics)
                _Choice(
                  label: '${topic.icon}  ${topic.name}',
                  selected: topic.id == selectedId,
                  onTap: () => onSelect(topic),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _ActionChip extends StatelessWidget {
  const _ActionChip({
    required this.label,
    required this.glyph,
    required this.tint,
    required this.onTap,
  });

  final String label;
  final String glyph;
  final Color tint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SqPressable(
      onTap: onTap,
      pressedScale: 0.95,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: tint.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(AppRadii.md),
          border: Border.all(color: tint.withValues(alpha: 0.32)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(glyph, style: const TextStyle(fontSize: 15)),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({
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
        curve: AppMotion.standard,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: selected ? p.accentWash(0.18) : p.surface,
          borderRadius: BorderRadius.circular(AppRadii.pill),
          border: Border.all(
            color: selected ? p.accent : p.border,
            width: selected ? 1.5 : 1,
          ),
          // A static bloom on the chosen chip: cheap enough to sit on every
          // chip in a wrap, and it makes the selection findable at a glance.
          boxShadow: selected
              ? AppShadows.glow(AppColors.accent, strength: 0.22)
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected) ...[
              Icon(Icons.check_rounded, size: 15, color: p.accent),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: selected ? p.accent : p.textPrimary,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.tint,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color tint;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return SqSurface(
      onTap: onTap,
      highlighted: selected,
      glow: selected,
      accent: tint,
      child: Row(
        children: [
          AnimatedContainer(
            duration: AppMotion.fast,
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: tint.withValues(alpha: selected ? 0.22 : 0.12),
              borderRadius: BorderRadius.circular(AppRadii.sm),
              border: Border.all(
                color: tint.withValues(alpha: selected ? 0.5 : 0.2),
              ),
            ),
            child: Icon(icon, color: tint, size: 21),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleMedium),
                const SizedBox(height: 1),
                Text(subtitle, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(width: 8),
          AnimatedSwitcher(
            duration: AppMotion.fast,
            transitionBuilder: (child, animation) =>
                ScaleTransition(scale: animation, child: child),
            child: Icon(
              selected
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_unchecked_rounded,
              key: ValueKey(selected),
              color: selected ? tint : p.textFaint,
              size: 22,
            ),
          ),
        ],
      ),
    );
  }
}
