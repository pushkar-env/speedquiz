import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/exams/domain/exam_models.dart';

/// Renders a question's content blocks: prose, inline LaTeX, and figures.
///
/// Maths is rendered from LaTeX rather than shipped as pictures of formulae.
/// Pictures would cost dark-mode support, reflow at the reader's text size,
/// screen-reader access, search, and roughly ten times the bytes — all of which
/// matter more on a 360dp phone than the convenience of not parsing anything.
///
/// Figures are the opposite case: a circuit or a free-body diagram genuinely is
/// a picture, so it ships as one, with a separate variant baked for each theme.
class ContentView extends StatelessWidget {
  const ContentView({
    super.key,
    required this.blocks,
    required this.figures,
    required this.assets,
    this.textStyle,
    this.spacing = 12,
  });

  /// The blocks to draw, in order.
  final List<ContentBlock> blocks;

  /// `ref` -> checksum for this question.
  final Map<String, String> figures;

  /// checksum -> asset for the whole paper.
  final Map<String, ExamAsset> assets;

  final TextStyle? textStyle;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final style =
        textStyle ??
        Theme.of(context).textTheme.bodyLarge!.copyWith(height: 1.5);

    final children = <Widget>[];
    for (final block in blocks) {
      switch (block) {
        case TextBlock(:final text) when text.trim().isNotEmpty:
          children.add(_MathText(text: text, style: style));
        case FigureBlock(:final ref):
          final asset = assets[figures[ref]];
          if (asset != null) children.add(_Figure(asset: asset));
        case _:
          break;
      }
    }

    if (children.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) SizedBox(height: spacing),
          children[i],
        ],
      ],
    );
  }
}

/// Prose with `$...$` maths spans, laid out as one flowing paragraph.
///
/// The spans go through `Text.rich` so a formula wraps with the sentence around
/// it instead of forcing its own line — which is what keeps a long stem
/// readable on a narrow screen.
class _MathText extends StatelessWidget {
  const _MathText({required this.text, required this.style});

  final String text;
  final TextStyle style;

  /// Splits on unescaped `$`. An escaped `\$` is a literal dollar sign — real
  /// in chemistry and economics questions — and must not open a maths span.
  static final _delimiter = RegExp(r'(?<!\\)\$');

  /// `\(..\)`, `\[..\]` and `$$..$$` all mean the same thing as `$..$`.
  ///
  /// Content is canonicalised to `$` on the way into the database, so this is
  /// belt and braces — but it is the difference between a formula and a line
  /// of visible LaTeX source if anything ever slips through, and a reader
  /// cannot work around it.
  static final _altDelimiters = [
    RegExp(r'\\\((.*?)\\\)', dotAll: true),
    RegExp(r'\\\[(.*?)\\\]', dotAll: true),
    RegExp(r'\$\$(.+?)\$\$', dotAll: true),
  ];

  static String _canonicalize(String raw) {
    var out = raw;
    for (final pattern in _altDelimiters) {
      out = out.replaceAllMapped(pattern, (m) {
        final body = (m.group(1) ?? '').trim();
        return body.isEmpty ? '' : '\$$body\$';
      });
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final text = _canonicalize(this.text);
    final pieces = text.split(_delimiter);
    if (pieces.length < 3) {
      // No complete maths span. Unescape and render as plain prose.
      return Text(text.replaceAll(r'\$', r'$'), style: style);
    }

    final spans = <InlineSpan>[];
    for (var i = 0; i < pieces.length; i++) {
      final piece = pieces[i];
      if (piece.isEmpty) continue;

      // Odd indices sit between delimiters, so they are the maths.
      if (i.isOdd) {
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            baseline: TextBaseline.alphabetic,
            child: Math.tex(
              piece,
              textStyle: style,
              mathStyle: MathStyle.text,
              // No renderer covers all of LaTeX. Rather than an error box in
              // the middle of a question, fall back to the source — a student
              // can still read `\frac{13}{32}MR^2` and answer.
              onErrorFallback: (_) => Text(piece, style: style),
            ),
          ),
        );
      } else {
        spans.add(TextSpan(text: piece.replaceAll(r'\$', r'$')));
      }
    }

    return Text.rich(TextSpan(children: spans), style: style);
  }
}

/// One diagram, in the variant that suits the current theme.
class _Figure extends StatelessWidget {
  const _Figure({required this.asset});

  final ExamAsset asset;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final url = dark ? asset.darkUrl : asset.lightUrl;
    if (url.isEmpty) return const SizedBox.shrink();

    final palette = context.sq;

    return Semantics(
      label: asset.altText ?? 'Figure',
      image: true,
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          // Cap the height so a tall figure cannot push the options off screen,
          // and the width so a small diagram is not stretched into mush.
          constraints: const BoxConstraints(maxHeight: 280, maxWidth: 520),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: AspectRatio(
              aspectRatio: asset.aspectRatio,
              child: CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.contain,
                // The URL is a content hash, so the bytes behind it can never
                // change and the cache never needs invalidating.
                placeholder: (context, _) => Container(
                  color: palette.surfaceElevated,
                  child: const Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ),
                errorWidget: (context, _, _) => Container(
                  color: palette.surfaceElevated,
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.image_not_supported_outlined,
                        size: 18,
                        color: palette.textSecondary,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          'Diagram unavailable',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: palette.textSecondary),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
