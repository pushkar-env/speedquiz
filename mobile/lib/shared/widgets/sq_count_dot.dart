import 'package:flutter/material.dart';
import 'package:speedquiz/core/theme/app_theme.dart';

/// The "there is something here" marker.
///
/// One widget rather than the three near-identical private copies this app
/// grew — on the tab bar, on the inbox bell, and on the friends button. They
/// drifted by a pixel and a font weight each, which is exactly how a set of
/// badges stops reading as one system.
///
/// Counts are capped so a neglected inbox cannot widen the dot into whatever
/// it is pinned to. Above the cap it says "9+", because the difference between
/// twelve and forty unread is not a difference anyone acts on.
class SqCountDot extends StatelessWidget {
  const SqCountDot({
    super.key,
    required this.count,
    this.cap = 9,
    this.tint = AppColors.danger,
  });

  final int count;

  /// Above this, the label becomes "N+".
  final int cap;

  final Color tint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The ring is the page behind it, not a colour: it reads as the dot being
    // punched out of whatever it sits on, which is what keeps it legible over
    // an icon in either theme.
    final ring = theme.sq.background;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      constraints: const BoxConstraints(minWidth: 17),
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(AppRadii.pill),
        border: Border.all(color: ring, width: 1.6),
        boxShadow: AppShadows.glow(tint, strength: 0.35),
      ),
      child: Text(
        count > cap ? '$cap+' : '$count',
        textAlign: TextAlign.center,
        style: theme.textTheme.labelSmall?.copyWith(
          color: Colors.white,
          fontSize: 10,
          height: 1.2,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

/// Pins a [SqCountDot] to the top-right of [child], drawing nothing at zero.
///
/// The dot overhangs its anchor, so the anchor must not have to reserve room
/// for it — every use here is an icon in a row whose spacing was tuned without
/// one.
class SqBadged extends StatelessWidget {
  const SqBadged({
    super.key,
    required this.child,
    required this.count,
    this.cap = 9,
    this.offset = const Offset(-2, -2),
  });

  final Widget child;
  final int count;
  final int cap;

  /// Where the dot sits relative to the top-right corner.
  final Offset offset;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return child;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(
          right: offset.dx,
          top: offset.dy,
          child: SqCountDot(count: count, cap: cap),
        ),
      ],
    );
  }
}
