import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:quizverse/core/theme/app_theme.dart';
import 'package:quizverse/features/auth/presentation/auth_controller.dart';
import 'package:quizverse/shared/widgets/qv_button.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final user = auth is AuthAuthenticated ? auth.user : null;
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;

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
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [
                          AppColors.accent.withValues(alpha: 0.35),
                          AppColors.accent.withValues(alpha: 0.08),
                        ],
                      ),
                      border: Border.all(
                        color: AppColors.accent.withValues(alpha: 0.35),
                      ),
                    ),
                    child: Text(
                      (user?.username.isNotEmpty ?? false)
                          ? user!.username[0].toUpperCase()
                          : 'Q',
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: AppColors.accent,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          user?.displayName ?? user?.username ?? 'Player',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        QvXpBar(
                          level: user?.level ?? 1,
                          xp: user?.xp ?? 0,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.warning.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(AppRadii.pill),
                      border: Border.all(
                        color: AppColors.warning.withValues(alpha: 0.28),
                      ),
                    ),
                    child: Text(
                      '🔥 ${user?.currentStreak ?? 0}',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: AppColors.warning,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xl),
              Text(
                'QUIZVERSE',
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
              QvSurface(
                onTap: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Daily Challenge arrives in Phase 5'),
                    ),
                  );
                },
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
                            'Same questions for everyone',
                            style: theme.textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.lock_outline_rounded,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.45),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              const QvSectionHeader(
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
              QvSurface(
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
          QvButton(label: 'PLAY', onPressed: widget.onPlay),
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
