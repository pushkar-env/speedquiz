import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/auth/presentation/auth_controller.dart';
import 'package:speedquiz/features/daily/data/daily_repository.dart';
import 'package:speedquiz/shared/widgets/sq_button.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  Future<void> _openDaily(BuildContext context, WidgetRef ref) async {
    final repo = ref.read(dailyRepositoryProvider);
    try {
      final info = await repo.fetchToday();
      if (!context.mounted) return;
      if (info.isCompleted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              info.bestScore != null
                  ? 'Done for today · score ${info.bestScore}. Come back tomorrow!'
                  : 'Daily challenge complete. Come back tomorrow!',
            ),
          ),
        );
        ref.invalidate(dailyChallengeProvider);
        return;
      }
      final session = await repo.start();
      if (!context.mounted) return;
      ref.invalidate(dailyChallengeProvider);
      context.push(
        '/quiz/play',
        extra: {
          'topicId': session.topicId,
          'topicName': session.topicName,
          'mode': 'daily',
          'difficulty': session.difficulty,
          'session': session,
        },
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Daily challenge unavailable: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final user = auth is AuthAuthenticated ? auth.user : null;
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final dailyAsync = ref.watch(dailyChallengeProvider);

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: dark ? AppColors.backgroundDark.wash : null,
          color: dark ? null : AppColors.backgroundLight,
        ),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.md,
              AppSpacing.lg,
              AppSpacing.xxl,
            ),
            children: [
              Builder(
                builder: (context) {
                  final level = user?.level ?? 1;
                  final xp = user?.xp ?? 0;
                  final threshold = level < 1 ? 500 : level * 500;
                  final progress = threshold <= 0 ? 0.0 : (xp / threshold).clamp(0.0, 1.0);
                  final initial = (user?.username.isNotEmpty ?? false)
                      ? user!.username[0].toUpperCase()
                      : 'S';
                  final displayName = user?.displayName ?? user?.username ?? 'Player';
                  final streak = user?.dailyStreak ?? user?.currentStreak ?? 0;

                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: dark
                          ? AppColors.surfaceDark.withValues(alpha: 0.65)
                          : Colors.white.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: dark
                            ? Colors.white.withValues(alpha: 0.08)
                            : AppColors.borderLight,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: dark ? 0.25 : 0.05),
                          blurRadius: 16,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [AppColors.accent, Color(0xFF00B4D8)],
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.accent.withValues(alpha: 0.35),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Text(
                            initial,
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: const Color(0xFF0D1B2A),
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      displayName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.titleSmall?.copyWith(
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: -0.2,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: AppColors.accent.withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(
                                        color: AppColors.accent.withValues(alpha: 0.3),
                                      ),
                                    ),
                                    child: Text(
                                      'LVL $level',
                                      style: theme.textTheme.labelSmall?.copyWith(
                                        color: AppColors.accent,
                                        fontWeight: FontWeight.w800,
                                        fontSize: 10,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 5),
                              Row(
                                children: [
                                  Expanded(
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(999),
                                      child: LinearProgressIndicator(
                                        value: progress,
                                        minHeight: 4,
                                        backgroundColor: (dark ? Colors.white : Colors.black)
                                            .withValues(alpha: 0.08),
                                        color: AppColors.accent,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '$xp/$threshold XP',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.7),
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                AppColors.warning.withValues(alpha: 0.25),
                                AppColors.warning.withValues(alpha: 0.1),
                              ],
                            ),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: AppColors.warning.withValues(alpha: 0.4),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('🔥', style: TextStyle(fontSize: 13)),
                              const SizedBox(width: 4),
                              Text(
                                '$streak',
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: AppColors.warning,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: AppSpacing.xl),
              Text(
                'SPEEDQUIZ',
                style: theme.textTheme.displaySmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -1.4,
                  height: 1,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Pick a topic. Climb the ranks.',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: dark
                      ? AppColors.textSecondaryDark
                      : AppColors.textSecondaryLight,
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              _PlayHero(onPlay: () => context.push('/quiz/setup')),
              const SizedBox(height: AppSpacing.lg),
              dailyAsync.when(
                loading: () => SqSurface(
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: AppColors.warning.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(AppRadii.sm),
                        ),
                        child: const Text('📅', style: TextStyle(fontSize: 22)),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Daily Challenge',
                              style: theme.textTheme.titleMedium,
                            ),
                            Text(
                              'Loading today’s set…',
                              style: theme.textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                error: (_, _) => SqSurface(
                  onTap: () => ref.invalidate(dailyChallengeProvider),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: AppColors.warning.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(AppRadii.sm),
                        ),
                        child: const Text('📅', style: TextStyle(fontSize: 22)),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Daily Challenge',
                              style: theme.textTheme.titleMedium,
                            ),
                            Text(
                              'Tap to retry',
                              style: theme.textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.refresh_rounded,
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.45),
                      ),
                    ],
                  ),
                ),
                data: (daily) {
                  final subtitle = daily.isCompleted
                      ? (daily.bestScore != null
                          ? 'Completed · ${daily.bestScore} pts'
                          : 'Completed · come back tomorrow')
                      : daily.isInProgress
                          ? 'Resume · ${daily.topicName}'
                          : '${daily.topicName} · ${daily.questionCount} Qs';
                  return SqSurface(
                    onTap: () => _openDaily(context, ref),
                    child: Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: AppColors.warning.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(AppRadii.sm),
                          ),
                          child: Text(
                            daily.topicIcon,
                            style: const TextStyle(fontSize: 22),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                daily.title,
                                style: theme.textTheme.titleMedium,
                              ),
                              Text(subtitle, style: theme.textTheme.bodyMedium),
                            ],
                          ),
                        ),
                        Icon(
                          daily.isCompleted
                              ? Icons.check_circle_outline_rounded
                              : Icons.chevron_right_rounded,
                          color: daily.isCompleted
                              ? AppColors.accent
                              : theme.colorScheme.onSurface.withValues(alpha: 0.45),
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: AppSpacing.xl),
              const SqSectionHeader(
                title: 'Topics',
                subtitle: 'Jump straight into a challenge',
              ),
              const SizedBox(height: AppSpacing.md),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _TopicChip(label: 'Science', icon: '🧠', onTap: () => context.push('/quiz/setup')),
                  _TopicChip(label: 'Astronomy', icon: '🌌', onTap: () => context.push('/quiz/setup')),
                  _TopicChip(label: 'AI', icon: '🤖', onTap: () => context.push('/quiz/setup')),
                  _TopicChip(label: 'Programming', icon: '💻', onTap: () => context.push('/quiz/setup')),
                  _TopicChip(label: 'Gaming', icon: '🎮', onTap: () => context.push('/quiz/setup')),
                  _TopicChip(label: 'Geography', icon: '🌍', onTap: () => context.push('/quiz/setup')),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              SqSurface(
                onTap: () => context.push('/custom-topic'),
                child: Row(
                  children: [
                    const Icon(Icons.add_circle_outline, color: AppColors.accent),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Custom Topic',
                            style: theme.textTheme.titleMedium,
                          ),
                          Text(
                            'Create a quiz about anything',
                            style: theme.textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlayHero extends StatefulWidget {
  const _PlayHero({required this.onPlay});

  final VoidCallback onPlay;

  @override
  State<_PlayHero> createState() => _PlayHeroState();
}

class _PlayHeroState extends State<_PlayHero>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_pulse.value);
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(AppSpacing.lg),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.lg),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.lerp(
                  const Color(0xFF163028),
                  const Color(0xFF1A3A30),
                  t,
                )!,
                const Color(0xFF101822),
              ],
            ),
            border: Border.all(
              color: AppColors.accent.withValues(alpha: 0.22 + t * 0.12),
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.accent.withValues(alpha: 0.08 + t * 0.06),
                blurRadius: 24,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: child,
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'READY?',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  letterSpacing: 1.4,
                  color: AppColors.accent,
                ),
          ),
          const SizedBox(height: 6),
          Text(
            'Start a run',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimaryDark,
                ),
          ),
          const SizedBox(height: 4),
          Text(
            'Timed questions. Server-side scoring. Pure focus.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.textSecondaryDark,
                ),
          ),
          const SizedBox(height: AppSpacing.md),
          SqButton(label: 'PLAY', onPressed: widget.onPlay),
        ],
      ),
    );
  }
}

class _TopicChip extends StatelessWidget {
  const _TopicChip({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final String icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: dark ? AppColors.surfaceDark : AppColors.surfaceLight,
      borderRadius: BorderRadius.circular(AppRadii.sm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.sm),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.sm),
            border: Border.all(
              color: dark ? AppColors.borderDark : AppColors.borderLight,
            ),
          ),
          child: Text('$icon  $label'),
        ),
      ),
    );
  }
}
