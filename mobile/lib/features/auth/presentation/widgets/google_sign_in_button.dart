import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/shared/widgets/sq_press.dart';
import 'package:speedquiz/shared/widgets/sq_shake.dart';

/// "Continue with Google" — white pill on both themes, matching the platform
/// convention users already recognise.
class GoogleSignInButton extends StatefulWidget {
  const GoogleSignInButton({
    super.key,
    required this.onPressed,
    this.label = 'Continue with Google',
    this.loading = false,
    this.height = 54,
  });

  final VoidCallback? onPressed;
  final String label;
  final bool loading;
  final double height;

  @override
  State<GoogleSignInButton> createState() => GoogleSignInButtonState();
}

class GoogleSignInButtonState extends State<GoogleSignInButton>
    with SingleTickerProviderStateMixin {
  late final ShakeController _shake = ShakeController(vsync: this);

  /// Shake to signal a rejected sign-in without stealing focus with a modal.
  void reject() => _shake.shake();

  @override
  void dispose() {
    _shake.dispose();
    super.dispose();
  }

  bool get _disabled => widget.loading || widget.onPressed == null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return SqShake(
      controller: _shake,
      child: SqPressable(
        enabled: !_disabled,
        haptic: false,
        pressedScale: 0.97,
        semanticLabel: widget.label,
        onTap: _disabled
            ? null
            : () {
                Haptics.press();
                widget.onPressed!.call();
              },
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 180),
          opacity: _disabled ? 0.6 : 1,
          child: Container(
            height: widget.height,
            width: double.infinity,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(AppRadii.md),
              border: Border.all(
                color: p.isDark ? Colors.transparent : const Color(0xFFDADCE0),
              ),
              boxShadow: p.isDark ? null : AppShadows.soft(p),
            ),
            child: widget.loading
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: Color(0xFF4285F4),
                    ),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const _GoogleGlyph(size: 20),
                      const SizedBox(width: 12),
                      Text(
                        widget.label,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: const Color(0xFF1F1F1F),
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// The Google "G", drawn as four arcs plus the crossbar so no image asset or
/// extra dependency is needed.
class _GoogleGlyph extends StatelessWidget {
  const _GoogleGlyph({this.size = 20});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: const _GoogleGlyphPainter()),
    );
  }
}

class _GoogleGlyphPainter extends CustomPainter {
  const _GoogleGlyphPainter();

  static const _blue = Color(0xFF4285F4);
  static const _green = Color(0xFF34A853);
  static const _yellow = Color(0xFFFBBC05);
  static const _red = Color(0xFFEA4335);

  static double _rad(double degrees) => degrees * math.pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.23;
    final rect = Rect.fromLTWH(0, 0, size.width, size.height)
        .deflate(stroke / 2);

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.butt;

    // 0deg is east, sweeps run clockwise: bottom -> left -> top -> right.
    canvas.drawArc(rect, _rad(5), _rad(130), false, paint..color = _green);
    canvas.drawArc(rect, _rad(135), _rad(80), false, paint..color = _yellow);
    canvas.drawArc(rect, _rad(215), _rad(95), false, paint..color = _red);
    canvas.drawArc(rect, _rad(310), _rad(55), false, paint..color = _blue);

    // Crossbar running from the centre out to the ring.
    final barTop = size.height / 2 - stroke / 2;
    canvas.drawRect(
      Rect.fromLTRB(size.width * 0.47, barTop, size.width, barTop + stroke),
      Paint()..color = _blue,
    );
  }

  @override
  bool shouldRepaint(_GoogleGlyphPainter oldDelegate) => false;
}
