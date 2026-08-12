import 'package:flutter/material.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/profile/domain/avatar_catalog.dart';

/// Player avatar.
///
/// When the player has picked an [avatarId] it renders that preset's gradient
/// and glyph. Otherwise it falls back to a gradient derived from [seed] so the
/// same player always looks the same across screens and devices.
class SqAvatar extends StatelessWidget {
  const SqAvatar({
    super.key,
    this.name,
    this.seed,
    this.avatarId,
    this.size = 44,
    this.ring = false,
    this.premium = false,
    this.showGlyph = true,
  });

  final String? name;

  /// Stable id used when no avatar has been chosen.
  final String? seed;

  /// Chosen avatar preset id (`avatar_id` on the server).
  final String? avatarId;
  final double size;
  final bool ring;
  final bool premium;

  /// When false, shows the name's initial instead of the preset glyph.
  final bool showGlyph;

  String get _initial {
    final source = (name ?? '').trim();
    if (source.isEmpty) return 'S';
    return source[0].toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final body = _buildAvatar(context);
    // The rotating gold ring is a Premium cosmetic. Honouring reduce-motion
    // is not optional here — it renders on every screen the player visits.
    if (!premium || !ring || MediaQuery.disableAnimationsOf(context)) {
      return body;
    }
    return _PremiumRing(size: size, child: body);
  }

  Widget _buildAvatar(BuildContext context) {
    final preset = AvatarCatalog.resolve(avatarId, seed: seed ?? name);
    final colors =
        premium ? AppColors.premiumGradient.colors : preset.colors;
    final ringColor = premium ? AppColors.gold : colors.first;

    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
        border: ring
            ? Border.all(color: ringColor.withValues(alpha: 0.45), width: 2)
            : null,
        boxShadow: [
          BoxShadow(
            color: colors.first.withValues(alpha: 0.32),
            blurRadius: size * 0.28,
            offset: Offset(0, size * 0.08),
          ),
        ],
      ),
      child: showGlyph && avatarId != null && avatarId!.isNotEmpty
          ? Text(
              preset.glyph,
              style: TextStyle(fontSize: size * 0.44, height: 1),
            )
          : Text(
              _initial,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontFamily: 'SpaceGrotesk',
                    color: const Color(0xFF071018),
                    fontWeight: FontWeight.w700,
                    fontSize: size * 0.42,
                    height: 1,
                  ),
            ),
    );
  }
}

/// A slowly rotating gradient ring, drawn behind a premium player's avatar.
class _PremiumRing extends StatefulWidget {
  const _PremiumRing({required this.size, required this.child});

  final double size;
  final Widget child;

  @override
  State<_PremiumRing> createState() => _PremiumRingState();
}

class _PremiumRingState extends State<_PremiumRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ringSize = widget.size + 8;

    return SizedBox(
      width: ringSize,
      height: ringSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          RepaintBoundary(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                return Transform.rotate(
                  angle: _controller.value * 2 * 3.1415926535,
                  child: Container(
                    width: ringSize,
                    height: ringSize,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: SweepGradient(
                        colors: [
                          AppColors.gold,
                          AppColors.gold.withValues(alpha: 0.15),
                          AppColors.magenta.withValues(alpha: 0.55),
                          AppColors.gold,
                        ],
                        stops: const [0.0, 0.35, 0.7, 1.0],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          widget.child,
        ],
      ),
    );
  }
}
