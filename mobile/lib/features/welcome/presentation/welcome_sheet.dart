import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/feedback/audio_service.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/auth/domain/auth_models.dart';
import 'package:speedquiz/features/daily/domain/daily_models.dart';
import 'package:speedquiz/features/welcome/domain/welcome_cue.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// The greeting a player gets when a session starts.
///
/// Modelled on what the big storefront apps do on sign-in: name them, show
/// them the state of their account in one glance, tell them what is waiting
/// today, and offer exactly one way forward.
Future<void> showWelcomeSheet(
  BuildContext context, {
  required WelcomeCue cue,
  DailyChallengeInfo? daily,
  VoidCallback? onPlay,
}) {
  Haptics.milestone();
  Sound.play(cue.isFirstEver ? Sfx.unlock : Sfx.streak);

  return showSqSheet<void>(
    context,
    builder: (sheetContext) => _WelcomeBody(
      cue: cue,
      daily: daily,
      onPlay: onPlay,
    ),
  );
}

class _WelcomeBody extends StatelessWidget {
  const _WelcomeBody({required this.cue, this.daily, this.onPlay});

  final WelcomeCue cue;
  final DailyChallengeInfo? daily;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final user = cue.user;
    final threshold = xpThresholdForLevel(user.level);
    final progress = threshold <= 0
        ? 0.0
        : (user.xp / threshold).clamp(0.0, 1.0);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.lg + MediaQuery.paddingOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SqStagger(
            child: SqGlowBorder(
              radius: AppRadii.pill,
              thickness: 2,
              glow: 0.34,
              period: const Duration(seconds: 5),
              colors: user.isPremium
                  ? const [
                      AppColors.gold,
                      Color(0xFFFFF0C2),
                      Color(0xFFFF9F43),
                      AppColors.gold,
                    ]
                  : null,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: SqProgressRing(
                  value: progress,
                  size: 96,
                  stroke: 5,
                  gradient: user.isPremium
                      ? AppColors.premiumGradient
                      : AppColors.brandGradient,
                  child: SqAvatar(
                    name: user.name,
                    seed: user.id,
                    avatarId: user.avatarId,
                    size: 74,
                    premium: user.isPremium,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          SqStagger(
            index: 1,
            child: Text(
              cue.headline(context.l10n),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.headlineSmall,
            ),
          ),
          const SizedBox(height: 6),
          SqStagger(
            index: 2,
            child: Text(
              _subtitle(context.l10n, user),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          SqStagger(
            index: 3,
            child: Row(
              children: [
                Expanded(
                  child: _Stat(
                    glyph: '🎖️',
                    label: context.l10n.level,
                    value: '${user.level}',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _Stat(
                    glyph: '🪙',
                    label: context.l10n.coins,
                    value: '${user.coins}',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _Stat(
                    glyph: '🔥',
                    label: context.l10n.streak,
                    value: '${user.dailyStreak}',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          SqStagger(
            index: 4,
            child: Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: p.accentWash(0.08),
                borderRadius: BorderRadius.circular(AppRadii.md),
                border: Border.all(color: p.accentWash(0.22)),
              ),
              child: Row(
                children: [
                  Text(
                    _todayGlyph(),
                    style: const TextStyle(fontSize: 18),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.l10n.welcomeWaitingToday,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: p.textFaint,
                            letterSpacing: 1,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _todayLine(context.l10n),
                          style: theme.textTheme.titleSmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          SqStagger(
            index: 5,
            child: SqButton(
              label: cue.isFirstEver
                  ? context.l10n.welcomeStartPlaying
                  : context.l10n.welcomeJumpBackIn,
              icon: Icons.play_arrow_rounded,
              onPressed: () {
                Navigator.of(context).pop();
                onPlay?.call();
              },
            ),
          ),
          const SizedBox(height: 8),
          SqStagger(
            index: 6,
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(context.l10n.welcomeLookAround),
            ),
          ),
        ],
      ),
    );
  }

  String _subtitle(SqStrings l10n, AuthUser user) {
    if (cue.isFirstEver) {
      return user.isGuest ? l10n.welcomeGuestBody : l10n.welcomeAccountBody;
    }
    final email = user.email;
    if (email != null && email.isNotEmpty) return email;
    return user.isGuest
        ? l10n.welcomeGuestHandle(user.username)
        : '@${user.username}';
  }

  String _todayGlyph() {
    final d = daily;
    if (d == null) return '⚡';
    if (d.isCompleted) return '✅';
    return d.topicIcon;
  }

  String _todayLine(SqStrings l10n) {
    final d = daily;
    if (d == null) return l10n.welcomeCuePickTopic;
    if (d.isCompleted) return l10n.welcomeCueDailyDone;
    if (d.isInProgress) return l10n.welcomeCueResumeDaily(d.topicName);
    return l10n.welcomeCueDaily(d.topicName);
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.glyph, required this.label, required this.value});

  final String glyph;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(AppRadii.sm),
        border: Border.all(color: p.border),
      ),
      child: Column(
        children: [
          Text(glyph, style: const TextStyle(fontSize: 16)),
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
          Text(
            label.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: p.textFaint,
              fontSize: 10,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

/// The quiet version, for a player who simply relaunched the app.
class WelcomeBanner extends ConsumerWidget {
  const WelcomeBanner({
    super.key,
    required this.name,
    required this.onDismiss,
  });

  final String name;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return SqSurface(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: 12,
      ),
      child: Row(
        children: [
          const Text('👋', style: TextStyle(fontSize: 18)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              context.l10n.welcomeBack(name),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall,
            ),
          ),
          GestureDetector(
            onTap: onDismiss,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.close_rounded, size: 18, color: p.textFaint),
            ),
          ),
        ],
      ),
    );
  }
}
