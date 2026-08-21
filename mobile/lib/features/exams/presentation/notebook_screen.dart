import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/exams/data/exam_repository.dart';
import 'package:speedquiz/features/exams/domain/exam_models.dart' as models;
import 'package:speedquiz/features/exams/presentation/mock_test_screen.dart'
    show PaletteColors;
import 'package:speedquiz/features/exams/presentation/widgets/content_view.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// Every question this student has got wrong, grouped by chapter.
///
/// The screen a serious candidate opens more than any other. A mock test tells
/// you how you did; this tells you what to do about it — so it leads with the
/// question and the worked solution, not with a score.
class NotebookScreen extends ConsumerStatefulWidget {
  const NotebookScreen({super.key});

  @override
  ConsumerState<NotebookScreen> createState() => _NotebookScreenState();
}

class _NotebookScreenState extends ConsumerState<NotebookScreen> {
  String _status = 'open';
  String? _chapter;

  @override
  Widget build(BuildContext context) {
    final notebook = ref.watch(notebookProvider(_status));
    final p = context.sq;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mistake notebook'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Row(
              children: [
                for (final entry in const [
                  ('open', 'To revise'),
                  ('recovered', 'Fixed'),
                  ('reviewed', 'Reviewed'),
                  ('all', 'All'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _FilterChip(
                      label: entry.$2,
                      selected: _status == entry.$1,
                      onTap: () {
                        Haptics.tap();
                        setState(() {
                          _status = entry.$1;
                          _chapter = null;
                        });
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      body: notebook.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Could not load your notebook.'),
                const SizedBox(height: 12),
                SqButton(
                  label: 'Try again',
                  expand: false,
                  onPressed: () => ref.invalidate(notebookProvider(_status)),
                ),
              ],
            ),
          ),
        ),
        data: (data) {
          if (data.isEmpty) {
            return SqEmptyState(
              icon: _status == 'open' ? '🎯' : '📓',
              title: _status == 'open'
                  ? 'Nothing to revise'
                  : 'Nothing here yet',
              message: _status == 'open'
                  ? 'Questions you get wrong in a mock test land here '
                        'automatically, with the worked solution.'
                  : 'Mistakes you have worked through will show up here.',
            );
          }

          final visible = _chapter == null
              ? data.items
              : data.items.where((e) => e.chapter == _chapter).toList();

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              if (data.chapters.length > 1) ...[
                SizedBox(
                  height: 34,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      _FilterChip(
                        label: 'All chapters',
                        selected: _chapter == null,
                        onTap: () => setState(() => _chapter = null),
                      ),
                      for (final chapter in data.chapters)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: _FilterChip(
                            label: '${chapter.name} · ${chapter.count}',
                            selected: _chapter == chapter.name,
                            onTap: () =>
                                setState(() => _chapter = chapter.name),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              Text(
                '${visible.length} question${visible.length == 1 ? '' : 's'}',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: p.textSecondary),
              ),
              const SizedBox(height: 10),
              for (final entry in visible)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _NotebookCard(
                    entry: entry,
                    assets: data.assets,
                    onReviewed: () => _setStatus(entry, 'reviewed'),
                    onReopen: () => _setStatus(entry, 'open'),
                    onDelete: () => _delete(entry),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _setStatus(models.NotebookEntry entry, String status) async {
    Haptics.tap();
    try {
      await ref
          .read(examRepositoryProvider)
          .setNotebookStatus(entry.id, status);
      ref.invalidate(notebookProvider(_status));
      ref.invalidate(notebookCountProvider);
    } catch (_) {
      if (mounted) SqToast.error(context, 'Could not update that.');
    }
  }

  Future<void> _delete(models.NotebookEntry entry) async {
    final confirmed = await showSqConfirm(
      context,
      title: 'Remove from notebook?',
      message: 'It will come back if you get the question wrong again.',
      confirmLabel: 'Remove',
    );
    if (!confirmed || !mounted) return;
    try {
      await ref.read(examRepositoryProvider).deleteNotebookEntry(entry.id);
      ref.invalidate(notebookProvider(_status));
      ref.invalidate(notebookCountProvider);
    } catch (_) {
      if (mounted) SqToast.error(context, 'Could not remove that.');
    }
  }
}

class _NotebookCard extends StatefulWidget {
  const _NotebookCard({
    required this.entry,
    required this.assets,
    required this.onReviewed,
    required this.onReopen,
    required this.onDelete,
  });

  final models.NotebookEntry entry;
  final Map<String, models.ExamAsset> assets;
  final VoidCallback onReviewed;
  final VoidCallback onReopen;
  final VoidCallback onDelete;

  @override
  State<_NotebookCard> createState() => _NotebookCardState();
}

class _NotebookCardState extends State<_NotebookCard> {
  /// Solutions start collapsed. The point of revision is to try the question
  /// again first — a card that opens with the answer showing is a card that
  /// never gets attempted.
  bool _showSolution = false;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final p = context.sq;
    final theme = Theme.of(context);

    return SqSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  entry.chapter,
                  style: theme.textTheme.labelLarge?.copyWith(color: p.accent),
                ),
              ),
              if (entry.wrongCount > 1)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: PaletteColors.notAnswered.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    'wrong ${entry.wrongCount}×',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: PaletteColors.notAnswered,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
          if (entry.source != null) ...[
            const SizedBox(height: 2),
            Text(
              entry.source!,
              style: theme.textTheme.bodySmall?.copyWith(color: p.textFaint),
            ),
          ],
          const SizedBox(height: 12),
          ContentView(
            blocks: entry.stem,
            figures: entry.figures,
            assets: widget.assets,
            textStyle: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
          ),
          const SizedBox(height: 14),

          if (entry.answerType.isNumeric)
            _AnswerRow(
              label: 'Correct answer',
              value: entry.correctValue?.toString() ?? '—',
              yours: entry.yourNumeric?.toString(),
            )
          else
            ...List.generate(entry.optionText.length, (index) {
              final isCorrect = index == entry.correctOptionIndex;
              final wasYours = entry.yourSelected.contains(index);
              if (!isCorrect && !wasYours) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _OptionRow(
                  index: index,
                  blocks: index < entry.options.length
                      ? entry.options[index]
                      : const [],
                  fallback: entry.optionText[index],
                  figures: entry.figures,
                  assets: widget.assets,
                  isCorrect: isCorrect,
                  wasYours: wasYours,
                ),
              );
            }),

          const SizedBox(height: 10),
          if (entry.solution.isNotEmpty) ...[
            InkWell(
              onTap: () => setState(() => _showSolution = !_showSolution),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(
                      _showSolution ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: p.accent,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _showSolution ? 'Hide solution' : 'Show solution',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: p.accent,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_showSolution)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 8),
                child: ContentView(
                  blocks: [models.TextBlock(text: entry.solution)],
                  figures: entry.figures,
                  assets: widget.assets,
                  textStyle: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
                ),
              ),
          ],

          const Divider(height: 20),
          Row(
            children: [
              if (entry.isOpen)
                TextButton.icon(
                  onPressed: widget.onReviewed,
                  icon: const Icon(Icons.check, size: 16),
                  label: const Text('Got it'),
                )
              else
                TextButton.icon(
                  onPressed: widget.onReopen,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Revise again'),
                ),
              const Spacer(),
              IconButton(
                tooltip: 'Remove',
                onPressed: widget.onDelete,
                icon: Icon(Icons.delete_outline, size: 18, color: p.textFaint),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.index,
    required this.blocks,
    required this.fallback,
    required this.figures,
    required this.assets,
    required this.isCorrect,
    required this.wasYours,
  });

  final int index;
  final List<models.ContentBlock> blocks;
  final String fallback;
  final Map<String, String> figures;
  final Map<String, models.ExamAsset> assets;
  final bool isCorrect;
  final bool wasYours;

  @override
  Widget build(BuildContext context) {
    final colour = isCorrect
        ? PaletteColors.answered
        : PaletteColors.notAnswered;
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colour.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isCorrect ? Icons.check_circle : Icons.cancel,
            size: 17,
            color: colour,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: blocks.isNotEmpty
                ? ContentView(
                    blocks: blocks,
                    figures: figures,
                    assets: assets,
                    spacing: 6,
                    textStyle: theme.textTheme.bodyMedium,
                  )
                : Text(fallback, style: theme.textTheme.bodyMedium),
          ),
          if (wasYours && !isCorrect)
            Text(
              'yours',
              style: theme.textTheme.labelSmall?.copyWith(color: colour),
            ),
        ],
      ),
    );
  }
}

class _AnswerRow extends StatelessWidget {
  const _AnswerRow({required this.label, required this.value, this.yours});

  final String label;
  final String value;
  final String? yours;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(Icons.check_circle, size: 17, color: PaletteColors.answered),
        const SizedBox(width: 10),
        Text('$label: ', style: theme.textTheme.bodyMedium),
        Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: PaletteColors.answered,
          ),
        ),
        if (yours != null) ...[
          const Spacer(),
          Text(
            'you: $yours',
            style: theme.textTheme.bodySmall?.copyWith(
              color: PaletteColors.notAnswered,
            ),
          ),
        ],
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.sq;
    return Material(
      color: selected ? p.accent : p.surface,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: selected ? p.accent : p.border),
          ),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: selected ? p.background : p.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
