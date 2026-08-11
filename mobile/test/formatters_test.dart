import 'package:flutter_test/flutter_test.dart';
import 'package:speedquiz/core/utils/formatters.dart';

void main() {
  group('formatScore', () {
    test('groups thousands', () {
      expect(formatScore(0), '0');
      expect(formatScore(999), '999');
      expect(formatScore(1000), '1,000');
      expect(formatScore(1234567), '1,234,567');
    });

    test('keeps the sign on negative scores', () {
      // Negative mode starts at 1000 and can go below zero.
      expect(formatScore(-1500), '-1,500');
    });
  });

  group('formatCompact', () {
    test('abbreviates large values', () {
      expect(formatCompact(999), '999');
      expect(formatCompact(1200), '1.2K');
      expect(formatCompact(1000), '1K');
      expect(formatCompact(1500000), '1.5M');
    });
  });

  test('xpThresholdForLevel mirrors the server curve', () {
    expect(xpThresholdForLevel(0), 500);
    expect(xpThresholdForLevel(1), 500);
    expect(xpThresholdForLevel(4), 2000);
  });

  test('humanizeMode turns snake_case into title case', () {
    expect(humanizeMode('sudden_death'), 'Sudden Death');
    expect(humanizeMode('casual'), 'Casual');
  });

  test('achievementGlyph falls back to a trophy', () {
    expect(achievementGlyph('fire'), '🔥');
    expect(achievementGlyph('not_a_real_icon'), '🏆');
  });
}
