import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/theme/app_motion.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/auth/presentation/auth_controller.dart';
import 'package:speedquiz/shared/widgets/sq_logo.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// Boot screen. Restores a stored session, then the router sends the player
/// to the landing screen or straight into the app.
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  late final Animation<double> _fade = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0, 0.6, curve: Curves.easeOut),
  );

  late final Animation<double> _markScale = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0, 0.7, curve: AppMotion.spring),
  );

  @override
  void initState() {
    super.initState();
    _controller.forward();
    Future.microtask(
      () => ref.read(authControllerProvider.notifier).bootstrap(),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return Scaffold(
      body: SqBackdrop(
        intensity: 0.8,
        child: SafeArea(
          child: FadeTransition(
            opacity: _fade,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                children: [
                  const Spacer(flex: 3),
                  ScaleTransition(
                    scale: Tween<double>(begin: 0.7, end: 1)
                        .animate(_markScale),
                    child: const SqFloat(child: SqLogoMark(size: 92)),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  const SqWordmark(fontSize: 38),
                  const SizedBox(height: 10),
                  Text(
                    'Endless AI quizzes. Real game energy.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: p.textSecondary,
                    ),
                  ),
                  const Spacer(flex: 4),
                  SizedBox(
                    width: 132,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadii.pill),
                      child: LinearProgressIndicator(
                        minHeight: 4,
                        backgroundColor: p.border.withValues(alpha: 0.6),
                        color: p.accent,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    'Warming up…',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: p.textFaint,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
