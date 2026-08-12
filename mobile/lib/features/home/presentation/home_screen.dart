import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
import 'package:speedquiz/core/network/api_errors.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/theme/app_motion.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/auth/domain/auth_models.dart';
import 'package:speedquiz/features/auth/presentation/auth_controller.dart';
import 'package:speedquiz/features/daily/data/daily_repository.dart';
import 'package:speedquiz/features/daily/domain/daily_models.dart';
import 'package:speedquiz/features/shell/presentation/main_shell.dart';
import 'package:speedquiz/features/topics/data/topics_repository.dart';
import 'package:speedquiz/features/topics/presentation/topic_tile.dart';
import 'package:speedquiz/features/welcome/data/welcome_store.dart';
import 'package:speedquiz/features/welcome/domain/welcome_cue.dart';
import 'package:speedquiz/features/welcome/presentation/welcome_sheet.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _startingDaily = false;

  /// Set only for a player who relaunched the app — they get an inline hello
  /// rather than a sheet in the face.
  WelcomeCue? _returningCue;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _greet());
  }

  /// Consume the greeting raised when the session started, if there is one.
  Future<void> _greet() async {
    final cue = ref.read(authControllerProvider.notifier).takeWelcomeCue();
    if (cue == null || !mounted) return;
    final store = ref.read(welcomeStoreProvider);

    if (!cue.deservesSheet) {
      // A relaunch is not an event: at most one quiet hello a day.
      if (!await store.shouldGreetToday()) return;
      await store.markGreeted();
      if (mounted) setState(() => _returningCue = cue);
      return;
    }

    await store.markGreeted();

    // Give the daily a moment to land so the sheet can name what is waiting,
    // but never hold the greeting hostage to the network.
    DailyChallengeInfo? daily;
    try {
      daily = await ref
          .read(dailyChallengeProvider.future)
          .timeout(const Duration(milliseconds: 1200));
    } catch (_) {
      daily = null;
    }

    if (!mounted) return;
    await showWelcomeSheet(
      context,
      cue: cue,
      daily: daily,
      onPlay: () => context.push(Routes.quizSetup),
    );
  }

  Future<void> _refresh() async {
    ref.invalidate(dailyChallengeProvider);
    ref.invalidate(topicsProvider);
    await ref.read(authControllerProvider.notifier).refreshMe();
    await ref.read(topicsProvider.future);
  }

  Future<void> _openDaily() async {
    if (_startingDaily) return;
    setState(() => _startingDaily = true);
    final repo = ref.read(dailyRepositoryProvider);

    try {
      final info = await repo.fetchToday();
      if (!mounted) return;

      if (info.isCompleted) {
        ref.invalidate(dailyChallengeProvider);
        setState(() => _startingDaily = false);
        await showSqInfo(
          context,
          title: 'Today is done',
          message: info.bestScore != null
              ? 'You scored ${formatScore(info.bestScore!)} on today’s '
                    'challenge. A fresh set unlocks tomorrow.'
              : 'You already cleared today’s challenge. '
                    'A fresh set unlocks tomorrow.',
          glyph: '✅',
          tone: SqDialogTone.success,
          actionLabel: 'NICE',
        );
        return;
      }

      final session = await repo.start();
      if (!mounted) return;
      ref.invalidate(dailyChallengeProvider);
      setState(() => _startingDaily = false);

      context.push(
        Routes.quizPlay,
        extra: {
          'topicId': session.topicId,
          'topicName': session.topicName,
          'mode': 'daily',
          'difficulty': session.difficulty,
          'session': session,
        },
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _startingDaily = false);
      SqToast.error(
        context,
        apiErrorMessage(error, fallback: 'Daily challenge is unavailable.'),
        actionLabel: 'RETRY',
        onAction: _openDaily,
      );
    }
  }

  void _openTopic(TopicItem topic) {
    context.push(
      Routes.quizSetup,
      extra: {'topicId': topic.id, 'topicName': topic.name},
    );
  }

  /// Zero-decision path into a run: random topic, adaptive difficulty, go.
  void _surpriseMe() {
    final topic = ref.read(randomTopicProvider);
    if (topic == null) {
      SqToast.warning(context, 'No topic has questions ready yet.');
      return;
    }
    Haptics.success();
    context.push(
      Routes.quizPlay,
      extra: {
        'topicId': topic.id,
        'topicName': topic.name,
        'mode': 'casual',
        'difficulty': 'medium',
        'adaptive': true,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final user = ref.watch(currentUserProvider);
    final dailyAsync = ref.watch(dailyChallengeProvider);
    final topicsAsync = ref.watch(topicsProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SqBackdrop(
        intensity: 0.7,
        child: SafeArea(
          bottom: false,
          child: RefreshIndicator(
            onRefresh: _refresh,
            color: p.accent,
            backgroundColor: p.surfaceElevated,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.md,
                AppSpacing.lg,
                MainShell.contentBottomPadding(context),
              ),
              children: [
                SqStagger(
                  child: _PlayerBar(
                    user: user,
                    onTap: () => context.go(Routes.profile),
                  ),
                ),
                // Only present for a relaunch, and only once a day.
                AnimatedSize(
                  duration: AppMotion.normal,
                  curve: AppMotion.enter,
                  alignment: Alignment.topCenter,
                  child: _returningCue == null
                      ? const SizedBox(width: double.infinity)
                      : Padding(
                          padding: const EdgeInsets.only(top: AppSpacing.md),
                          child: WelcomeBanner(
                            name: _returningCue!.user.name,
                            onDismiss: () =>
                                setState(() => _returningCue = null),
                          ),
                        ),
                ),
                const SizedBox(height: AppSpacing.xl),
                SqStagger(
                  index: 1,
                  child: Text(
                    _greeting(user?.name),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      letterSpacing: 1.4,
                      fontWeight: FontWeight.w700,
                      color: p.accent,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                SqStagger(
                  index: 2,
                  child: Text(
                    'Pick a topic.\nClimb the ranks.',
                    style: theme.textTheme.displaySmall?.copyWith(height: 1.06),
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                SqStagger(
                  index: 3,
                  child: _PlayHero(
                    onPlay: () => context.push(Routes.quizSetup),
                    onSurprise: _surpriseMe,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                SqStagger(
                  index: 4,
                  child: _DailyCard(
                    async: dailyAsync,
                    busy: _startingDaily,
                    onTap: _openDaily,
                    onRetry: () => ref.invalidate(dailyChallengeProvider),
                  ),
                ),
                const SizedBox(height: AppSpacing.xl),
                SqStagger(
                  index: 5,
                  child: SqSectionHeader(
                    title: 'Jump back in',
                    subtitle: 'Topics with the deepest question banks',
                    actionLabel: 'ALL',
                    onAction: () => context.go(Routes.explore),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                SqStagger(
                  index: 6,
                  child: _TopicShortcuts(
                    async: topicsAsync,
                    onTap: _openTopic,
                    onRetry: () => ref.invalidate(topicsProvider),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                SqStagger(
                  index: 7,
                  child: _CustomTopicCard(
                    onTap: () => context.push(Routes.customTopic),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Time-of-day greeting, addressed to the player when we know their name.
  static String _greeting(String? name) {
    final hour = DateTime.now().hour;
    final part = hour < 5
        ? 'BURNING THE MIDNIGHT OIL'
        : hour < 12
            ? 'GOOD MORNING'
            : hour < 17
                ? 'GOOD AFTERNOON'
                : 'GOOD EVENING';
    if (name == null || name.trim().isEmpty) return part;
    return '$part, ${name.trim().toUpperCase()}';
  }
}

/// Compact player strip: avatar, name, level progress and streak.
class _PlayerBar extends StatelessWidget {
  const _PlayerBar({required this.user, required this.onTap});

  final AuthUser? user;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    final level = user?.level ?? 1;
    final xp = user?.xp ?? 0;
    final threshold = xpThresholdForLevel(level);
    final progress = threshold <= 0 ? 0.0 : (xp / threshold).clamp(0.0, 1.0);
    final displayName = user?.displayName ?? user?.username ?? 'Player';
    final streak = user?.dailyStreak ?? user?.currentStreak ?? 0;
    final isPremium = user?.isPremium ?? false;

    return SqPressable(
      onTap: onTap,
      pressedScale: 0.985,
      semanticLabel: 'Open your profile',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: p.surface.withValues(alpha: p.isDark ? 0.6 : 0.9),
          borderRadius: BorderRadius.circular(AppRadii.xl),
          border: Border.all(color: p.border),
          boxShadow: AppShadows.soft(p),
        ),
        child: Row(
          children: [
            SqAvatar(
              name: displayName,
              seed: user?.id,
              size: 40,
              premium: isPremium,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      const SizedBox(width: 6),
                      SqBadge(label: 'LVL $level', dense: true),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: SqProgressTrack(value: progress, height: 4),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '$xp/$threshold',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: p.textFaint,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            _StreakPill(streak: streak),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded, size: 18, color: p.textFaint),
          ],
        ),
      ),
    );
  }
}

class _StreakPill extends StatelessWidget {
  const _StreakPill({required this.streak});

  final int streak;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = streak > 0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        gradient: active
            ? LinearGradient(
                colors: [
                  AppColors.gold.withValues(alpha: 0.28),
                  AppColors.warning.withValues(alpha: 0.12),
                ],
              )
            : null,
        color: active ? null : theme.sq.border.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(AppRadii.pill),
        border: Border.all(
          color: active
              ? AppColors.gold.withValues(alpha: 0.45)
              : theme.sq.border,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(active ? '🔥' : '💤', style: const TextStyle(fontSize: 13)),
          const SizedBox(width: 5),
          Text(
            '$streak',
            style: theme.textTheme.labelMedium?.copyWith(
              color: active ? AppColors.gold : theme.sq.textFaint,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

/// The primary call to action — a breathing gradient panel.
class _PlayHero extends StatefulWidget {
  const _PlayHero({required this.onPlay, required this.onSurprise});

  final VoidCallback onPlay;
  final VoidCallback onSurprise;

  @override
  State<_PlayHero> createState() => _PlayHeroState();
}

class _PlayHeroState extends State<_PlayHero>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _pulse.stop();
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return SqGlowBorder(
      radius: AppRadii.lg,
      glow: 0.26,
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _pulse,
          builder: (context, child) {
            final t = Curves.easeInOut.transform(_pulse.value);
            return Container(
              padding: const EdgeInsets.all(AppSpacing.lg),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadii.lg),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: p.isDark
                      ? [
                          Color.lerp(
                            const Color(0xFF14332B),
                            const Color(0xFF1B4438),
                            t,
                          )!,
                          const Color(0xFF101822),
                        ]
                      : [
                          Color.lerp(
                            const Color(0xFFE9FBF4),
                            const Color(0xFFDDF7EC),
                            t,
                          )!,
                          Colors.white,
                        ],
                ),
                boxShadow: AppShadows.glow(
                  AppColors.accent,
                  strength: 0.10 + t * 0.07,
                ),
              ),
              child: child,
            );
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const SqBreathe(
                    child: SqBadge(
                      label: 'READY',
                      icon: Icons.bolt_rounded,
                      dense: true,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    'SERVER-SCORED',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: p.textFaint,
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Text('Start a run', style: theme.textTheme.headlineMedium),
              const SizedBox(height: 4),
              Text(
                'Timed questions, speed bonuses and streak multipliers. '
                'Five modes to pick from.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: SqButton(
                      label: 'PLAY',
                      icon: Icons.play_arrow_rounded,
                      onPressed: widget.onPlay,
                    ),
                  ),
                  const SizedBox(width: 10),
                  // One tap, no decisions — random topic, adaptive difficulty.
                  Expanded(
                    flex: 2,
                    child: SqButton(
                      label: 'SURPRISE',
                      variant: SqButtonVariant.ghost,
                      onPressed: widget.onSurprise,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DailyCard extends StatelessWidget {
  const _DailyCard({
    required this.async,
    required this.busy,
    required this.onTap,
    required this.onRetry,
  });

  final AsyncValue<DailyChallengeInfo> async;
  final bool busy;
  final VoidCallback onTap;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return async.when(
      loading: () => const SqShimmer(child: SqSkeletonCard()),
      error: (_, _) => SqSurface(
        onTap: onRetry,
        child: Row(
          children: [
            _Glyph(glyph: '📅', tint: AppColors.warning),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Daily Challenge', style: theme.textTheme.titleMedium),
                  Text('Tap to retry', style: theme.textTheme.bodyMedium),
                ],
              ),
            ),
            Icon(Icons.refresh_rounded, color: p.textFaint),
          ],
        ),
      ),
      data: (daily) {
        final done = daily.isCompleted;
        final subtitle = done
            ? (daily.bestScore != null
                  ? 'Cleared · ${formatScore(daily.bestScore!)} pts'
                  : 'Cleared · back tomorrow')
            : daily.isInProgress
            ? 'Resume · ${daily.topicName}'
            : '${daily.topicName} · ${daily.questionCount} questions';

        return SqSurface(
          onTap: busy ? null : onTap,
          highlighted: !done,
          // Only while it is still waiting to be played.
          glow: !done,
          accent: done ? AppColors.success : AppColors.warning,
          child: Row(
            children: [
              _Glyph(
                glyph: daily.topicIcon,
                tint: done ? AppColors.success : AppColors.warning,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            daily.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium,
                          ),
                        ),
                        if (!done) ...[
                          const SizedBox(width: 8),
                          const SqBadge(
                            label: 'TODAY',
                            color: AppColors.warning,
                            dense: true,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (busy)
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: p.accent,
                  ),
                )
              else
                Icon(
                  done
                      ? Icons.check_circle_rounded
                      : Icons.chevron_right_rounded,
                  color: done ? AppColors.success : p.textFaint,
                ),
            ],
          ),
        );
      },
    );
  }
}

class _Glyph extends StatelessWidget {
  const _Glyph({required this.glyph, required this.tint});

  final String glyph;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 46,
      height: 46,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadii.sm),
        border: Border.all(color: tint.withValues(alpha: 0.25)),
      ),
      child: Text(glyph, style: const TextStyle(fontSize: 22)),
    );
  }
}

/// Horizontal rail of real, playable topics — tapping one carries the topic
/// straight through to setup.
class _TopicShortcuts extends StatelessWidget {
  const _TopicShortcuts({
    required this.async,
    required this.onTap,
    required this.onRetry,
  });

  final AsyncValue<List<TopicItem>> async;
  final ValueChanged<TopicItem> onTap;
  final VoidCallback onRetry;

  static const _railHeight = 128.0;

  @override
  Widget build(BuildContext context) {
    return async.when(
      loading: () => SizedBox(
        height: _railHeight,
        child: SqShimmer(
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: 4,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (_, _) => const SqSkeleton(
              width: 172,
              height: _railHeight,
              radius: AppRadii.md,
            ),
          ),
        ),
      ),
      error: (error, _) => SqErrorState(
        title: 'Topics unavailable',
        message: apiErrorMessage(error, fallback: 'Could not load topics.'),
        onRetry: onRetry,
      ),
      data: (all) {
        final playable = all.where((t) => t.isPlayable).take(8).toList();
        if (playable.isEmpty) {
          return SqSurface(
            child: Text(
              'The question bank is still filling up. Check back shortly.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          );
        }

        return SizedBox(
          height: _railHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            padding: EdgeInsets.zero,
            itemCount: playable.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, index) => SqStagger(
              index: index,
              offset: 0,
              child: TopicFeatureCard(
                topic: playable[index],
                onTap: () => onTap(playable[index]),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CustomTopicCard extends StatelessWidget {
  const _CustomTopicCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return SqSurface(
      onTap: onTap,
      gradient: LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [
          AppColors.violet.withValues(alpha: p.isDark ? 0.16 : 0.10),
          p.surface,
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.violet.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(AppRadii.sm),
              border: Border.all(
                color: AppColors.violet.withValues(alpha: 0.3),
              ),
            ),
            child: const Icon(
              Icons.auto_awesome_rounded,
              color: AppColors.violet,
              size: 22,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Custom topic', style: theme.textTheme.titleMedium),
                const SizedBox(height: 2),
                Text(
                  'Describe anything and the AI builds a quiz for it',
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, color: p.textFaint),
        ],
      ),
    );
  }
}
