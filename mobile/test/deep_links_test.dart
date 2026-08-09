import 'package:flutter_test/flutter_test.dart';
import 'package:quizverse/core/routing/deep_links.dart';

void main() {
  test('maps quizverse://results/{id}', () {
    final loc = locationFromDeepLink(
      Uri.parse('quizverse://results/abc-123'),
    );
    expect(loc, '/share/results/abc-123');
  });

  test('maps path-style quizverse URI', () {
    final loc = locationFromDeepLink(
      Uri.parse('quizverse:///results/abc-123'),
    );
    expect(loc, '/share/results/abc-123');
  });

  test('maps future https share path', () {
    final loc = locationFromDeepLink(
      Uri.parse('https://quizverse.app/share/results/abc-123'),
    );
    expect(loc, '/share/results/abc-123');
  });

  test('maps public landing /r/{id}', () {
    final loc = locationFromDeepLink(
      Uri.parse('https://quizverse.app/r/abc-123'),
    );
    expect(loc, '/share/results/abc-123');
  });

  test('ignores unrelated links', () {
    expect(locationFromDeepLink(Uri.parse('https://example.com/')), isNull);
  });
}
