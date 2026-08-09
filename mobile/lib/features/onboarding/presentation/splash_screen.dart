import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:quizverse/core/theme/app_theme.dart';
import 'package:quizverse/features/auth/presentation/auth_controller.dart';
import 'package:quizverse/shared/widgets/qv_button.dart';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.08),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _controller.forward();
    Future.microtask(() => ref.read(authControllerProvider.notifier).bootstrap());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final theme = Theme.of(context);

    return Scaffold(
      body: Container(
        width: double.infinity,
        decoration: BoxDecoration(gradient: AppColors.backgroundDark.wash),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: FadeTransition(
              opacity: _fade,
              child: SlideTransition(
                position: _slide,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Spacer(),
                    Text(
                      'QUIZVERSE',
                      style: theme.textTheme.displayMedium?.copyWith(
                        color: AppColors.textPrimaryDark,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -1.5,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      width: 56,
                      height: 4,
                      decoration: BoxDecoration(
                        color: AppColors.accent,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      'Endless AI quizzes. Real game energy.',
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: AppColors.textSecondaryDark,
                      ),
                    ),
                    const Spacer(flex: 2),
                    Text(
                      auth is AuthError
                          ? 'Connection issue'
                          : 'Signing you in as guest…',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: AppColors.textSecondaryDark,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    if (auth is AuthLoading || auth is AuthInitial)
                      const LinearProgressIndicator(
                        color: AppColors.accent,
                        backgroundColor: Color(0xFF243041),
                      ),
                    if (auth is AuthError) ...[
                      Text(
                        'Could not reach the server.\n${auth.message}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: AppColors.danger,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      QvButton(
                        label: 'Retry as Guest',
                        onPressed: () => ref
                            .read(authControllerProvider.notifier)
                            .continueAsGuest(),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.lg),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
