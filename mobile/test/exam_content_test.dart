import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speedquiz/core/config/app_config.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/exams/domain/exam_models.dart';
import 'package:speedquiz/features/exams/presentation/widgets/content_view.dart';

/// The renderer is where a correctly-ingested question can still become
/// unreadable, so these cover the shapes that actually occur in a paper:
/// prose with inline maths, a stem with a figure, and figure-only options.
Widget _host(Widget child, {Brightness brightness = Brightness.light}) {
  return MaterialApp(
    theme: brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

const _asset = ExamAsset(
  checksum: 'abc123',
  width: 240,
  height: 200,
  lightUrl: 'https://example.test/abc123.light.png',
  darkUrl: 'https://example.test/abc123.dark.png',
  altText: 'A disc with a circular section removed',
);

void main() {
  group('ContentBlock parsing', () {
    test('reads a text block', () {
      final block = ContentBlock.fromJson({'t': 'text', 'v': r'Let $x^2 = 4$'});
      expect(block, isA<TextBlock>());
      expect((block as TextBlock).text, r'Let $x^2 = 4$');
    });

    test('reads a figure block', () {
      final block = ContentBlock.fromJson({'t': 'figure', 'ref': 'fig1'});
      expect(block, isA<FigureBlock>());
      expect((block as FigureBlock).ref, 'fig1');
    });

    test('an unknown block type degrades to text rather than throwing', () {
      // A newer pipeline emitting a block this client does not know must not
      // take the whole question down with it.
      final block = ContentBlock.fromJson({'t': 'table', 'v': 'fallback'});
      expect(block, isA<TextBlock>());
    });

    test('listFrom tolerates a non-list', () {
      expect(ContentBlock.listFrom(null), isEmpty);
      expect(ContentBlock.listFrom('nope'), isEmpty);
    });
  });

  group('ExamAsset', () {
    test('falls back to the light variant when no dark one was baked', () {
      final asset = ExamAsset.fromJson({
        'checksum': 'x',
        'width': 100,
        'height': 50,
        'variants': {
          'light': {'url': 'https://example.test/x.light.png', 'bytes': 10},
        },
      });
      // Better a hard-to-read figure than a missing one.
      expect(asset.darkUrl, asset.lightUrl);
    });

    test('a relative url is joined to the API base', () {
      // The local asset store returns "/static/figures/..."; image loaders
      // need an absolute URL, and the failure is invisible until a real
      // device shows an empty box where the diagram should be.
      final asset = ExamAsset.fromJson({
        'checksum': 'x',
        'width': 10,
        'height': 10,
        'variants': {
          'light': {'url': '/static/figures/ab/abc.light.png'},
          'dark': {'url': '/static/figures/ab/abc.dark.png'},
        },
      });
      expect(asset.lightUrl, startsWith(AppConfig.apiBaseUrl));
      expect(asset.lightUrl, endsWith('/static/figures/ab/abc.light.png'));
      expect(Uri.parse(asset.lightUrl).hasScheme, isTrue);
    });

    test('an absolute url is left alone', () {
      // R2 returns a full URL on its own hostname; prefixing it would break it.
      const remote = 'https://figures.example.test/ab/abc.light.png';
      final asset = ExamAsset.fromJson({
        'checksum': 'x',
        'width': 10,
        'height': 10,
        'variants': {
          'light': {'url': remote},
        },
      });
      expect(asset.lightUrl, remote);
    });

    test('an empty url stays empty rather than becoming the bare base', () {
      expect(ExamAsset.resolveUrl(''), '');
    });

    test('aspect ratio survives a zero dimension', () {
      final asset = ExamAsset.fromJson({
        'checksum': 'x',
        'width': 0,
        'height': 0,
        'variants': const {},
      });
      expect(asset.aspectRatio, greaterThan(0));
    });
  });

  group('ContentView', () {
    testWidgets('renders prose around inline maths', (tester) async {
      await tester.pumpWidget(
        _host(
          const ContentView(
            blocks: [
              TextBlock(text: r'The value of $\frac{13}{32}MR^2$ is required.'),
            ],
            figures: {},
            assets: {},
          ),
        ),
      );

      // The prose survives as real text; the maths becomes a widget span, so
      // it is deliberately not asserted as a string.
      expect(find.textContaining('The value of'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('paren-delimited maths renders, not as source', (tester) async {
      // The reported bug: Q63 rendered its options as visible LaTeX source.
      // Content is canonicalised server-side now; this is the client's own
      // guard, and the failure it prevents is unreadable to a student.
      await tester.pumpWidget(
        _host(
          const ContentView(
            blocks: [TextBlock(text: r'Product is \( \text{CH}_3 - \text{CHO} \)')],
            figures: {},
            assets: {},
          ),
        ),
      );

      // The prose survives; nothing of the delimiter or the command does.
      expect(find.textContaining('Product is'), findsOneWidget);
      expect(find.textContaining(r'\('), findsNothing);
      expect(find.textContaining(r'\text{CH}'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an escaped dollar stays literal', (tester) async {
      await tester.pumpWidget(
        _host(
          const ContentView(
            blocks: [TextBlock(text: r'A price of \$40 per unit.')],
            figures: {},
            assets: {},
          ),
        ),
      );

      expect(find.text(r'A price of $40 per unit.'), findsOneWidget);
    });

    testWidgets('an unmatched dollar does not swallow the sentence', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const ContentView(
            blocks: [TextBlock(text: r'Cost is $40 and rising')],
            figures: {},
            assets: {},
          ),
        ),
      );

      expect(find.textContaining('Cost is'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('places a figure that resolves', (tester) async {
      await tester.pumpWidget(
        _host(
          const ContentView(
            blocks: [
              TextBlock(text: 'A uniform disc, as shown.'),
              FigureBlock(ref: 'fig1'),
            ],
            figures: {'fig1': 'abc123'},
            assets: {'abc123': _asset},
          ),
        ),
      );
      await tester.pump();

      expect(find.text('A uniform disc, as shown.'), findsOneWidget);
      expect(
        find.bySemanticsLabel('A disc with a circular section removed'),
        findsOneWidget,
      );
    });

    testWidgets('a dangling figure ref renders nothing rather than an error', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const ContentView(
            blocks: [
              TextBlock(text: 'Stem text.'),
              FigureBlock(ref: 'fig9'),
            ],
            figures: {},
            assets: {},
          ),
        ),
      );

      expect(find.text('Stem text.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('empty blocks collapse', (tester) async {
      await tester.pumpWidget(
        _host(const ContentView(blocks: [], figures: {}, assets: {})),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('lays out in dark theme', (tester) async {
      await tester.pumpWidget(
        _host(
          const ContentView(
            blocks: [
              TextBlock(text: r'Find $I$ for the remaining part.'),
              FigureBlock(ref: 'fig1'),
            ],
            figures: {'fig1': 'abc123'},
            assets: {'abc123': _asset},
          ),
          brightness: Brightness.dark,
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });

  group('QuestionResponse', () {
    test('a numeric zero counts as an answer', () {
      // 0 is a legitimate answer. A falsy check here would silently discard it.
      const response = QuestionResponse(examQuestionId: 'q1', numericValue: 0);
      expect(response.hasAnswer, isTrue);
    });

    test('marked without an answer is not answered', () {
      const response = QuestionResponse(
        examQuestionId: 'q1',
        state: ResponseState.marked,
      );
      expect(response.hasAnswer, isFalse);
      expect(response.state.isMarked, isTrue);
      expect(response.state.isAnswered, isFalse);
    });

    test('answered-and-marked reads as both', () {
      const response = QuestionResponse(
        examQuestionId: 'q1',
        state: ResponseState.answeredAndMarked,
        selected: [2],
      );
      expect(response.state.isAnswered, isTrue);
      expect(response.state.isMarked, isTrue);
    });

    test('clearNumeric wipes both the value and the raw text', () {
      const response = QuestionResponse(
        examQuestionId: 'q1',
        numericValue: 12.5,
        numericRaw: '12.5',
      );
      final cleared = response.copyWith(clearNumeric: true);
      expect(cleared.numericValue, isNull);
      expect(cleared.numericRaw, isNull);
    });
  });
}
