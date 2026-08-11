import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/config/app_config.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
import 'package:speedquiz/core/network/api_errors.dart';
import 'package:speedquiz/core/settings/app_settings.dart';
import 'package:speedquiz/core/theme/app_motion.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/core/theme/theme_mode_provider.dart';
import 'package:speedquiz/features/auth/domain/auth_models.dart';
import 'package:speedquiz/features/auth/presentation/auth_controller.dart';
import 'package:speedquiz/features/auth/presentation/widgets/google_sign_in_button.dart';
import 'package:speedquiz/features/entitlements/data/entitlements_repository.dart';
import 'package:speedquiz/features/profile/presentation/widgets/profile_widgets.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _linkingGoogle = false;
  bool _signingOut = false;

  Future<void> _linkGoogle() async {
    if (_linkingGoogle) return;

    if (!AppConfig.hasGoogleSignInConfig) {
      await showSqInfo(
        context,
        title: 'Google sign-in unavailable',
        message: 'This build was compiled without a Google client ID, so '
            'accounts cannot be linked here.',
        glyph: '🔐',
        tone: SqDialogTone.warning,
      );
      return;
    }

    setState(() => _linkingGoogle = true);
    final result =
        await ref.read(authControllerProvider.notifier).signInWithGoogle();
    if (!mounted) return;
    setState(() => _linkingGoogle = false);

    if (result.isCancelled) return;
    if (result.isSuccess) {
      SqToast.success(context, 'Account linked — your progress is safe.');
    } else {
      SqToast.error(context, result.message ?? 'Could not link your account.');
    }
  }

  Future<void> _signOut(AuthUser user) async {
    if (_signingOut) return;

    final confirmed = await showSqConfirm(
      context,
      title: 'Sign out?',
      message: user.isGuest
          ? 'This is a guest session. Signing out ends it — level, XP and '
              'streak on this device will not come back unless you link a '
              'Google account first.'
          : 'You can sign back in with Google any time and pick up exactly '
              'where you left off.',
      confirmLabel: 'SIGN OUT',
      cancelLabel: 'STAY',
      tone: user.isGuest ? SqDialogTone.danger : SqDialogTone.neutral,
      glyph: user.isGuest ? '⚠️' : '👋',
    );
    if (!confirmed || !mounted) return;

    setState(() => _signingOut = true);
    await ref.read(authControllerProvider.notifier).signOut();
    // The router redirects to the landing screen once the state flips.
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final user = ref.watch(currentUserProvider);
    final themeMode = ref.watch(themeModeProvider);
    final settings = ref.watch(settingsProvider);
    final entitlements = ref.watch(entitlementsProvider).valueOrNull;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SqBackdrop(
        intensity: 0.4,
        child: SafeArea(
          child: Column(
            children: [
              const SubScreenHeader(title: 'Settings'),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.sm,
                    AppSpacing.lg,
                    AppSpacing.xxl,
                  ),
                  children: [
                    SqStagger(
                      child: const SqSectionHeader(
                        title: 'Appearance',
                        subtitle: 'Applies instantly across the app',
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    SqStagger(
                      index: 1,
                      child: _ThemePicker(
                        mode: themeMode,
                        onChanged: (mode) {
                          Haptics.tap();
                          ref.read(themeModeProvider.notifier).setMode(mode);
                        },
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    SqStagger(
                      index: 2,
                      child: const SqSectionHeader(
                        title: 'Feel',
                        subtitle: 'Sound and vibration',
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    SqStagger(
                      index: 3,
                      child: SqSurface(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md,
                          vertical: 4,
                        ),
                        child: Column(
                          children: [
                            _SettingSwitch(
                              icon: Icons.volume_up_rounded,
                              title: 'Sound effects',
                              subtitle: 'Answer, streak and result cues',
                              value: settings.soundEnabled,
                              onChanged: (value) {
                                Haptics.tap();
                                ref
                                    .read(settingsProvider.notifier)
                                    .setSound(value);
                              },
                            ),
                            Divider(height: 1, color: p.border),
                            _SettingSwitch(
                              icon: Icons.music_note_rounded,
                              title: 'Ambient music',
                              subtitle: 'Low background loop while you play',
                              value: settings.musicEnabled,
                              onChanged: (value) {
                                Haptics.tap();
                                ref
                                    .read(settingsProvider.notifier)
                                    .setMusic(value);
                              },
                            ),
                            Divider(height: 1, color: p.border),
                            _SettingSwitch(
                              icon: Icons.vibration_rounded,
                              title: 'Haptics',
                              subtitle: 'Taps, hits and misses you can feel',
                              value: settings.hapticsEnabled,
                              onChanged: (value) {
                                ref
                                    .read(settingsProvider.notifier)
                                    .setHaptics(value);
                                if (value) Haptics.success();
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    SqStagger(
                      index: 4,
                      child: const SqSectionHeader(title: 'Account'),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    if (user?.isGuest == true) ...[
                      SqStagger(
                        index: 5,
                        child: SqSurface(
                          padding: const EdgeInsets.all(AppSpacing.lg),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(
                                    Icons.shield_moon_outlined,
                                    color: AppColors.warning,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Save your progress',
                                    style: theme.textTheme.titleMedium,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Guest progress lives only on this device. '
                                'Link a Google account and your level, streak '
                                'and ranks follow you anywhere.',
                                style: theme.textTheme.bodyMedium,
                              ),
                              const SizedBox(height: AppSpacing.md),
                              GoogleSignInButton(
                                label: 'Link Google account',
                                loading: _linkingGoogle,
                                onPressed: _linkGoogle,
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                    ] else if (user?.email != null) ...[
                      SqStagger(
                        index: 5,
                        child: SqSurface(
                          child: Row(
                            children: [
                              const Icon(
                                Icons.verified_user_rounded,
                                color: AppColors.success,
                                size: 20,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Signed in with Google',
                                      style: theme.textTheme.titleSmall,
                                    ),
                                    Text(
                                      user!.email!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                    ],
                    if (entitlements?.devToggleAllowed ?? false) ...[
                      SqStagger(
                        index: 6,
                        child: _DevEntitlements(
                          isPremium: entitlements?.isPremium ?? false,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                    ],
                    if (user != null)
                      SqStagger(
                        index: 7,
                        child: SqButton(
                          label: _signingOut ? 'SIGNING OUT…' : 'SIGN OUT',
                          icon: Icons.logout_rounded,
                          variant: SqButtonVariant.danger,
                          loading: _signingOut,
                          onPressed: () => _signOut(user),
                        ),
                      ),
                    const SizedBox(height: AppSpacing.lg),
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
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingSwitch extends StatelessWidget {
  const _SettingSwitch({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Icon(icon, size: 20, color: value ? p.accent : p.textFaint),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleSmall),
                const SizedBox(height: 1),
                Text(subtitle, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _ThemePicker extends StatelessWidget {
  const _ThemePicker({required this.mode, required this.onChanged});

  final ThemeMode mode;
  final ValueChanged<ThemeMode> onChanged;

  static const _options = [
    (ThemeMode.dark, 'Dark', Icons.dark_mode_rounded),
    (ThemeMode.light, 'Light', Icons.light_mode_rounded),
    (ThemeMode.system, 'System', Icons.brightness_auto_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return Row(
      children: [
        for (final (value, label, icon) in _options) ...[
          Expanded(
            child: SqPressable(
              onTap: () => onChanged(value),
              haptic: false,
              pressedScale: 0.95,
              child: AnimatedContainer(
                duration: AppMotion.fast,
                curve: AppMotion.standard,
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  color: mode == value ? p.accentWash(0.15) : p.surface,
                  borderRadius: BorderRadius.circular(AppRadii.md),
                  border: Border.all(
                    color: mode == value ? p.accentWash(0.5) : p.border,
                    width: mode == value ? 1.5 : 1,
                  ),
                ),
                child: Column(
                  children: [
                    Icon(
                      icon,
                      size: 20,
                      color: mode == value ? p.accent : p.textSecondary,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      label,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: mode == value ? p.accent : p.textSecondary,
                        fontWeight:
                            mode == value ? FontWeight.w800 : FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (value != _options.last.$1) const SizedBox(width: 10),
        ],
      ],
    );
  }
}

/// Only rendered when the server says this build may toggle entitlements.
class _DevEntitlements extends ConsumerWidget {
  const _DevEntitlements({required this.isPremium});

  final bool isPremium;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return SqSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.construction_rounded,
                size: 18,
                color: AppColors.warning,
              ),
              const SizedBox(width: 8),
              Text('Dev entitlements', style: theme.textTheme.titleSmall),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              isPremium ? 'Premium enabled' : 'Enable Premium',
              style: theme.textTheme.titleSmall,
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
                  SqToast.success(
                    context,
                    updated.isPremium
                        ? 'Premium enabled (dev)'
                        : 'Back to Free (dev)',
                  );
                }
              } catch (error) {
                if (context.mounted) {
                  SqToast.error(context, apiErrorMessage(error));
                }
              }
            },
          ),
        ],
      ),
    );
  }
}
