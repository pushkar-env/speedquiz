import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/shared/widgets/sq_flame.dart';

/// The flame is drawn, not composed from widgets, so the thing worth testing
/// is the silhouette itself. The bug this guards against is a body that fills
/// only half its box — at the 15px streak chip that renders as a thin candle
/// wick rather than fire, which no "widget exists" assertion would catch.
void main() {
  group('silhouette', () {
    const box = Size(100, 118); // The widget's own 1 : 1.18 aspect.

    test('fills its box horizontally across the whole flicker cycle', () {
      for (var i = 0; i <= 10; i++) {
        final phase = i / 10;
        final bounds = debugFlameSilhouette(box, phase: phase).getBounds();
        expect(
          bounds.width / box.width,
          greaterThan(0.8),
          reason: 'too narrow at phase $phase '
              '(${(bounds.width / box.width).toStringAsFixed(2)} of the box)',
        );
      }
    });

    test('stays taller than it is wide, so it still reads as a flame', () {
      final bounds = debugFlameSilhouette(box).getBounds();
      expect(bounds.height, greaterThan(bounds.width));
    });

    test('reaches the base of the box', () {
      final bounds = debugFlameSilhouette(box).getBounds();
      // Bottom should sit at or below the base line, not float mid-box.
      expect(bounds.bottom, greaterThan(box.height * 0.9));
    });

    test('stays inside its box give or take the lean', () {
      for (var i = 0; i <= 10; i++) {
        final bounds = debugFlameSilhouette(box, phase: i / 10).getBounds();
        expect(bounds.left, greaterThan(-box.width * 0.12));
        expect(bounds.right, lessThan(box.width * 1.12));
      }
    });

    test('scales with the box rather than assuming a fixed size', () {
      final small = debugFlameSilhouette(const Size(15, 17.7)).getBounds();
      final large = debugFlameSilhouette(const Size(60, 70.8)).getBounds();
      expect(large.width / small.width, closeTo(4, 0.1));
    });
  });

  group('widget', () {
    testWidgets('a cold streak runs no ticker', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(
            body: Center(child: SqFlame(size: 15, alive: false)),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(SqFlame), findsOneWidget);
      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('reduce motion stops the flame ticking', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: const MediaQuery(
            data: MediaQueryData(disableAnimations: true),
            child: Scaffold(body: Center(child: SqFlame(size: 15))),
          ),
        ),
      );
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('a live streak animates', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(body: Center(child: SqFlame(size: 15))),
        ),
      );
      await tester.pump();
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      // Leave no ticker running into teardown.
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
