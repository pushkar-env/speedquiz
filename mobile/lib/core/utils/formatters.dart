/// Group a score with thousands separators: `12345` -> `12,345`.
String formatScore(int score) {
  final s = score.abs().toString();
  final buf = StringBuffer(score < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    buf.write(s[i]);
    final remaining = s.length - i - 1;
    if (remaining > 0 && remaining % 3 == 0) buf.write(',');
  }
  return buf.toString();
}

/// Compact form for tight spaces: `1200` -> `1.2K`, `1500000` -> `1.5M`.
String formatCompact(int value) {
  final abs = value.abs();
  if (abs < 1000) return '$value';
  if (abs < 1000000) {
    final k = value / 1000;
    return '${_trim(k)}K';
  }
  final m = value / 1000000;
  return '${_trim(m)}M';
}

String _trim(double value) {
  final fixed = value.toStringAsFixed(1);
  return fixed.endsWith('.0') ? fixed.substring(0, fixed.length - 2) : fixed;
}

/// XP required to advance out of [level]. Mirrors the server curve.
int xpThresholdForLevel(int level) => level < 1 ? 500 : level * 500;

/// Emoji for a server-side achievement icon key.
String achievementGlyph(String icon) {
  switch (icon) {
    case 'flag':
      return '🏁';
    case 'check':
      return '✅';
    case 'fire':
      return '🔥';
    case 'bolt':
      return '⚡';
    case 'brain':
      return '🧠';
    case 'infinity':
      return '∞';
    case 'star':
      return '⭐';
    case 'calendar':
      return '📅';
    case 'planet':
      return '🪐';
    case 'sigma':
      return '∑';
    case 'robot':
      return '🤖';
    default:
      return '🏆';
  }
}

/// `sudden_death` -> `Sudden Death`.
String humanizeMode(String mode) {
  return mode
      .split('_')
      .where((part) => part.isNotEmpty)
      .map((part) => part[0].toUpperCase() + part.substring(1))
      .join(' ');
}
