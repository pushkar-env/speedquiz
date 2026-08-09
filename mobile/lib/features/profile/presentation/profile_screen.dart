import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:quizverse/core/theme/app_theme.dart';
import 'package:quizverse/core/theme/theme_mode_provider.dart';
import 'package:quizverse/features/auth/presentation/auth_controller.dart';
import 'package:quizverse/shared/widgets/qv_button.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final themeMode = ref.watch(themeModeProvider);
    final user = auth is AuthAuthenticated ? auth.user : null;
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            Text(
              'Profile',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppSpacing.lg),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadii.lg),
                gradient: dark
                    ? const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFF163028), Color(0xFF101822)],
                      )
                    : null,
                color: dark ? null : AppColors.surfaceLight,
                border: Border.all(
                  color: dark
                      ? AppColors.accent.withValues(alpha: 0.22)
                      : AppColors.borderLight,
                ),
              ),
              child: Column(
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.accent.withValues(alpha: 0.16),
                      border: Border.all(
                        color: AppColors.accent.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Text(
                      (user?.username.isNotEmpty ?? false)
                          ? user!.username[0].toUpperCase()
                          : 'Q',
                      style: theme.textTheme.headlineMedium?.copyWith(
                        color: AppColors.accent,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    user?.username ?? 'Guest',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: dark ? AppColors.textPrimaryDark : null,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    user?.isGuest == true
                        ? 'Guest · progress saved & upgradable'
                        : (user?.email ?? ''),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: dark ? AppColors.textSecondaryDark : null,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  QvXpBar(level: user?.level ?? 1, xp: user?.xp ?? 0),
                  const SizedBox(height: AppSpacing.md),
                  Row(
                    children: [
                      Expanded(
                        child: _Metric(
                          label: 'Coins',
                          value: '${user?.coins ?? 0}',
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _Metric(
                          label: 'Streak',
                          value: '${user?.currentStreak ?? 0}',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            Text('Appearance', style: theme.textTheme.titleLarge),
            const SizedBox(height: AppSpacing.sm),
            SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                ButtonSegment(value: ThemeMode.system, label: Text('System')),
              ],
              selected: {themeMode},
              onSelectionChanged: (value) {
                ref.read(themeModeProvider.notifier).setMode(value.first);
              },
            ),
            const SizedBox(height: AppSpacing.xl),
            QvSurface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Achievements', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text(
                    'Unlock trophies as you climb — coming in Phase 5.',
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppRadii.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 2),
          Text(
            value,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
          ),
        ],
      ),
    );
  }
}
