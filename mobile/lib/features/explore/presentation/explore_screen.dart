import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/network/api_errors.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/theme/app_motion.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/shell/presentation/main_shell.dart';
import 'package:speedquiz/features/studio/data/custom_quiz_repository.dart';
import 'package:speedquiz/features/studio/domain/custom_quiz_models.dart';
import 'package:speedquiz/features/studio/presentation/widgets/quiz_widgets.dart';
import 'package:speedquiz/features/topics/data/topics_repository.dart';
import 'package:speedquiz/features/topics/presentation/topic_tile.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

class ExploreScreen extends ConsumerStatefulWidget {
  const ExploreScreen({super.key});

  @override
  ConsumerState<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends ConsumerState<ExploreScreen> {
  final _searchController = TextEditingController();

  String _query = '';

  /// null = "All categories".
  String? _categorySlug;

  bool get _filtering => _query.isNotEmpty || _categorySlug != null;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<TopicItem> _visible(List<TopicItem> all) {
    final needle = _query.toLowerCase();
    return all.where((topic) {
      if (_categorySlug != null && topic.group.slug != _categorySlug) {
        return false;
      }
      if (needle.isEmpty) return true;
      return topic.name.toLowerCase().contains(needle) ||
          (topic.description?.toLowerCase().contains(needle) ?? false);
    }).toList();
  }

  /// Custom quizzes worth showing next to the catalog.
  ///
  /// Fed by the viewer's own library, which is the only safe source: these
  /// have no public tier, so the list must never be anything but "quizzes I
  /// wrote" plus "quizzes shared with me". Reusing that provider makes the
  /// entitlement check structural rather than something this screen has to
  /// remember to repeat.
  List<CustomQuiz> _customQuizzes(CustomQuizLibrary library) {
    // A category filter is asking the catalog a question these cannot answer —
    // they have no category — so the section steps aside rather than ignoring
    // the filter the player just set.
    if (_categorySlug != null) return const [];

    final needle = _query.toLowerCase();
    bool matches(CustomQuiz quiz) {
      if (needle.isEmpty) return true;
      return quiz.title.toLowerCase().contains(needle) ||
          (quiz.description?.toLowerCase().contains(needle) ?? false);
    }

    return [
      // Drafts stay in: the author is the only one who sees them, the card
      // badges them, and tapping through is how they get published. Archived
      // and under-review quizzes do not — neither is actionable here, and the
      // studio is where you manage those.
      ...library.mine.where(
        (q) => q.status == QuizStatus.published || q.status == QuizStatus.draft,
      ),
      ...library.shared,
    ].where(matches).toList(growable: false);
  }

  void _openQuiz(CustomQuiz quiz) {
    Haptics.tap();
    context.push(Routes.quizDetailPath(quiz.id));
  }

  /// The custom-quiz section, or nothing at all.
  ///
  /// Degrades silently while the library loads or if it fails: this is a
  /// secondary section on a browse screen, and an error block here would sit
  /// on top of a catalog that is working perfectly well. The studio tab is
  /// where a failure to load your quizzes is worth reporting.
  List<Widget> _customQuizSlivers(SqStrings l10n) {
    final library = ref.watch(customQuizLibraryProvider).valueOrNull;
    if (library == null) return const [];

    final quizzes = _customQuizzes(library);
    if (quizzes.isEmpty) return const [];

    // Capped: this is a pointer into the studio, not a second copy of it.
    const shown = 4;
    final visible = quizzes.take(shown).toList(growable: false);

    return [
      _SectionLabel(
        title: l10n.exploreCustomQuizzes,
        glyph: '✍️',
        count: quizzes.length,
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: Column(
            children: [
              for (final quiz in visible)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: QuizCard(quiz: quiz, onTap: () => _openQuiz(quiz)),
                ),
              if (quizzes.length > shown)
                SqButton(
                  label: l10n.studioTitle,
                  icon: Icons.edit_note_rounded,
                  variant: SqButtonVariant.ghost,
                  height: 46,
                  onPressed: () => context.push(Routes.studio),
                ),
            ],
          ),
        ),
      ),
    ];
  }

  void _open(TopicItem topic) {
    context.push(
      Routes.quizSetup,
      extra: {'topicId': topic.id, 'topicName': topic.name},
    );
  }

  void _surpriseMe() {
    final topic = ref.read(randomTopicProvider);
    if (topic == null) {
      SqToast.warning(context, context.l10n.homeNoTopicReady);
      return;
    }
    Haptics.success();
    _open(topic);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final l10n = context.l10n;
    final topics = ref.watch(topicsProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SqBackdrop(
        intensity: 0.5,
        child: SafeArea(
          bottom: false,
          child: topics.when(
            loading: () => const _ExploreSkeleton(),
            error: (error, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: SqErrorState(
                  title: l10n.exploreCouldNotLoad,
                  message: localizedApiErrorMessage(
                    context,
                    error,
                    fallback: l10n.exploreCheckConnection,
                  ),
                  onRetry: () => ref.invalidate(topicsProvider),
                ),
              ),
            ),
            data: (all) {
              final visible = _visible(all);
              final ready = visible.where((t) => t.isPlayable).toList();
              final soon = visible.where((t) => !t.isPlayable).toList();
              final groups = groupTopics(ready);
              final trending = ready.where((t) => t.isTrending).toList();
              final categories = groupTopics(
                all,
              ).map((g) => g.category).toList();

              return RefreshIndicator(
                onRefresh: () async {
                  ref
                    ..invalidate(topicsProvider)
                    ..invalidate(customQuizLibraryProvider);
                  await ref.read(topicsProvider.future);
                },
                color: p.accent,
                backgroundColor: p.surfaceElevated,
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(
                          AppSpacing.lg,
                          AppSpacing.md,
                          AppSpacing.lg,
                          AppSpacing.sm,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    l10n.exploreTitle,
                                    style: theme.textTheme.displaySmall,
                                  ),
                                ),
                                _SurpriseButton(onTap: _surpriseMe),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              l10n.exploreReadyToPlay(
                                all.where((t) => t.isPlayable).length,
                              ),
                              style: theme.textTheme.bodyMedium,
                            ),
                            const SizedBox(height: AppSpacing.md),
                            _SearchField(
                              controller: _searchController,
                              onChanged: (value) =>
                                  setState(() => _query = value.trim()),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Exam mode is a different kind of thing from a topic, so
                    // it gets its own entry above the catalog rather than a
                    // card inside it. Hidden while searching: a query is a
                    // search of the topic catalog, and this is not in it.
                    if (!_filtering && _query.isEmpty)
                      const SliverToBoxAdapter(child: _ExamModeCard()),
                    SliverToBoxAdapter(
                      child: _CategoryRail(
                        categories: categories,
                        selected: _categorySlug,
                        onSelect: (slug) {
                          Haptics.tap();
                          setState(() => _categorySlug = slug);
                        },
                      ),
                    ),
                    // Above the catalog, and outside the "no topics match"
                    // branch below: a search that finds nothing curated should
                    // still surface the quiz of yours that does match.
                    ..._customQuizSlivers(l10n),
                    if (visible.isEmpty)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: SqEmptyState(
                          icon: '🔍',
                          title: l10n.exploreNothingHere,
                          message: _query.isEmpty
                              ? l10n.exploreCategoryEmpty
                              : l10n.exploreNoMatch(_query),
                          action: SqButton(
                            label: l10n.setupCreateCustomTopic,
                            expand: false,
                            icon: Icons.auto_awesome_rounded,
                            onPressed: () => context.push(Routes.customTopic),
                          ),
                        ),
                      )
                    else ...[
                      // Trending only makes sense on the unfiltered view;
                      // inside a category it just repeats the list below.
                      if (!_filtering && trending.isNotEmpty) ...[
                        _SectionLabel(
                          title: l10n.exploreTrendingNow,
                          glyph: '🔥',
                        ),
                        SliverToBoxAdapter(
                          child: _TrendingRail(topics: trending, onTap: _open),
                        ),
                      ],
                      for (final group in groups) ...[
                        _SectionLabel(
                          title: group.category.name,
                          glyph: group.category.icon,
                          count: group.topics.length,
                        ),
                        _TopicGrid(items: group.topics, onTap: _open),
                      ],
                      if (soon.isNotEmpty) ...[
                        _SectionLabel(
                          title: l10n.exploreBankFilling,
                          glyph: '⏳',
                        ),
                        _TopicGrid(items: soon, onTap: _open, muted: true),
                      ],
                    ],
                    SliverToBoxAdapter(
                      child: SizedBox(
                        height: MainShell.contentBottomPadding(context),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Dice button that drops the player into a random topic.
/// Entry point into exam mode.
///
/// Reads deliberately calmer than the topic cards around it — a three-hour JEE
/// paper is a different commitment from a fifteen-second Survival round, and
/// the card should set that expectation before the tap, not after.
class _ExamModeCard extends StatelessWidget {
  const _ExamModeCard();

  @override
  Widget build(BuildContext context) {
    final p = context.sq;
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.xs,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      child: SqSurface(
        onTap: () {
          Haptics.tap();
          context.push(Routes.exams);
        },
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: p.accentWash(),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.school_outlined, color: p.accent, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Mock Tests', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text(
                    'Full-length past papers, timed and scored',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: p.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: p.textFaint),
          ],
        ),
      ),
    );
  }
}

class _SurpriseButton extends StatelessWidget {
  const _SurpriseButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SqPressable(
      onTap: onTap,
      pressedScale: 0.9,
      semanticLabel: context.l10n.explorePlayRandom,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              AppColors.violet.withValues(alpha: 0.3),
              AppColors.magenta.withValues(alpha: 0.18),
            ],
          ),
          borderRadius: BorderRadius.circular(AppRadii.pill),
          border: Border.all(color: AppColors.violet.withValues(alpha: 0.45)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('🎲', style: TextStyle(fontSize: 15)),
            const SizedBox(width: 6),
            Text(
              context.l10n.exploreRandom,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.sq.isDark
                    ? AppColors.violet
                    : const Color(0xFF5B4BD8),
                fontWeight: FontWeight.w800,
                letterSpacing: 0.6,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryRail extends StatelessWidget {
  const _CategoryRail({
    required this.categories,
    required this.selected,
    required this.onSelect,
  });

  final List<TopicCategory> categories;
  final String? selected;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    if (categories.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      height: 44 + context.scriptExtraHeight,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        children: [
          _CategoryChip(
            label: context.l10n.all,
            glyph: '🗂',
            selected: selected == null,
            onTap: () => onSelect(null),
          ),
          for (final category in categories) ...[
            const SizedBox(width: 8),
            _CategoryChip(
              label: category.name,
              glyph: category.icon,
              selected: selected == category.slug,
              onTap: () =>
                  onSelect(selected == category.slug ? null : category.slug),
            ),
          ],
        ],
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.glyph,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String glyph;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return SqPressable(
      onTap: onTap,
      haptic: false,
      pressedScale: 0.93,
      child: AnimatedContainer(
        duration: AppMotion.fast,
        curve: AppMotion.standard,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? p.accentWash(0.18) : p.surface,
          borderRadius: BorderRadius.circular(AppRadii.pill),
          border: Border.all(
            color: selected ? p.accent : p.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(glyph, style: const TextStyle(fontSize: 13)),
            const SizedBox(width: 6),
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: selected ? p.accent : p.textSecondary,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.sq;
    return TextField(
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      style: Theme.of(context).textTheme.bodyLarge,
      decoration: InputDecoration(
        hintText: context.l10n.exploreSearchHint,
        prefixIcon: Icon(Icons.search_rounded, color: p.textFaint, size: 20),
        suffixIcon: ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, value, _) {
            if (value.text.isEmpty) return const SizedBox.shrink();
            return IconButton(
              icon: const Icon(Icons.close_rounded, size: 18),
              onPressed: () {
                controller.clear();
                onChanged('');
              },
            );
          },
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.title, required this.glyph, this.count});

  final String title;
  final String glyph;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.sm,
        ),
        child: Row(
          children: [
            Text(glyph, style: const TextStyle(fontSize: 16)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleLarge,
              ),
            ),
            if (count != null) SqBadge(label: '$count', dense: true),
          ],
        ),
      ),
    );
  }
}

/// Wide cards for trending topics — they earn more visual weight.
class _TrendingRail extends StatelessWidget {
  const _TrendingRail({required this.topics, required this.onTap});

  final List<TopicItem> topics;
  final ValueChanged<TopicItem> onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 128 + context.scriptExtraHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        itemCount: topics.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, index) => SqStagger(
          index: index,
          offset: 0,
          child: TopicFeatureCard(
            topic: topics[index],
            onTap: () => onTap(topics[index]),
          ),
        ),
      ),
    );
  }
}

class _TopicGrid extends StatelessWidget {
  const _TopicGrid({
    required this.items,
    required this.onTap,
    this.muted = false,
  });

  final List<TopicItem> items;
  final ValueChanged<TopicItem> onTap;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 220,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          // Taller tiles in Devanagari: the same two lines of text occupy a
          // taller line box, and a fixed ratio that fits English clips it.
          childAspectRatio: context.appLanguage.script == SqScript.devanagari
              ? 1.06
              : 1.22,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) => SqStagger(
            index: index,
            child: TopicTile(
              topic: items[index],
              muted: muted,
              onTap: muted ? null : () => onTap(items[index]),
            ),
          ),
          childCount: items.length,
        ),
      ),
    );
  }
}

class _ExploreSkeleton extends StatelessWidget {
  const _ExploreSkeleton();

  @override
  Widget build(BuildContext context) {
    final p = context.sq;

    return SqShimmer(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.md,
          AppSpacing.lg,
          AppSpacing.lg,
        ),
        physics: const NeverScrollableScrollPhysics(),
        children: [
          const SqSkeleton(width: 160, height: 34),
          const SizedBox(height: AppSpacing.md),
          const SqSkeleton(height: 48, radius: AppRadii.md),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: const [
              SqSkeleton(width: 70, height: 40, radius: AppRadii.pill),
              SizedBox(width: 8),
              SqSkeleton(width: 96, height: 40, radius: AppRadii.pill),
              SizedBox(width: 8),
              SqSkeleton(width: 84, height: 40, radius: AppRadii.pill),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          const SqSkeleton(width: 130, height: 20),
          const SizedBox(height: AppSpacing.md),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 220,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.22,
            ),
            itemCount: 4,
            itemBuilder: (context, index) => Container(
              decoration: BoxDecoration(
                color: p.surface,
                borderRadius: BorderRadius.circular(AppRadii.md),
                border: Border.all(color: p.border),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
