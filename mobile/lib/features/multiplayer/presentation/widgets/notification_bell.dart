import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/theme/app_motion.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/multiplayer/presentation/multiplayer_providers.dart';
import 'package:speedquiz/shared/widgets/sq_count_dot.dart';
import 'package:speedquiz/shared/widgets/sq_press.dart';

/// The inbox bell, on Home.
///
/// It sits on the first screen rather than inside Battle because the inbox is
/// not a battle feature: a friend request, an accepted request and a finished
/// match all land in it, and putting the only way to reach them one tab deep
/// meant a player had to already suspect there was something to see.
///
/// Unread is drawn three ways at once — accent fill, a counted dot, and a ring
/// that keeps breathing — because any one of them alone is something a player
/// glancing at Home on the way to Play does not register.
class NotificationBell extends ConsumerWidget {
  const NotificationBell({super.key, this.size = 48});

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Selected down to the count: the summary also carries the online-friend
    // set, which churns on its own schedule and would otherwise rebuild — and
    // restart the pulse of — a bell whose number never changed.
    final unread = ref.watch(
      socialSummaryProvider.select(
        (summary) => summary.valueOrNull?.unreadNotifications ?? 0,
      ),
    );

    return _Bell(
      unread: unread,
      size: size,
      onTap: () {
        Haptics.tap();
        context.push(Routes.notifications);
      },
    );
  }
}

class _Bell extends StatefulWidget {
  const _Bell({
    required this.unread,
    required this.size,
    required this.onTap,
  });

  final int unread;
  final double size;
  final VoidCallback onTap;

  @override
  State<_Bell> createState() => _BellState();
}

class _BellState extends State<_Bell> with TickerProviderStateMixin {
  /// The ambient ring. Runs only while something is unread — an idle bell
  /// animating forever is a battery cost with nothing to say.
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1900),
  );

  /// A one-shot swing for the moment a notification *arrives* while the player
  /// is looking at Home. The steady ring says "there is something here"; this
  /// says "something just happened", which is a different message.
  late final AnimationController _swing = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 720),
  );

  @override
  void initState() {
    super.initState();
    if (widget.unread > 0) _pulse.repeat();
  }

  @override
  void didUpdateWidget(_Bell old) {
    super.didUpdateWidget(old);
    if (old.unread == widget.unread) return;

    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (widget.unread > 0 && !_pulse.isAnimating && !reduceMotion) {
      _pulse.repeat();
    } else if (widget.unread == 0) {
      _pulse
        ..stop()
        ..value = 0;
    }
    // Only on the way up. Reading the inbox drops the count to zero, and a
    // bell that swings because you just cleared it is noise.
    if (widget.unread > old.unread && !reduceMotion) {
      _swing.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    _swing.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.sq;
    final l10n = context.l10n;
    final active = widget.unread > 0;
    final animate = active && !MediaQuery.disableAnimationsOf(context);
    final size = widget.size;

    // The ring is painted outside the button's own box, so this is wrapped in
    // a RepaintBoundary rather than being allowed to dirty the header it sits
    // in on every frame of the pulse.
    return RepaintBoundary(
      child: SqPressable(
        onTap: widget.onTap,
        pressedScale: 0.9,
        semanticLabel: active
            ? l10n.notificationsUnread(widget.unread)
            : l10n.notificationsTitle,
        child: SizedBox(
          width: size,
          height: size,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              if (animate)
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedBuilder(
                      animation: _pulse,
                      builder: (context, _) {
                        final t = Curves.easeOut.transform(_pulse.value);
                        return Transform.scale(
                          scale: 1 + t * 0.42,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: p.accent
                                    .withValues(alpha: 0.45 * (1 - t)),
                                width: 1.6,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              AnimatedContainer(
                duration: AppMotion.normal,
                curve: AppMotion.enter,
                width: size,
                height: size,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: active
                      ? p.accentWash(p.isDark ? 0.22 : 0.14)
                      : p.surface.withValues(alpha: p.isDark ? 0.7 : 0.9),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: active ? p.accent.withValues(alpha: 0.55) : p.border,
                    width: active ? 1.4 : 1,
                  ),
                  boxShadow: active
                      ? AppShadows.glow(p.accent, strength: 0.22)
                      : AppShadows.soft(p),
                ),
                child: _Swing(
                  animation: _swing,
                  child: Icon(
                    active
                        ? Icons.notifications_active_rounded
                        : Icons.notifications_none_rounded,
                    size: size * 0.46,
                    color: active ? p.accent : p.textSecondary,
                  ),
                ),
              ),
              if (active)
                Positioned(
                  right: -2,
                  top: -2,
                  child: SqCountDot(count: widget.unread),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Rocks the bell about its top edge, the way one hangs from a yoke.
class _Swing extends StatelessWidget {
  const _Swing({required this.animation, required this.child});

  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final t = animation.value;
        if (t == 0) return child!;
        // Three swings, decaying to nothing. The damping is what keeps it from
        // reading as a spinner.
        final angle = 0.34 * (1 - t) * math.sin(t * 3 * 2 * math.pi);
        return Transform.rotate(
          angle: angle,
          alignment: Alignment.topCenter,
          child: child,
        );
      },
      child: child,
    );
  }
}
