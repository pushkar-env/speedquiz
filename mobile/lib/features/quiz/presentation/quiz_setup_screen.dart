import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
import 'package:speedquiz/core/i18n/game_labels.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/i18n/language_providers.dart';
import 'package:speedquiz/core/i18n/widgets/language_picker.dart';
import 'package:speedquiz/core/network/api_errors.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/routing/nav.dart';
import 'package:speedquiz/core/theme/app_motion.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/topics/data/topics_repository.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// Run setup.
///
/// Laid out so nothing that matters is below the fold. Mode and difficulty are
/// two quick decisions with sensible defaults, so they sit in a fixed band at
/// the top; the topic catalog is the long, browsable part, so it owns the only
/// scrolling region. The previous layout stacked all three, which buried mode
/// selection under a wall of topic chips — most players never saw it.
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
  final _scrollController = ScrollController();
  final _searchController = TextEditingController();

  String? _topicId;
  String? _topicName;
  String _difficulty = 'medium';
  String _mode = 'casual';
  String _query = '';
  bool _starting = false;

  bool get _adaptive => _difficulty == 'adaptive';

  List<(String, String, String)> _difficulties(SqStrings l10n) => [
        ('easy', l10n.difficultyEasy, '🌱'),
        ('medium', l10n.difficultyMedium, '⚖️'),
        ('hard', l10n.difficultyHard, '🔥'),
        ('expert', l10n.difficultyExpert, '💀'),
        ('adaptive', l10n.difficultyAdaptive, '🎯'),
      ];

  /// The three modes that survived the cull. Negative was casual with the sign
  /// flipped and sudden death ended most runs on question three; survival now
  /// carries the "real stakes" slot on its own.
  List<(String, String, String, IconData, Color)> _modes(SqStrings l10n) => [
        (
          'casual',
          l10n.setupModeCasual,
          l10n.setupModeCasualHook,
          Icons.all_inclusive_rounded,
          AppColors.accent,
        ),
        (
          'speedrun',
          l10n.setupModeSpeedrun,
          l10n.setupModeSpeedrunHook,
          Icons.bolt_rounded,
          AppColors.gold,
        ),
        (
          'survival',
          l10n.setupModeSurvival,
          l10n.setupModeSurvivalHook,
          Icons.favorite_rounded,
          AppColors.magenta,
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
    _searchController.dispose();
    super.dispose();
  }

  void _select(TopicItem topic) {
    Haptics.tap();
    setState(() {
      _topicId = topic.id;
      _topicName = topic.name;
    });
  }

  /// A topic whose bank is still generating — or that exists in the catalog
  /// but not yet in the chosen quiz language. Say which, plainly: "come back
  /// later" and "try another language" are different instructions.
  void _selectLocked(TopicItem topic) {
    Haptics.tap();
    final language = ref.read(quizLanguageProvider);
    final l10n = context.l10n;
    if (topic.isPlayable && !topic.isPlayableIn(language.code)) {
      SqToast.info(
        context,
        l10n.languageBankEmptyHint(language.nativeLabel),
      );
      return;
    }
    SqToast.info(context, l10n.setupTopicStillWriting(topic.name));
  }

  void _selectRandom() {
    final topic = ref.read(randomTopicProvider);
    final l10n = context.l10n;
    if (topic == null) {
      final language = ref.read(quizLanguageProvider);
      SqToast.warning(
        context,
        // Distinguish "nothing anywhere" from "nothing in Hindi" — the second
        // has an obvious fix the player can act on.
        ref.read(playableTopicsProvider).isEmpty
            ? l10n.setupNoTopicReady
            : l10n.languageBankEmptyHint(language.nativeLabel),
      );
      return;
    }
    Haptics.success();
    setState(() {
      _topicId = topic.id;
      _topicName = topic.name;
    });
    SqToast.info(context, l10n.setupRandomPicked(topic.name));
  }

  Future<void> _start() async {
    if (_topicId == null) {
      // Reject inline instead of interrupting with a modal.
      _startKey.currentState?.reject();
      SqToast.warning(context, context.l10n.setupPickTopicToStart);
      if (_scrollController.hasClients) {
        await _scrollController.animateTo(
          0,
          duration: AppMotion.normal,
          curve: AppMotion.enter,
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
        // The run's content language. Fixed here rather than read at play
        // time: the session the server creates is stamped with it, and a
        // language change mid-run would leave the player mid-quiz in a bank
        // they cannot read.
        'language': ref.read(quizLanguageProvider).code,
      },
    );
    if (mounted) setState(() => _starting = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final l10n = context.l10n;
    final topics = ref.watch(topicsProvider);
    final quizLanguage = ref.watch(quizLanguageProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SqBackdrop(
        intensity: 0.55,
        child: SafeArea(
          child: Column(
            children: [
              _SetupHeader(mode: _mode, difficulty: _difficulty),

              // --- Fixed band: the quick decisions ----------------------
              SqStagger(
                child: _ModeCarousel(
                  modes: _modes(l10n),
                  selected: _mode,
                  onSelect: (value) {
                    Haptics.tap();
                    setState(() => _mode = value);
                  },
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              SqStagger(
                index: 1,
                child: _DifficultyRow(
                  difficulties: _difficulties(l10n),
                  selected: _difficulty,
                  onSelect: (value) {
                    Haptics.tap();
                    setState(() => _difficulty = value);
                  },
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              // Language sits with mode and difficulty because it is the same
              // kind of decision — a property of *this run*, set before it
              // starts and fixed once it does.
              SqStagger(
                index: 2,
                child: _QuizLanguageBar(
                  selected: quizLanguage,
                  // Availability is computed from the loaded catalog so an
                  // empty language is visible before the player commits a
                  // topic to it, not after.
                  availability: {
                    for (final language in AppLanguage.values)
                      language: (topics.valueOrNull ?? const [])
                          .any((t) => t.isPlayableIn(language.code)),
                  },
                  onSelect: (language) {
                    if (language == quizLanguage) return;
                    Haptics.tap();
                    ref
                        .read(quizLanguageProvider.notifier)
                        .setLanguage(language);
                    // A topic chosen for the old language may have no bank in
                    // the new one — drop it rather than start a run that
                    // cannot be dealt.
                    final selected = (topics.valueOrNull ?? const [])
                        .where((t) => t.id == _topicId)
                        .firstOrNull;
                    if (selected != null &&
                        !selected.isPlayableIn(language.code)) {
                      setState(() {
                        _topicId = null;
                        _topicName = null;
                      });
                    }
                  },
                ),
              ),

              const SizedBox(height: AppSpacing.md),
              Divider(height: 1, color: p.border.withValues(alpha: 0.6)),

              // --- Scrolling region: the topic catalog -------------------
              Expanded(
                child: topics.when(
                  loading: () => const _TopicSkeleton(),
                  error: (error, _) => Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: SqErrorState(
                      title: l10n.setupCouldNotLoadTopics,
                      message: apiErrorMessage(error),
                      onRetry: () => ref.invalidate(topicsProvider),
                    ),
                  ),
                  data: (items) => _TopicBrowser(
                    controller: _scrollController,
                    searchController: _searchController,
                    items: items,
                    query: _query,
                    selectedId: _topicId,
                    languageCode: quizLanguage.code,
                    onQuery: (value) => setState(() => _query = value),
                    onSelect: _select,
                    onLocked: _selectLocked,
                    onCustom: () => context.push(Routes.customTopic),
                    onRandom: _selectRandom,
                  ),
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
                        ? l10n.setupPickATopic
                        : l10n.startWithTopic(_topicName!),
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

/// The run's content language, as a labelled strip under the difficulty rail.
class _QuizLanguageBar extends StatelessWidget {
  const _QuizLanguageBar({
    required this.selected,
    required this.availability,
    required this.onSelect,
  });

  final AppLanguage selected;
  final Map<AppLanguage, bool> availability;
  final ValueChanged<AppLanguage> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final l10n = context.l10n;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: Row(
        children: [
          Icon(Icons.translate_rounded, size: 15, color: p.textFaint),
          const SizedBox(width: 6),
          Text(
            l10n.quizLanguageTitle,
            style: theme.textTheme.labelSmall?.copyWith(
              color: p.textFaint,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SqLanguagePicker(
              selected: selected,
              dense: true,
              tint: AppColors.violet,
              availability: availability,
              onChanged: onSelect,
            ),
          ),
        ],
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
        AppSpacing.sm,
      ),
      child: Row(
        children: [
          SqIconButton(
            icon: Icons.close_rounded,
            tooltip: context.l10n.close,
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
                Text(context.l10n.setupTitle, style: theme.textTheme.titleLarge),
                Text(
                  '${localizedMode(context, mode)} · '
                  '${localizedDifficulty(context, difficulty)}',
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

/// Mode as a horizontal rail of cards, pinned above the fold.
///
/// Three wide cards would not fit legibly, and a dropdown hides the one thing
/// that most changes how a run feels — so they scroll sideways with the
/// selected card visibly lifted.
class _ModeCarousel extends StatelessWidget {
  const _ModeCarousel({
    required this.modes,
    required this.selected,
    required this.onSelect,
  });

  final List<(String, String, String, IconData, Color)> modes;
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 112 + context.scriptExtraHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        itemCount: modes.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final (value, title, hook, icon, tint) = modes[i];
          return _ModeCard(
            title: title,
            hook: hook,
            icon: icon,
            tint: tint,
            selected: selected == value,
            onTap: () => onSelect(value),
          );
        },
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.title,
    required this.hook,
    required this.icon,
    required this.tint,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String hook;
  final IconData icon;
  final Color tint;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return SqPressable(
      onTap: onTap,
      haptic: false,
      pressedScale: 0.95,
      child: AnimatedContainer(
        duration: AppMotion.fast,
        curve: AppMotion.standard,
        width: 156,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          gradient: selected
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    tint.withValues(alpha: 0.26),
                    tint.withValues(alpha: 0.06),
                  ],
                )
              : null,
          color: selected ? null : p.surface,
          borderRadius: BorderRadius.circular(AppRadii.md),
          border: Border.all(
            color: selected ? tint : p.border,
            width: selected ? 1.6 : 1,
          ),
          boxShadow:
              selected ? AppShadows.glow(tint, strength: 0.26) : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AnimatedContainer(
                  duration: AppMotion.fast,
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: tint.withValues(alpha: selected ? 0.28 : 0.12),
                    borderRadius: BorderRadius.circular(AppRadii.sm),
                  ),
                  child: Icon(icon, color: tint, size: 18),
                ),
                const Spacer(),
                AnimatedScale(
                  duration: AppMotion.fast,
                  curve: Curves.easeOutBack,
                  scale: selected ? 1 : 0,
                  child: Icon(
                    Icons.check_circle_rounded,
                    color: tint,
                    size: 18,
                  ),
                ),
              ],
            ),
            const Spacer(),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                color: selected ? tint : p.textPrimary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              hook,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

/// Difficulty as one horizontal rail — five small chips, no wrapping, no
/// section header. It is a secondary decision and should not cost a section.
class _DifficultyRow extends StatelessWidget {
  const _DifficultyRow({
    required this.difficulties,
    required this.selected,
    required this.onSelect,
  });

  final List<(String, String, String)> difficulties;
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 38 + context.scriptExtraHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        itemCount: difficulties.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final (value, label, glyph) = difficulties[i];
          return _Choice(
            label: '$glyph  $label',
            selected: selected == value,
            dense: true,
            onTap: () => onSelect(value),
          );
        },
      ),
    );
  }
}

/// The topic catalog: search, quick actions, then grouped chips.
class _TopicBrowser extends StatelessWidget {
  const _TopicBrowser({
    required this.controller,
    required this.searchController,
    required this.items,
    required this.query,
    required this.selectedId,
    required this.languageCode,
    required this.onQuery,
    required this.onSelect,
    required this.onLocked,
    required this.onCustom,
    required this.onRandom,
  });

  final ScrollController controller;
  final TextEditingController searchController;
  final List<TopicItem> items;
  final String query;
  final String? selectedId;

  /// The chosen quiz language. Splits the catalog into "playable now" and
  /// "exists, but not in this language yet".
  final String languageCode;

  final ValueChanged<String> onQuery;
  final ValueChanged<TopicItem> onSelect;
  final ValueChanged<TopicItem> onLocked;
  final VoidCallback onCustom;
  final VoidCallback onRandom;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final l10n = context.l10n;
    final playable = items.where((t) => t.isPlayableIn(languageCode)).toList();

    // Topics whose bank is still being generated, or not yet written in this
    // language. Shown rather than hidden: a catalog that silently omits half
    // its entries looks sparse and gives the player no idea more is coming.
    // They are visibly locked and cannot be selected, so nobody dead-ends on
    // an empty topic.
    final filling = items.where((t) => !t.isPlayableIn(languageCode)).toList();

    if (playable.isEmpty && filling.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: SqEmptyState(
          icon: '🌱',
          title: l10n.setupBankFilling,
          message: l10n.setupBankFillingBody,
          action: SqButton(
            label: l10n.setupCreateCustomTopic,
            expand: false,
            icon: Icons.auto_awesome_rounded,
            onPressed: onCustom,
          ),
        ),
      );
    }

    // Everything the catalog holds, but none of it in this language: a
    // different problem from an empty bank, and it has a one-tap fix.
    if (playable.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: SqEmptyState(
          icon: '🗣️',
          title: l10n.languageBankEmpty(
            AppLanguage.fromCode(languageCode).nativeLabel,
          ),
          message: l10n.languageBankEmptyHint(
            AppLanguage.fromCode(languageCode).nativeLabel,
          ),
          action: SqButton(
            label: l10n.setupCreateCustomTopic,
            expand: false,
            icon: Icons.auto_awesome_rounded,
            onPressed: onCustom,
          ),
        ),
      );
    }

    final needle = query.trim().toLowerCase();
    bool matches(TopicItem t) =>
        needle.isEmpty ||
        t.name.toLowerCase().contains(needle) ||
        (t.category?.name.toLowerCase().contains(needle) ?? false);

    final filtered = playable.where(matches).toList();
    final filteredFilling = filling.where(matches).toList();
    final groups = groupTopics(filtered);

    return ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.lg,
      ),
      children: [
        Row(
          children: [
            Expanded(
              child: _ActionChip(
                label: l10n.setupSurpriseMe,
                glyph: '🎲',
                tint: AppColors.violet,
                onTap: onRandom,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _ActionChip(
                label: l10n.setupCustomTopic,
                glyph: '✨',
                tint: AppColors.magenta,
                onTap: onCustom,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        // A catalog this size stops being browsable without a filter.
        TextField(
          controller: searchController,
          onChanged: onQuery,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: l10n.setupSearchTopics(playable.length),
            prefixIcon: const Icon(Icons.search_rounded, size: 19),
            isDense: true,
            suffixIcon: needle.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close_rounded, size: 17),
                    onPressed: () {
                      searchController.clear();
                      onQuery('');
                    },
                  ),
          ),
        ),

        if (filtered.isEmpty && filteredFilling.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xl),
            child: SqEmptyState(
              icon: '🔍',
              title: l10n.setupNoTopicMatches(query),
              message: l10n.setupNoTopicMatchesBody,
              action: SqButton(
                label: l10n.setupCreateCustomTopic,
                expand: false,
                icon: Icons.auto_awesome_rounded,
                onPressed: onCustom,
              ),
            ),
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
              const SizedBox(width: 8),
              Expanded(
                child: Divider(
                  color: p.border.withValues(alpha: 0.6),
                  height: 1,
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

        if (filteredFilling.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              const Text('⏳', style: TextStyle(fontSize: 13)),
              const SizedBox(width: 6),
              Text(
                l10n.comingSoon.toUpperCase(),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: p.textFaint,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Divider(
                  color: p.border.withValues(alpha: 0.6),
                  height: 1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            l10n.setupComingSoonBody,
            style: theme.textTheme.bodySmall?.copyWith(color: p.textFaint),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final topic in filteredFilling)
                _Choice(
                  label: '${topic.icon}  ${topic.name}',
                  selected: false,
                  locked: true,
                  // A topic stocked in another language is not "still being
                  // written" — it is one language switch away from playable,
                  // and the chip says so instead of making the player tap to
                  // find out.
                  note: topic.isPlayable
                      ? l10n.setupUnavailableInLanguage
                      : null,
                  onTap: () => onLocked(topic),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _TopicSkeleton extends StatelessWidget {
  const _TopicSkeleton();

  @override
  Widget build(BuildContext context) {
    return const SqShimmer(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.md,
          AppSpacing.lg,
          AppSpacing.lg,
        ),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            SqSkeleton(width: 110, height: 40, radius: 999),
            SqSkeleton(width: 92, height: 40, radius: 999),
            SqSkeleton(width: 128, height: 40, radius: 999),
            SqSkeleton(width: 104, height: 40, radius: 999),
            SqSkeleton(width: 118, height: 40, radius: 999),
            SqSkeleton(width: 96, height: 40, radius: 999),
          ],
        ),
      ),
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
    this.dense = false,
    this.locked = false,
    this.note,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool dense;

  /// A topic whose question bank is still generating — visible so the catalog
  /// looks complete, dimmed so nobody expects to play it yet.
  final bool locked;

  /// Why it is locked, when there is more than one reason it could be.
  final String? note;

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
        padding: EdgeInsets.symmetric(
          horizontal: dense ? 12 : 14,
          vertical: dense ? 8 : 11,
        ),
        decoration: BoxDecoration(
          color: selected
              ? p.accentWash(0.18)
              : (locked ? Colors.transparent : p.surface),
          borderRadius: BorderRadius.circular(AppRadii.pill),
          border: Border.all(
            color: selected
                ? p.accent
                : p.border.withValues(alpha: locked ? 0.5 : 1),
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
              Icon(Icons.check_rounded, size: dense ? 13 : 15, color: p.accent),
              const SizedBox(width: 6),
            ] else if (locked) ...[
              Icon(
                note != null
                    ? Icons.translate_rounded
                    : Icons.hourglass_empty_rounded,
                size: 12,
                color: p.textFaint,
              ),
              const SizedBox(width: 5),
            ],
            Opacity(
              opacity: locked ? 0.55 : 1,
              child: Text(
                note == null ? label : '$label · $note',
                style: (dense
                        ? theme.textTheme.labelMedium
                        : theme.textTheme.bodyMedium)
                    ?.copyWith(
                  color: selected ? p.accent : p.textPrimary,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
