import 'package:flutter/material.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/routing/nav.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/auth/domain/auth_models.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// Identity block reused by the profile hub and the edit screen.
class ProfileIdentityCard extends StatelessWidget {
  const ProfileIdentityCard({
    super.key,
    required this.user,
    required this.isPremium,
    this.onTap,
    this.compact = false,
    this.animateProgress = false,
  });

  final AuthUser? user;
  final bool isPremium;
  final VoidCallback? onTap;
  final bool compact;

  /// Sweep the level ring and XP bar up from empty. The profile hub turns this
  /// on so opening the tab reads as progress being counted up, rather than a
  /// static readout the player has to interpret.
  final bool animateProgress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final level = user?.level ?? 1;
    final xp = user?.xp ?? 0;
    final threshold = xpThresholdForLevel(level);
    final progress = threshold <= 0 ? 0.0 : (xp / threshold).clamp(0.0, 1.0);

    final card = SqGlowBorder(
      radius: AppRadii.lg,
      thickness: 1.4,
      glow: 0.24,
      period: const Duration(seconds: 9),
      colors: isPremium
          ? const [
              AppColors.gold,
              Color(0xFFFFF0C2),
              Color(0xFFFF9F43),
              AppColors.gold,
            ]
          : null,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.lg),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadii.lg),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isPremium
                ? [
                    AppColors.gold.withValues(alpha: p.isDark ? 0.16 : 0.12),
                    p.surface,
                  ]
                : [p.accentWash(p.isDark ? 0.14 : 0.09), p.surface],
          ),
          boxShadow: AppShadows.soft(p),
        ),
        child: Column(
          children: [
            SqProgressRing(
              value: progress,
              size: compact ? 82 : 96,
              stroke: 5,
              fillFromZero: animateProgress,
              gradient: isPremium
                  ? AppColors.premiumGradient
                  : AppColors.brandGradient,
              child: SqAvatar(
                name: user?.name,
                seed: user?.id,
                avatarId: user?.avatarId,
                size: compact ? 62 : 74,
                premium: isPremium,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              user?.name ?? context.l10n.profileGuest,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              alignment: WrapAlignment.center,
              children: [
                SqBadge(
                  label: context.l10n.levelBadge(level),
                  icon: Icons.military_tech_rounded,
                ),
                SqBadge(
                  label: isPremium
                      ? context.l10n.profilePremiumBadge
                      : context.l10n.profileFree,
                  color: isPremium ? AppColors.gold : p.accent,
                  gradient: isPremium ? AppColors.premiumGradient : null,
                ),
                if (user?.isGuest == true)
                  SqBadge(
                    label: context.l10n.profileGuestBadge,
                    color: p.textSecondary,
                    icon: Icons.person_outline_rounded,
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            SqProgressTrack(
              value: progress,
              height: 7,
              fillFromZero: animateProgress,
            ),
            const SizedBox(height: 6),
            Text(
              '$xp / $threshold XP to level ${level + 1}',
              style: theme.textTheme.labelSmall?.copyWith(color: p.textFaint),
            ),
          ],
        ),
      ),
    );

    // Lights drifting along the edge. Premium gets a warm palette; everyone
    // else the brand ramp, so the card still breathes without implying status.
    final lit = SqParticleBorder(
      radius: AppRadii.lg,
      count: isPremium ? 5 : 4,
      colors: isPremium
          ? const [AppColors.gold, Color(0xFFFFF0C2), Color(0xFFFF9F43)]
          : null,
      child: card,
    );

    if (onTap == null) return lit;
    return SqPressable(onTap: onTap, pressedScale: 0.99, child: lit);
  }
}

/// One row in the profile hub's navigation list.
class ProfileNavTile extends StatelessWidget {
  const ProfileNavTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.tint,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Color? tint;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final color = tint ?? p.accent;

    return SqSurface(
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(AppRadii.sm),
              border: Border.all(color: color.withValues(alpha: 0.26)),
            ),
            child: Icon(icon, size: 20, color: color),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleSmall),
                const SizedBox(height: 1),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (trailing != null) ...[trailing!, const SizedBox(width: 6)],
          Icon(Icons.chevron_right_rounded, color: p.textFaint, size: 20),
        ],
      ),
    );
  }
}

/// Small labelled stat used across profile screens.
class ProfileMetric extends StatelessWidget {
  const ProfileMetric({
    super.key,
    required this.label,
    required this.value,
    required this.glyph,
    this.glyphWidget,
  });

  final String label;
  final String value;
  final String glyph;

  /// Replaces the emoji with a live widget — used for the streak flame.
  /// [glyph] stays required so every metric keeps a text fallback.
  final Widget? glyphWidget;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(AppRadii.sm),
        border: Border.all(color: p.border),
      ),
      child: Column(
        children: [
          SizedBox(
            height: 19,
            child: Center(
              child: glyphWidget ??
                  Text(glyph, style: const TextStyle(fontSize: 16)),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              fontFamily: 'SpaceGrotesk',
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: p.textFaint,
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }
}

/// Standard header for the pushed profile sub-screens.
class SubScreenHeader extends StatelessWidget {
  const SubScreenHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.action,
    this.fallback = Routes.profile,
  });

  final String title;
  final String? subtitle;
  final Widget? action;

  /// Where back lands when this screen is the only page in the stack — a deep
  /// link or a cold start can open it with nothing underneath.
  final String fallback;

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
            icon: Icons.arrow_back_rounded,
            tooltip: context.l10n.profileBack,
            onPressed: () => context.popOrGo(fallback),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge,
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}
