import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:quizverse/core/theme/app_theme.dart';
import 'package:quizverse/core/theme/theme_mode_provider.dart';
import 'package:quizverse/features/achievements/data/achievements_repository.dart';
import 'package:quizverse/features/achievements/domain/achievement_models.dart';
import 'package:quizverse/features/auth/presentation/auth_controller.dart';
import 'package:quizverse/features/entitlements/data/entitlements_repository.dart';
import 'package:quizverse/features/entitlements/presentation/premium_paywall_sheet.dart';
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
    final achievementsAsync = ref.watch(achievementsProvider);
    final entitlementsAsync = ref.watch(entitlementsProvider);
    final dailyStreak = user?.dailyStreak ?? user?.currentStreak ?? 0;
    final isPremium =
        entitlementsAsync.valueOrNull?.isPremium ?? user?.isPremium ?? false;

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
                  const SizedBox(height: 8),
                  _PlanBadge(isPremium: isPremium),
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
                          label: 'Daily streak',
                          value: '$dailyStreak',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (!isPremium) ...[
              const SizedBox(height: AppSpacing.lg),
              QvSurface(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Upgrade',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Unlock unlimited unique questions and custom topics when caps go live.',
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    QvButton(
                      label: 'VIEW PREMIUM',
                      onPressed: () => showPremiumPaywall(context),
                    ),
                  ],
                ),
              ),
            ],
            entitlementsAsync.when(
              data: (ent) {
                if (!ent.devToggleAllowed) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.lg),
                  child: QvSurface(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Dev entitlements',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          ent.enforceCaps
                              ? 'Caps ON · free limit ${ent.uniquePerTopicLimit ?? 30}/topic'
                              : 'Caps OFF · free unlimited (flag ready)',
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            isPremium ? 'Premium enabled' : 'Enable Premium',
                          ),
                          value: isPremium,
                          onChanged: (enabled) async {
                            try {
                              final updated = await ref
                                  .read(entitlementsRepositoryProvider)
                                  .setDevPremium(enabled: enabled);
                              ref.invalidate(entitlementsProvider);
                              ref
                                  .read(authControllerProvider.notifier)
                                  .applyProgress(isPremium: updated.isPremium);
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      updated.isPremium
                                          ? 'Premium enabled (dev)'
                                          : 'Back to Free (dev)',
                                    ),
                                  ),
                                );
                              }
                            } catch (e) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Toggle failed: $e')),
                                );
                              }
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                );
              },
              loading: () => const SizedBox.shrink(),
              error: (_, _) => const SizedBox.shrink(),
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
            Text('Achievements', style: theme.textTheme.titleLarge),
            const SizedBox(height: AppSpacing.sm),
            achievementsAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (err, _) => QvSurface(
                child: Text(
                  'Could not load achievements. Pull to retry later.',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              data: (list) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${list.unlockedCount} / ${list.total} unlocked',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  ...list.items.map(
                    (item) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _AchievementTile(item: item),
                    ),
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

class _PlanBadge extends StatelessWidget {
  const _PlanBadge({required this.isPremium});

  final bool isPremium;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: (isPremium ? AppColors.warning : AppColors.accent)
            .withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadii.pill),
        border: Border.all(
          color: (isPremium ? AppColors.warning : AppColors.accent)
              .withValues(alpha: 0.35),
        ),
      ),
      child: Text(
        isPremium ? 'PREMIUM' : 'FREE',
        style: theme.textTheme.labelLarge?.copyWith(
          color: isPremium ? AppColors.warning : AppColors.accent,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.1,
        ),
      ),
    );
  }
}

class _AchievementTile extends StatelessWidget {
  const _AchievementTile({required this.item});

  final AchievementItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final locked = !item.unlocked;

    return Opacity(
      opacity: locked ? 0.55 : 1,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadii.md),
          color: dark ? AppColors.surfaceDark : AppColors.surfaceLight,
          border: Border.all(
            color: item.unlocked
                ? AppColors.accent.withValues(alpha: 0.35)
                : (dark ? AppColors.borderDark : AppColors.borderLight),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.accent.withValues(alpha: 0.12),
              ),
              child: Text(
                locked ? '🔒' : _achievementIcon(item.icon),
                style: const TextStyle(fontSize: 18),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(item.description, style: theme.textTheme.bodyMedium),
                  if (item.unlocked)
                    Text(
                      [
                        if (item.xpReward > 0) '+${item.xpReward} XP',
                        if (item.coinsReward > 0) '+${item.coinsReward} coins',
                      ].join(' · '),
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: AppColors.accent,
                      ),
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

String _achievementIcon(String icon) {
  switch (icon) {
    case 'flag':
      return '🏁';
    case 'check':
      return '✅';
    case 'fire':
      return '🔥';
    case 'bolt':
      return '⚡';
    case 'brain':
      return '🧠';
    case 'infinity':
      return '∞';
    case 'star':
      return '⭐';
    case 'calendar':
      return '📅';
    case 'planet':
      return '🪐';
    case 'sigma':
      return '∑';
    case 'robot':
      return '🤖';
    default:
      return '🏆';
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
