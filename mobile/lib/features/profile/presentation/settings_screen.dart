import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/config/app_config.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/i18n/language_providers.dart';
import 'package:speedquiz/core/i18n/widgets/language_picker.dart';
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
    final l10n = context.l10n;

    if (!AppConfig.hasGoogleSignInConfig) {
      await showSqInfo(
        context,
        title: l10n.settingsGoogleUnavailable,
        message: l10n.settingsGoogleUnavailableBody,
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
      SqToast.success(context, l10n.settingsAccountLinked);
    } else {
      SqToast.error(context, result.message ?? l10n.settingsAccountLinkFailed);
    }
  }

  Future<void> _signOut(AuthUser user) async {
    if (_signingOut) return;
    final l10n = context.l10n;

    final confirmed = await showSqConfirm(
      context,
      title: l10n.settingsSignOutTitle,
      message: user.isGuest
          ? l10n.settingsSignOutGuestBody
          : l10n.settingsSignOutBody,
      confirmLabel: l10n.settingsSignOutConfirm,
      cancelLabel: l10n.settingsStay,
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
    final l10n = context.l10n;
    final user = ref.watch(currentUserProvider);
    final themeMode = ref.watch(themeModeProvider);
    final settings = ref.watch(settingsProvider);
    final appLanguage = ref.watch(appLanguageProvider);
    final quizLanguage = ref.watch(quizLanguageProvider);
    final entitlements = ref.watch(entitlementsProvider).valueOrNull;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SqBackdrop(
        intensity: 0.4,
        child: SafeArea(
          child: Column(
            children: [
              SubScreenHeader(title: l10n.settingsTitle),
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
                      child: SqSectionHeader(
                        title: l10n.settingsLanguageSection,
                        subtitle: l10n.settingsLanguageSubtitle,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    // Two independent settings, deliberately adjacent: seeing
                    // them side by side is what makes it obvious they *are*
                    // independent, which is the whole point of the feature.
                    SqStagger(
                      index: 1,
                      child: SqSurface(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _LanguageRow(
                              icon: Icons.translate_rounded,
                              title: l10n.appLanguageTitle,
                              subtitle: l10n.appLanguageSubtitle,
                            ),
                            const SizedBox(height: 10),
                            SqLanguagePicker(
                              selected: appLanguage,
                              onChanged: (language) async {
                                if (language == appLanguage) return;
                                Haptics.tap();
                                await ref
                                    .read(appLanguageProvider.notifier)
                                    .setLanguage(language);
                                if (!context.mounted) return;
                                // Read the strings *after* the switch so the
                                // confirmation itself arrives in the new
                                // language — the first proof it worked.
                                SqToast.success(
                                  context,
                                  context.l10n
                                      .languageChanged(language.nativeLabel),
                                );
                              },
                            ),
                            const SizedBox(height: AppSpacing.md),
                            Divider(height: 1, color: p.border),
                            const SizedBox(height: AppSpacing.md),
                            _LanguageRow(
                              icon: Icons.quiz_outlined,
                              title: l10n.quizLanguageTitle,
                              subtitle: l10n.quizLanguageSubtitle,
                            ),
                            const SizedBox(height: 10),
                            SqLanguagePicker(
                              selected: quizLanguage,
                              tint: AppColors.violet,
                              onChanged: (language) {
                                if (language == quizLanguage) return;
                                Haptics.tap();
                                ref
                                    .read(quizLanguageProvider.notifier)
                                    .setLanguage(language);
                              },
                            ),
                            const SizedBox(height: 8),
                            Text(
                              l10n.quizLanguageHint,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: p.textFaint,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    SqStagger(
                      index: 2,
                      child: SqSectionHeader(
                        title: l10n.settingsAppearance,
                        subtitle: l10n.settingsAppearanceSubtitle,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    SqStagger(
                      index: 3,
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
                      index: 4,
                      child: SqSectionHeader(
                        title: l10n.settingsFeel,
                        subtitle: l10n.settingsFeelSubtitle,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    SqStagger(
                      index: 5,
                      child: SqSurface(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md,
                          vertical: 4,
                        ),
                        child: Column(
                          children: [
                            _SettingSwitch(
                              icon: Icons.volume_up_rounded,
                              title: l10n.settingsSound,
                              subtitle: l10n.settingsSoundSubtitle,
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
                              title: l10n.settingsMusic,
                              subtitle: l10n.settingsMusicSubtitle,
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
                              title: l10n.settingsHaptics,
                              subtitle: l10n.settingsHapticsSubtitle,
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
                      index: 6,
                      child: SqSectionHeader(title: l10n.settingsAccount),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    if (user?.isGuest == true) ...[
                      SqStagger(
                        index: 7,
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
                                    l10n.settingsSaveProgress,
                                    style: theme.textTheme.titleMedium,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                l10n.settingsSaveProgressBody,
                                style: theme.textTheme.bodyMedium,
                              ),
                              const SizedBox(height: AppSpacing.md),
                              GoogleSignInButton(
                                label: l10n.settingsLinkGoogle,
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
                        index: 7,
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
                                      l10n.settingsSignedInWithGoogle,
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
                        index: 8,
                        child: _DevEntitlements(
                          isPremium: entitlements?.isPremium ?? false,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                    ],
                    if (user != null)
                      SqStagger(
                        index: 9,
                        child: SqButton(
                          label: _signingOut
                              ? l10n.settingsSigningOut
                              : l10n.settingsSignOut,
                          icon: Icons.logout_rounded,
                          variant: SqButtonVariant.danger,
                          loading: _signingOut,
                          onPressed: () => _signOut(user),
                        ),
                      ),
                    const SizedBox(height: AppSpacing.lg),
                    Center(
                      child: Text(
                        l10n.settingsVersion(AppConfig.appVersion),
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

/// Icon + title + subtitle line above a language picker.
class _LanguageRow extends StatelessWidget {
  const _LanguageRow({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return Row(
      children: [
        Icon(icon, size: 19, color: p.accent),
        const SizedBox(width: 12),
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
      ],
    );
  }
}

class _ThemePicker extends StatelessWidget {
  const _ThemePicker({required this.mode, required this.onChanged});

  final ThemeMode mode;
  final ValueChanged<ThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final l10n = context.l10n;
    final options = [
      (ThemeMode.dark, l10n.settingsThemeDark, Icons.dark_mode_rounded),
      (ThemeMode.light, l10n.settingsThemeLight, Icons.light_mode_rounded),
      (ThemeMode.system, l10n.settingsThemeSystem, Icons.brightness_auto_rounded),
    ];

    return Row(
      children: [
        for (final (value, label, icon) in options) ...[
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
          if (value != options.last.$1) const SizedBox(width: 10),
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
    final l10n = context.l10n;

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
              Text(
                l10n.settingsDevEntitlements,
                style: theme.textTheme.titleSmall,
              ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              isPremium ? l10n.settingsPremiumEnabled : l10n.settingsEnablePremium,
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
                        ? l10n.settingsPremiumEnabledDev
                        : l10n.settingsBackToFreeDev,
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
