import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/exams/data/exam_repository.dart';
import 'package:speedquiz/features/exams/domain/exam_models.dart';
import 'package:speedquiz/features/exams/presentation/mock_test_controller.dart';
import 'package:speedquiz/features/exams/presentation/widgets/content_view.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// Colours of the official CBT answer palette.
///
/// Mirrored exactly rather than restyled: candidates have drilled against this
/// palette for two years, and a green square that means something else here
/// would be a real cost during a timed paper.
class PaletteColors {
  static const answered = Color(0xFF1A7F4B);
  static const notAnswered = Color(0xFFC0392B);
  static const marked = Color(0xFF6B3FA0);
  static const notVisited = Color(0xFF8A94A6);

  static Color of(ResponseState state) => switch (state) {
    ResponseState.answered => answered,
    ResponseState.answeredAndMarked => marked,
    ResponseState.marked => marked,
    ResponseState.notAnswered => notAnswered,
    ResponseState.notVisited => notVisited,
  };
}

/// Loads the paper and starts (or resumes) the attempt, then hands off.
class MockTestScreen extends ConsumerStatefulWidget {
  const MockTestScreen({super.key, required this.paperId});

  final String paperId;

  @override
  ConsumerState<MockTestScreen> createState() => _MockTestScreenState();
}

class _MockTestScreenState extends ConsumerState<MockTestScreen> {
  Future<(PaperManifest, MockAttempt)>? _boot;

  @override
  void initState() {
    super.initState();
    _boot = _start();
  }

  Future<(PaperManifest, MockAttempt)> _start() async {
    final repository = ref.read(examRepositoryProvider);
    // Manifest first: the paper has to be in hand before the clock starts, or
    // a slow network eats into the candidate's time.
    final manifest = await repository.fetchManifest(widget.paperId);
    final attempt = await repository.startAttempt(widget.paperId);
    return (manifest, attempt);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<(PaperManifest, MockAttempt)>(
      future: _boot,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
            appBar: AppBar(),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Could not open this paper.',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    SqButton(
                      label: 'Try again',
                      expand: false,
                      onPressed: () => setState(() => _boot = _start()),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Downloading the paper…'),
                ],
              ),
            ),
          );
        }
        final (manifest, attempt) = snapshot.data!;
        return _MockTestRunner(manifest: manifest, attempt: attempt);
      },
    );
  }
}

class _MockTestRunner extends ConsumerStatefulWidget {
  const _MockTestRunner({required this.manifest, required this.attempt});

  final PaperManifest manifest;
  final MockAttempt attempt;

  @override
  ConsumerState<_MockTestRunner> createState() => _MockTestRunnerState();
}

class _MockTestRunnerState extends ConsumerState<_MockTestRunner> {
  late final MockTestController _controller;
  late final RemoveListener _unsubscribe;
  late MockTestState _state;
  final _numericController = TextEditingController();
  String? _numericFor;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller = MockTestController(
      ref.read(examRepositoryProvider),
      manifest: widget.manifest,
      attempt: widget.attempt,
    )..onTimeExpired = _onTimeExpired;
    // The controller is scoped to this screen rather than to a provider: it
    // needs the manifest and the attempt as constructor arguments, and a
    // family key over two large objects buys nothing here. `addListener`
    // fires immediately, which is what seeds `_state`.
    _unsubscribe = _controller.addListener((next) {
      if (mounted) setState(() => _state = next);
    });
  }

  @override
  void dispose() {
    _unsubscribe();
    _controller.dispose();
    _numericController.dispose();
    super.dispose();
  }

  Future<void> _onTimeExpired() async {
    if (_closing || !mounted) return;
    _closing = true;
    // The server has already closed the attempt; asking it to submit just
    // fetches the score.
    await _finish(showConfirm: false);
  }

  Future<void> _finish({bool showConfirm = true}) async {
    if (showConfirm) {
      final unanswered =
          _state.manifest.questions.length - _state.answeredCount;
      final confirmed = await showSqConfirm(
        context,
        title: 'Submit the paper?',
        message: unanswered > 0
            ? '$unanswered question${unanswered == 1 ? '' : 's'} still '
                  'unanswered. You cannot come back to them after submitting.'
            : 'All questions answered. Ready to submit?',
        confirmLabel: 'Submit',
        cancelLabel: 'Keep going',
      );
      if (!confirmed || !mounted) return;
    }

    try {
      final result = await _controller.submit();
      if (!mounted) return;
      context.pushReplacement(Routes.mockResultPath(result.attempt.id));
    } catch (_) {
      if (!mounted) return;
      SqToast.error(
        context,
        'Could not submit. Your answers are saved — try again.',
      );
    }
  }

  void _syncNumericField(MockTestState state) {
    final question = state.question;
    if (!question.answerType.isNumeric) return;
    if (_numericFor == question.id) return;
    _numericFor = question.id;
    _numericController.text = state.current.numericRaw ?? '';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Leaving mid-paper must be deliberate: the clock keeps running whether
      // the screen is open or not.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        // Captured before the await: after it, this closure's `context` may
        // belong to a widget that is already gone, and the State's `mounted`
        // flag says nothing about it.
        final router = GoRouter.of(context);
        final leave = await showSqConfirm(
          context,
          title: 'Leave the test?',
          message:
              'The timer keeps running. Your answers are saved and you '
              'can come back before time runs out.',
          confirmLabel: 'Leave',
          cancelLabel: 'Stay',
          tone: SqDialogTone.warning,
        );
        if (!leave) return;
        await _controller.flush();
        if (!mounted) return;
        router.pop();
      },
      child: Builder(
        builder: (context) {
          _syncNumericField(_state);
          return Scaffold(
            appBar: _TestAppBar(
              state: _state,
              onPalette: () => _openPalette(_state),
              onSubmit: _finish,
            ),
            body: Column(
              children: [
                if (_state.lastSyncError != null)
                  _OfflineBanner(message: _state.lastSyncError!),
                Expanded(
                  child: _QuestionPane(
                    state: _state,
                    controller: _controller,
                    numericController: _numericController,
                  ),
                ),
                _BottomBar(state: _state, controller: _controller),
              ],
            ),
          );
        },
      ),
    );
  }

  void _openPalette(MockTestState state) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _PaletteSheet(
        state: state,
        onSelect: (index) {
          Navigator.of(sheetContext).pop();
          _controller.goTo(index);
        },
      ),
    );
  }
}

class _TestAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _TestAppBar({
    required this.state,
    required this.onPalette,
    required this.onSubmit,
  });

  final MockTestState state;
  final VoidCallback onPalette;
  final VoidCallback onSubmit;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final remaining = state.remaining;
    // Under five minutes the clock turns red. It is the only alarming colour
    // on this screen, which is what makes it register.
    final critical = remaining.inMinutes < 5;
    final palette = context.sq;

    String two(int value) => value.toString().padLeft(2, '0');
    final clock = remaining.inHours > 0
        ? '${remaining.inHours}:${two(remaining.inMinutes % 60)}:${two(remaining.inSeconds % 60)}'
        : '${two(remaining.inMinutes)}:${two(remaining.inSeconds % 60)}';

    return AppBar(
      title: Row(
        children: [
          Icon(
            Icons.timer_outlined,
            size: 18,
            color: critical ? PaletteColors.notAnswered : palette.textSecondary,
          ),
          const SizedBox(width: 6),
          Text(
            clock,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
              fontWeight: FontWeight.w700,
              color: critical ? PaletteColors.notAnswered : null,
            ),
          ),
          const SizedBox(width: 12),
          if (state.pendingSync > 0)
            Icon(
              Icons.cloud_upload_outlined,
              size: 15,
              color: palette.textFaint,
            ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: 'Question palette',
          icon: const Icon(Icons.grid_view_rounded),
          onPressed: onPalette,
        ),
        TextButton(onPressed: onSubmit, child: const Text('Submit')),
        const SizedBox(width: 4),
      ],
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: const Color(0xFF9A6410).withValues(alpha: 0.14),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.cloud_off_outlined, size: 15),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

class _QuestionPane extends StatelessWidget {
  const _QuestionPane({
    required this.state,
    required this.controller,
    required this.numericController,
  });

  final MockTestState state;
  final MockTestController controller;
  final TextEditingController numericController;

  @override
  Widget build(BuildContext context) {
    final question = state.question;
    final response = state.current;
    final palette = context.sq;
    final section = state.manifest.sectionOf(question);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        Row(
          children: [
            Text(
              'Question ${question.number}',
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(color: palette.accent),
            ),
            const Spacer(),
            Text(
              '+${question.marks.toStringAsFixed(0)} / '
              '${question.negativeMarks.toStringAsFixed(0)}',
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: palette.textSecondary),
            ),
          ],
        ),
        if (section != null) ...[
          const SizedBox(height: 2),
          Text(
            section.name,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: palette.textFaint),
          ),
        ],
        const SizedBox(height: 16),
        ContentView(
          blocks: question.stem,
          figures: question.figures,
          assets: state.manifest.assets,
        ),
        const SizedBox(height: 24),
        if (question.answerType.isNumeric)
          _NumericField(
            question: question,
            controller: numericController,
            onChanged: controller.setNumeric,
          )
        else
          ...List.generate(question.optionCount, (index) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _OptionTile(
                index: index,
                question: question,
                assets: state.manifest.assets,
                selected: response.selected.contains(index),
                onTap: () => controller.selectOption(index),
              ),
            );
          }),
      ],
    );
  }
}

class _NumericField extends StatelessWidget {
  const _NumericField({
    required this.question,
    required this.controller,
    required this.onChanged,
  });

  final ExamQuestion question;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      keyboardType: const TextInputType.numberWithOptions(
        decimal: true,
        signed: true,
      ),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'^-?\d*\.?\d*')),
      ],
      style: Theme.of(context).textTheme.headlineSmall,
      decoration: InputDecoration(
        labelText: 'Your answer',
        suffixText: question.unit,
        border: const OutlineInputBorder(),
        helperText: 'Numeric entry — no options for this question',
      ),
    );
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.index,
    required this.question,
    required this.assets,
    required this.selected,
    required this.onTap,
  });

  final int index;
  final ExamQuestion question;
  final Map<String, ExamAsset> assets;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.sq;
    final blocks = index < question.options.length
        ? question.options[index]
        : null;
    final fallback = index < question.optionText.length
        ? question.optionText[index]
        : '';

    return Material(
      color: selected ? palette.accentWash(0.16) : palette.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? palette.accent : palette.border,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected ? palette.accent : Colors.transparent,
                  border: Border.all(
                    color: selected ? palette.accent : palette.borderStrong,
                  ),
                ),
                child: Text(
                  '${index + 1}',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: selected
                        ? palette.background
                        : palette.textSecondary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: (blocks != null && blocks.isNotEmpty)
                    ? ContentView(
                        blocks: blocks,
                        figures: question.figures,
                        assets: assets,
                        spacing: 8,
                      )
                    : Text(fallback),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.state, required this.controller});

  final MockTestState state;
  final MockTestController controller;

  @override
  Widget build(BuildContext context) {
    final palette = context.sq;
    final marked = state.current.state.isMarked;

    return Container(
      padding: EdgeInsets.fromLTRB(
        12,
        10,
        12,
        10 + MediaQuery.paddingOf(context).bottom,
      ),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(top: BorderSide(color: palette.border)),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Previous',
            onPressed: state.index > 0 ? controller.previous : null,
            icon: const Icon(Icons.chevron_left),
          ),
          IconButton(
            tooltip: marked ? 'Unmark' : 'Mark for review',
            onPressed: controller.toggleMark,
            icon: Icon(
              marked ? Icons.bookmark : Icons.bookmark_outline,
              color: marked ? PaletteColors.marked : null,
            ),
          ),
          IconButton(
            tooltip: 'Clear response',
            onPressed: state.current.hasAnswer
                ? controller.clearResponse
                : null,
            icon: const Icon(Icons.backspace_outlined),
          ),
          const Spacer(),
          SqButton(
            label: state.isLastQuestion ? 'Last question' : 'Save & Next',
            expand: false,
            height: 46,
            onPressed: state.isLastQuestion ? null : controller.next,
          ),
        ],
      ),
    );
  }
}

/// The full question grid, colour-coded by state.
class _PaletteSheet extends StatelessWidget {
  const _PaletteSheet({required this.state, required this.onSelect});

  final MockTestState state;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final questions = state.manifest.questions;
    final palette = context.sq;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.92,
      builder: (context, scrollController) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Text(
                  'Questions',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                Text(
                  '${state.answeredCount} answered',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: palette.textSecondary),
                ),
              ],
            ),
          ),
          const _PaletteLegend(),
          const Divider(height: 20),
          Expanded(
            child: GridView.builder(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 56,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              ),
              itemCount: questions.length,
              itemBuilder: (context, index) {
                final question = questions[index];
                final response = state.responseFor(question.id);
                final color = PaletteColors.of(response.state);
                final current = index == state.index;

                return Material(
                  color: response.state == ResponseState.notVisited
                      ? palette.surfaceElevated
                      : color,
                  borderRadius: BorderRadius.circular(8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => onSelect(index),
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: current
                            ? Border.all(color: palette.textPrimary, width: 2)
                            : null,
                      ),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Text(
                            '${question.number}',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: response.state == ResponseState.notVisited
                                  ? palette.textSecondary
                                  : Colors.white,
                            ),
                          ),
                          // Answered-and-marked is purple with a green dot on
                          // the real interface. Same here.
                          if (response.state == ResponseState.answeredAndMarked)
                            const Positioned(
                              right: 4,
                              bottom: 4,
                              child: CircleAvatar(
                                radius: 4,
                                backgroundColor: PaletteColors.answered,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _PaletteLegend extends StatelessWidget {
  const _PaletteLegend();

  @override
  Widget build(BuildContext context) {
    const items = [
      ('Answered', PaletteColors.answered),
      ('Not answered', PaletteColors.notAnswered),
      ('Marked', PaletteColors.marked),
      ('Not visited', PaletteColors.notVisited),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Wrap(
        spacing: 14,
        runSpacing: 6,
        children: [
          for (final (label, color) in items)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 11,
                  height: 11,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 5),
                Text(label, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
        ],
      ),
    );
  }
}
