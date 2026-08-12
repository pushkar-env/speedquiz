import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:speedquiz/core/config/app_config.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/achievements/data/achievements_repository.dart';
import 'package:speedquiz/features/auth/presentation/auth_controller.dart';
import 'package:speedquiz/features/entitlements/data/entitlements_repository.dart';
import 'package:speedquiz/features/profile/presentation/widgets/account_card.dart';
import 'package:speedquiz/features/profile/presentation/widgets/profile_widgets.dart';
import 'package:speedquiz/features/shell/presentation/main_shell.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// Profile hub. Details, achievements and premium each live on their own
/// screen — this page is the identity summary plus the way into them.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final user = ref.watch(currentUserProvider);
    final achievementsAsync = ref.watch(achievementsProvider);
    final entitlementsAsync = ref.watch(entitlementsProvider);
    final isPremium =
        entitlementsAsync.valueOrNull?.isPremium ?? user?.isPremium ?? false;

    final unlocked = achievementsAsync.valueOrNull?.unlockedCount;
    final totalAchievements = achievementsAsync.valueOrNull?.total;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SqBackdrop(
        intensity: 0.5,
        child: SafeArea(
          bottom: false,
          child: RefreshIndicator(
            color: p.accent,
            backgroundColor: p.surfaceElevated,
            onRefresh: () async {
              ref.invalidate(achievementsProvider);
              ref.invalidate(entitlementsProvider);
              await ref.read(authControllerProvider.notifier).refreshMe();
            },
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
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Profile',
                          style: theme.textTheme.displaySmall,
                        ),
                      ),
                      SqIconButton(
                        icon: Icons.settings_outlined,
                        tooltip: 'Settings',
                        onPressed: () => context.push(Routes.settings),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                SqStagger(
                  index: 1,
                  child: ProfileIdentityCard(
                    user: user,
                    isPremium: isPremium,
                    onTap: () => context.push(Routes.profileEdit),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                SqStagger(
                  index: 2,
                  child: Row(
                    children: [
                      Expanded(
                        child: ProfileMetric(
                          label: 'Coins',
                          value: '${user?.coins ?? 0}',
                          glyph: '🪙',
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ProfileMetric(
                          label: 'Daily streak',
                          value:
                              '${user?.dailyStreak ?? user?.currentStreak ?? 0}',
                          glyph: '🔥',
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ProfileMetric(
                          label: 'Best streak',
                          value: '${user?.bestStreak ?? 0}',
                          glyph: '🏅',
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                SqStagger(index: 3, child: AccountCard(user: user)),
                const SizedBox(height: AppSpacing.xl),
                SqStagger(
                  index: 4,
                  child: ProfileNavTile(
                    icon: Icons.badge_outlined,
                    title: 'Profile details',
                    subtitle: 'Name, avatar and how you appear on boards',
                    onTap: () => context.push(Routes.profileEdit),
                  ),
                ),
                const SizedBox(height: 10),
                SqStagger(
                  index: 5,
                  child: ProfileNavTile(
                    icon: Icons.emoji_events_outlined,
                    title: 'Achievements',
                    subtitle: unlocked == null
                        ? 'Track everything you have unlocked'
                        : '$unlocked of $totalAchievements unlocked',
                    tint: AppColors.gold,
                    onTap: () => context.push(Routes.achievements),
                    trailing: unlocked == null
                        ? null
                        : SqBadge(label: '$unlocked', dense: true),
                  ),
                ),
                const SizedBox(height: 10),
                SqStagger(
                  index: 6,
                  child: ProfileNavTile(
                    icon: Icons.insights_rounded,
                    title: 'Statistics',
                    subtitle: 'Accuracy, speed and topic mastery',
                    tint: AppColors.cyan,
                    onTap: () => context.push(Routes.stats),
                  ),
                ),
                const SizedBox(height: 10),
                SqStagger(
                  index: 7,
                  child: ProfileNavTile(
                    icon: isPremium
                        ? Icons.workspace_premium_rounded
                        : Icons.workspace_premium_outlined,
                    title: isPremium ? 'Premium' : 'Go Premium',
                    subtitle: isPremium
                        ? 'Thanks for supporting SpeedQuiz'
                        : 'Unlimited questions and custom topics',
                    tint: AppColors.gold,
                    onTap: () => context.push(Routes.premium),
                  ),
                ),
                const SizedBox(height: 10),
                SqStagger(
                  index: 8,
                  child: ProfileNavTile(
                    icon: Icons.tune_rounded,
                    title: 'Settings',
                    subtitle: 'Appearance, sound and account',
                    tint: AppColors.violet,
                    onTap: () => context.push(Routes.settings),
                  ),
                ),
                const SizedBox(height: AppSpacing.xl),
                Center(
                  child: Text(
                    'SpeedQuiz · v${AppConfig.appVersion}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: p.textFaint,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
