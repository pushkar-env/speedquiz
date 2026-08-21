import 'package:flutter/material.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/exams/domain/exam_models.dart';
import 'package:speedquiz/features/exams/domain/test_mode.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// Choose how to sit the paper, before the clock starts.
///
/// Deliberately a decision the student makes rather than a setting buried in
/// preferences: the same paper is a three-hour rehearsal, a twenty-minute
/// sectional drill, or an unhurried walk through the solutions, and which one
/// it is changes everything about the run.
Future<TestSetup?> showTestSetupSheet(
  BuildContext context, {
  required ExamPaper paper,
  List<ExamSection> sections = const [],
}) {
  return showModalBottomSheet<TestSetup>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) =>
        _TestSetupSheet(paper: paper, sections: sections),
  );
}

class _TestSetupSheet extends StatefulWidget {
  const _TestSetupSheet({required this.paper, required this.sections});

  final ExamPaper paper;
  final List<ExamSection> sections;

  @override
  State<_TestSetupSheet> createState() => _TestSetupSheetState();
}

class _TestSetupSheetState extends State<_TestSetupSheet> {
  late TestSetup _setup = TestSetup.defaults(
    paperDurationMinutes: widget.paper.durationMinutes,
  );

  /// Offered durations, anchored on the paper's own. A student rehearsing for
  /// the real thing wants the real length; a student with a lunch break wants
  /// thirty minutes, and both are legitimate.
  List<int> get _durationChoices {
    final full = widget.paper.durationMinutes;
    final choices = <int>{
      15,
      30,
      45,
      60,
      full ~/ 2,
      full,
    }.where((m) => m >= 5 && m <= 360).toList()..sort();
    return choices;
  }

  int get _questionCount {
    if (_setup.mode == TestMode.sectional && _setup.sectionId != null) {
      for (final section in widget.sections) {
        if (section.id == _setup.sectionId) return section.questionCount;
      }
    }
    return widget.paper.questionCount;
  }

  void _set(TestSetup next) {
    Haptics.tap();
    setState(() => _setup = next);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.sq;
    final theme = Theme.of(context);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.82,
      maxChildSize: 0.94,
      builder: (context, scrollController) => Column(
        children: [
          Expanded(
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              children: [
                Text(widget.paper.title, style: theme.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  '${widget.paper.questionCount} questions · '
                  '${widget.paper.totalMarks.toStringAsFixed(0)} marks',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: palette.textSecondary,
                  ),
                ),
                const SizedBox(height: 22),

                _Label('Mode'),
                const SizedBox(height: 8),
                for (final mode in TestMode.values)
                  if (mode != TestMode.sectional || widget.sections.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _ChoiceCard(
                        title: mode.label,
                        blurb: mode.blurb,
                        selected: _setup.mode == mode,
                        onTap: () => _set(
                          _setup.copyWith(
                            mode: mode,
                            clearSection: mode != TestMode.sectional,
                            sectionId: mode == TestMode.sectional
                                ? (_setup.sectionId ?? widget.sections.first.id)
                                : null,
                          ),
                        ),
                      ),
                    ),

                if (_setup.mode == TestMode.sectional) ...[
                  const SizedBox(height: 14),
                  _Label('Section'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final section in widget.sections)
                        _Chip(
                          label: section.name,
                          selected: _setup.sectionId == section.id,
                          onTap: () =>
                              _set(_setup.copyWith(sectionId: section.id)),
                        ),
                    ],
                  ),
                ],

                const SizedBox(height: 22),
                _Label('Pacing'),
                const SizedBox(height: 8),
                for (final pacing in TestPacing.values)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _ChoiceCard(
                      title: pacing.label,
                      blurb: pacing.blurb,
                      selected: _setup.pacing == pacing,
                      onTap: () => _set(
                        _setup.copyWith(
                          pacing: pacing,
                          clearPerQuestion: pacing == TestPacing.casual,
                        ),
                      ),
                    ),
                  ),

                const SizedBox(height: 22),
                Row(
                  children: [
                    _Label('Total time'),
                    const Spacer(),
                    Text(
                      _formatMinutes(_setup.durationMinutes),
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: palette.accent,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final minutes in _durationChoices)
                      _Chip(
                        label: _formatMinutes(minutes),
                        selected: _setup.durationMinutes == minutes,
                        onTap: () =>
                            _set(_setup.copyWith(durationMinutes: minutes)),
                        badge: minutes == widget.paper.durationMinutes
                            ? 'as printed'
                            : null,
                      ),
                  ],
                ),

                if (_setup.pacing == TestPacing.timed) ...[
                  const SizedBox(height: 20),
                  _Label('Per question'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _Chip(
                        label: 'Even split',
                        selected: _setup.perQuestionSeconds == null,
                        onTap: () =>
                            _set(_setup.copyWith(clearPerQuestion: true)),
                      ),
                      for (final seconds in const [30, 45, 60, 90, 120, 180])
                        _Chip(
                          label: '${seconds}s',
                          selected: _setup.perQuestionSeconds == seconds,
                          onTap: () => _set(
                            _setup.copyWith(perQuestionSeconds: seconds),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'About ${_setup.derivedPerQuestionSeconds(_questionCount)}s '
                    'per question across $_questionCount. Running out moves you '
                    'on and locks that question.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: palette.textSecondary,
                    ),
                  ),
                ],

                if (!_setup.mode.countsForRank) ...[
                  const SizedBox(height: 18),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: palette.surfaceElevated,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 16,
                          color: palette.textSecondary,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Practice runs are saved and scored, but stay out '
                            'of the percentile — a score with the answers '
                            'visible is not the same test.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: palette.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 12),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              8,
              20,
              12 + MediaQuery.paddingOf(context).bottom,
            ),
            child: SqButton(
              label: _setup.mode == TestMode.practice
                  ? 'Start practising'
                  : 'Start test',
              icon: Icons.play_arrow_rounded,
              onPressed: () => Navigator.of(context).pop(_setup),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatMinutes(int minutes) {
  if (minutes < 60) return '$minutes min';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? '${hours}h' : '${hours}h ${rest}m';
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: Theme.of(context).textTheme.labelSmall?.copyWith(
      letterSpacing: 1.1,
      color: context.sq.textFaint,
      fontWeight: FontWeight.w700,
    ),
  );
}

class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard({
    required this.title,
    required this.blurb,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String blurb;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.sq;
    return Material(
      color: selected ? palette.accentWash(0.14) : palette.surface,
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
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 20,
                color: selected ? palette.accent : palette.textFaint,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      blurb,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: palette.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.badge,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final palette = context.sq;
    return Material(
      color: selected ? palette.accent : palette.surface,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected ? palette.accent : palette.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: selected ? palette.background : palette.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (badge != null) ...[
                const SizedBox(width: 6),
                Text(
                  badge!,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: selected
                        ? palette.background.withValues(alpha: 0.7)
                        : palette.textFaint,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
