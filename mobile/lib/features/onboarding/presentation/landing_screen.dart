import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/config/app_config.dart';
import 'package:speedquiz/core/theme/app_motion.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/auth/presentation/auth_controller.dart';
import 'package:speedquiz/features/auth/presentation/widgets/google_sign_in_button.dart';
import 'package:speedquiz/shared/widgets/sq_logo.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// First screen a signed-out player sees: brand, value props, and the two
/// ways in — guest (zero friction) or Google (portable progress).
class LandingScreen extends ConsumerStatefulWidget {
  const LandingScreen({super.key});

  @override
  ConsumerState<LandingScreen> createState() => _LandingScreenState();
}

class _LandingScreenState extends ConsumerState<LandingScreen> {
  final _guestKey = GlobalKey<SqButtonState>();
  final _googleKey = GlobalKey<GoogleSignInButtonState>();

  /// Which button owns the in-flight request, so only it shows a spinner.
  String? _busyAction;

  static const _highlights = [
    ('⚡', 'Five game modes', 'Casual, Speedrun, Survival, Negative, Sudden Death'),
    ('🏆', 'Daily challenge & ranks', 'One fresh set a day, weekly and daily boards'),
    ('🧠', 'Every answer explained', 'Miss one and the app teaches you why'),
  ];

  Future<void> _continueAsGuest() async {
    if (_busyAction != null) return;
    setState(() => _busyAction = 'guest');
    await ref.read(authControllerProvider.notifier).continueAsGuest();
    if (!mounted) return;
    setState(() => _busyAction = null);

    final state = ref.read(authControllerProvider);
    if (state is AuthSignedOut && state.message != null) {
      _guestKey.currentState?.reject();
      SqToast.error(
        context,
        state.message!,
        actionLabel: 'RETRY',
        onAction: _continueAsGuest,
      );
    }
  }

  Future<void> _continueWithGoogle() async {
    if (_busyAction != null) return;

    if (!AppConfig.hasGoogleSignInConfig) {
      _googleKey.currentState?.reject();
      await showSqInfo(
        context,
        title: 'Google sign-in unavailable',
        message: 'This build was compiled without a Google client ID. '
            'Play as a guest — you can link a Google account later.',
        glyph: '🔐',
        tone: SqDialogTone.warning,
        actionLabel: 'PLAY AS GUEST',
      );
      if (mounted) await _continueAsGuest();
      return;
    }

    setState(() => _busyAction = 'google');
    final result =
        await ref.read(authControllerProvider.notifier).signInWithGoogle();
    if (!mounted) return;
    setState(() => _busyAction = null);

    if (result.isCancelled) return;
    if (!result.isSuccess) {
      _googleKey.currentState?.reject();
      SqToast.error(context, result.message ?? 'Google sign-in failed.');
    }
  }

  Future<void> _retryStoredSession() async {
    if (_busyAction != null) return;
    setState(() => _busyAction = 'retry');
    await ref.read(authControllerProvider.notifier).bootstrap();
    if (mounted) setState(() => _busyAction = null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final auth = ref.watch(authControllerProvider);
    final signedOut = auth is AuthSignedOut ? auth : const AuthSignedOut();
    final busy = _busyAction != null || signedOut.pending;

    return Scaffold(
      body: SqBackdrop(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.lg,
                  AppSpacing.lg,
                  AppSpacing.md,
                ),
                // minHeight + Center keeps the block optically centred on tall
                // screens and lets it scroll on short ones.
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: constraints.maxHeight - AppSpacing.xl,
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 460),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const SqStagger(
                            child: Center(
                              child: SqFloat(child: SqLogoMark(size: 88)),
                            ),
                          ),
                          const SizedBox(height: AppSpacing.lg),
                          const SqStagger(
                            index: 1,
                            child: Center(child: SqWordmark(fontSize: 42)),
                          ),
                          const SizedBox(height: 10),
                          SqStagger(
                            index: 2,
                            child: Text(
                              'Endless AI quizzes. Real game energy.',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyLarge?.copyWith(
                                color: p.textSecondary,
                              ),
                            ),
                          ),
                          const SizedBox(height: AppSpacing.xl),
                          for (var i = 0; i < _highlights.length; i++)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: SqStagger(
                                index: 3 + i,
                                child: _Highlight(
                                  glyph: _highlights[i].$1,
                                  title: _highlights[i].$2,
                                  subtitle: _highlights[i].$3,
                                ),
                              ),
                            ),
                          const SizedBox(height: AppSpacing.lg),
                          if (signedOut.message != null) ...[
                            _ConnectionNotice(
                              message: signedOut.message!,
                              onRetry: busy ? null : _retryStoredSession,
                              retrying: _busyAction == 'retry',
                            ),
                            const SizedBox(height: AppSpacing.md),
                          ],
                          SqStagger(
                            index: 6,
                            child: SqButton(
                              key: _guestKey,
                              label: signedOut.hasStoredSession
                                  ? 'START A NEW GUEST RUN'
                                  : 'PLAY AS GUEST',
                              icon: Icons.bolt_rounded,
                              loading: _busyAction == 'guest',
                              onPressed: busy ? null : _continueAsGuest,
                            ),
                          ),
                          const SizedBox(height: 12),
                          SqStagger(
                            index: 7,
                            child: GoogleSignInButton(
                              key: _googleKey,
                              loading: _busyAction == 'google',
                              onPressed: busy ? null : _continueWithGoogle,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.md),
                          Text(
                            'Guest progress is saved on this device and '
                            'carries over when you link a Google account.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: p.textFaint,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Highlight extends StatelessWidget {
  const _Highlight({
    required this.glyph,
    required this.title,
    required this.subtitle,
  });

  final String glyph;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: p.surface.withValues(alpha: p.isDark ? 0.55 : 0.85),
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: p.border.withValues(alpha: 0.8)),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: p.accentWash(0.12),
              borderRadius: BorderRadius.circular(AppRadii.sm),
            ),
            child: Text(glyph, style: const TextStyle(fontSize: 18)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleSmall),
                const SizedBox(height: 1),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: p.textFaint,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectionNotice extends StatelessWidget {
  const _ConnectionNotice({
    required this.message,
    required this.onRetry,
    required this.retrying,
  });

  final String message;
  final VoidCallback? onRetry;
  final bool retrying;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AnimatedSize(
      duration: AppMotion.normal,
      curve: AppMotion.enter,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.warning.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(AppRadii.md),
          border: Border.all(color: AppColors.warning.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.cloud_off_rounded,
              color: AppColors.warning,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.warning,
                ),
              ),
            ),
            if (onRetry != null)
              TextButton(
                onPressed: retrying ? null : onRetry,
                child: Text(retrying ? '…' : 'RETRY'),
              ),
          ],
        ),
      ),
    );
  }
}
