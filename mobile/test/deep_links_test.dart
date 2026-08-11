import 'package:flutter_test/flutter_test.dart';
import 'package:speedquiz/core/routing/deep_links.dart';

void main() {
  test('maps speedquiz://results/{id}', () {
    final loc = locationFromDeepLink(
      Uri.parse('speedquiz://results/abc-123'),
    );
    expect(loc, '/share/results/abc-123');
  });

  test('maps path-style speedquiz URI', () {
    final loc = locationFromDeepLink(
      Uri.parse('speedquiz:///results/abc-123'),
    );
    expect(loc, '/share/results/abc-123');
  });

  test('maps future https share path', () {
    final loc = locationFromDeepLink(
      Uri.parse('https://speedquiz.app/share/results/abc-123'),
    );
    expect(loc, '/share/results/abc-123');
  });

  test('maps public landing /r/{id}', () {
    final loc = locationFromDeepLink(
      Uri.parse('https://speedquiz.app/r/abc-123'),
    );
    expect(loc, '/share/results/abc-123');
  });

  test('ignores unrelated links', () {
    expect(locationFromDeepLink(Uri.parse('https://example.com/')), isNull);
  });
}
