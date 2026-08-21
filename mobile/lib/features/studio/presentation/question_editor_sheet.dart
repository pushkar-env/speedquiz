import 'package:flutter/material.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/theme/app_motion.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/studio/domain/custom_quiz_models.dart';
import 'package:speedquiz/features/studio/presentation/widgets/quiz_widgets.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// What the author did in the question sheet.
sealed class QuestionEditResult {
  const QuestionEditResult();
}

class QuestionSaved extends QuestionEditResult {
  const QuestionSaved(this.question);

  final CustomQuizQuestion question;
}

class QuestionDeleted extends QuestionEditResult {
  const QuestionDeleted(this.questionId);

  final String questionId;
}

/// Write or edit one question.
///
/// A full-height sheet rather than a route: it is a form the author opens and
/// closes many times in a row, and a sheet keeps the question list visible
/// behind it so adding the ninth question still feels like working on a quiz
/// rather than filling in a wizard.
///
/// The sheet does no network work of its own — it hands the edited question
/// back and the editor screen persists it. That keeps one place responsible
/// for the quiz's state, which is the payload every mutation returns.
Future<QuestionEditResult?> showQuestionEditor(
  BuildContext context, {
  required CustomQuizQuestion question,
  bool canDelete = false,
}) {
  return showModalBottomSheet<QuestionEditResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: context.sq.scrim.withValues(alpha: 0.7),
    useSafeArea: true,
    builder: (sheetContext) => Padding(
      // Leaves the quiz list peeking above the sheet.
      padding: const EdgeInsets.only(top: AppSpacing.xl),
      child: SqSheetShell(
        child: _QuestionEditor(question: question, canDelete: canDelete),
      ),
    ),
  );
}

class _QuestionEditor extends StatefulWidget {
  const _QuestionEditor({required this.question, required this.canDelete});

  final CustomQuizQuestion question;
  final bool canDelete;

  @override
  State<_QuestionEditor> createState() => _QuestionEditorState();
}

class _QuestionEditorState extends State<_QuestionEditor> {
  final _saveKey = GlobalKey<SqButtonState>();
  late final TextEditingController _prompt;
  late final TextEditingController _explanation;
  late final List<TextEditingController> _options;
  late int _correct;
  late String _difficulty;
  String? _error;

  @override
  void initState() {
    super.initState();
    final q = widget.question;
    _prompt = TextEditingController(text: q.prompt);
    _explanation = TextEditingController(text: q.explanation ?? '');
    _options = List.generate(
      4,
      (i) => TextEditingController(text: i < q.options.length ? q.options[i] : ''),
    );
    _correct = q.correctOptionIndex.clamp(0, 3);
    _difficulty = q.difficulty;
  }

  @override
  void dispose() {
    _prompt.dispose();
    _explanation.dispose();
    for (final controller in _options) {
      controller.dispose();
    }
    super.dispose();
  }

  List<(String, String)> _difficulties(SqStrings l10n) => [
    ('easy', l10n.difficultyEasy),
    ('medium', l10n.difficultyMedium),
    ('hard', l10n.difficultyHard),
    ('expert', l10n.difficultyExpert),
  ];

  /// Client-side mirror of the server's rules, so a mistake is caught with the
  /// keyboard still up rather than after a round trip.
  String? _validate(SqStrings l10n) {
    if (_prompt.text.trim().length < 4) return l10n.questionNeedPrompt;
    final options = _options.map((c) => c.text.trim()).toList();
    if (options.any((o) => o.isEmpty)) return l10n.questionNeedOptions;
    final folded = options.map((o) => o.toLowerCase()).toSet();
    if (folded.length != options.length) return l10n.questionDuplicateOptions;
    return null;
  }

  void _save() {
    final l10n = context.l10n;
    final problem = _validate(l10n);
    if (problem != null) {
      Haptics.error();
      _saveKey.currentState?.reject();
      setState(() => _error = problem);
      return;
    }

    Haptics.success();
    final explanation = _explanation.text.trim();
    Navigator.of(context).pop(
      QuestionSaved(
        widget.question.copyWith(
          prompt: _prompt.text.trim(),
          options: _options.map((c) => c.text.trim()).toList(growable: false),
          correctOptionIndex: _correct,
          explanation: explanation.isEmpty ? null : explanation,
          difficulty: _difficulty,
        ),
      ),
    );
  }

  Future<void> _delete() async {
    final l10n = context.l10n;
    final confirmed = await showSqConfirm(
      context,
      title: l10n.questionDeleteTitle,
      message: widget.question.timesServed > 0
          ? '${l10n.questionDeleteBody} ${l10n.editorRetiredNote}'
          : l10n.questionDeleteBody,
      confirmLabel: l10n.editorDiscard,
      tone: SqDialogTone.danger,
      glyph: '🗑️',
    );
    if (!confirmed || !mounted) return;
    Navigator.of(context).pop(QuestionDeleted(widget.question.id));
  }

  void _clearError() {
    if (_error != null) setState(() => _error = null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final l10n = context.l10n;
    final isNew = widget.question.isNew;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.sm,
              AppSpacing.md,
              0,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    isNew ? l10n.questionEditorNew : l10n.questionEditorEdit,
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                if (widget.canDelete && !isNew)
                  SqIconButton(
                    icon: Icons.delete_outline_rounded,
                    tooltip: l10n.editorDelete,
                    color: AppColors.danger,
                    onPressed: _delete,
                  ),
                SqIconButton(
                  icon: Icons.close_rounded,
                  tooltip: l10n.close,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.md,
                AppSpacing.lg,
                AppSpacing.md,
              ),
              children: [
                Text(l10n.questionPromptLabel, style: theme.textTheme.titleSmall),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: _prompt,
                  maxLines: 3,
                  minLines: 2,
                  maxLength: 300,
                  autofocus: isNew,
                  textCapitalization: TextCapitalization.sentences,
                  style: theme.textTheme.bodyLarge,
                  onChanged: (_) => _clearError(),
                  decoration: InputDecoration(hintText: l10n.questionPromptHint),
                ),
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: [
                    Text(
                      l10n.questionOptionsLabel,
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        l10n.questionOptionsHint,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: p.textFaint,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                for (var i = 0; i < 4; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _OptionField(
                      controller: _options[i],
                      index: i,
                      selected: _correct == i,
                      onSelect: () {
                        Haptics.tap();
                        setState(() => _correct = i);
                      },
                      onChanged: _clearError,
                    ),
                  ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  l10n.questionDifficultyLabel,
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final (value, label) in _difficulties(l10n))
                      QuizChip(
                        label: label,
                        selected: _difficulty == value,
                        onTap: () {
                          Haptics.tap();
                          setState(() => _difficulty = value);
                        },
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  l10n.questionExplanationLabel,
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: _explanation,
                  maxLines: 2,
                  maxLength: 400,
                  textCapitalization: TextCapitalization.sentences,
                  style: theme.textTheme.bodyMedium,
                  decoration: InputDecoration(
                    hintText: l10n.questionExplanationHint,
                  ),
                ),
                AnimatedSize(
                  duration: AppMotion.normal,
                  curve: AppMotion.enter,
                  alignment: Alignment.topCenter,
                  child: _error == null
                      ? const SizedBox(width: double.infinity)
                      : Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(
                                Icons.error_outline_rounded,
                                size: 17,
                                color: AppColors.danger,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _error!,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: AppColors.danger,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              0,
              AppSpacing.lg,
              AppSpacing.md,
            ),
            child: SqButton(
              key: _saveKey,
              label: isNew ? l10n.editorAddQuestion : l10n.editorSaveChanges,
              icon: isNew ? Icons.add_rounded : Icons.check_rounded,
              onPressed: _save,
            ),
          ),
        ],
      ),
    );
  }
}

/// One answer field, with the tap target that marks it correct.
///
/// The circle is a real button rather than a separate radio column: on a phone
/// the author is already touching this row, and making "this is the answer"
/// reachable without moving their thumb is the difference between four taps
/// and eight per question.
class _OptionField extends StatelessWidget {
  const _OptionField({
    required this.controller,
    required this.index,
    required this.selected,
    required this.onSelect,
    required this.onChanged,
  });

  final TextEditingController controller;
  final int index;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onChanged;

  static const _labels = ['A', 'B', 'C', 'D'];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final l10n = context.l10n;
    final tint = selected ? AppColors.success : p.border;

    return AnimatedContainer(
      duration: AppMotion.fast,
      curve: AppMotion.standard,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: selected
            ? AppColors.success.withValues(alpha: p.isDark ? 0.1 : 0.07)
            : p.surface,
        borderRadius: BorderRadius.circular(AppRadii.sm),
        border: Border.all(
          color: selected ? tint.withValues(alpha: 0.6) : p.border,
          width: selected ? 1.5 : 1,
        ),
      ),
      child: Row(
        children: [
          Semantics(
            button: true,
            selected: selected,
            label: selected ? l10n.questionCorrect : l10n.questionMarkCorrect,
            child: SqPressable(
              onTap: onSelect,
              pressedScale: 0.9,
              borderRadius: BorderRadius.circular(AppRadii.pill),
              child: Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected
                      ? AppColors.success.withValues(alpha: 0.2)
                      : Colors.transparent,
                  border: Border.all(
                    color: selected ? AppColors.success : p.borderStrong,
                    width: selected ? 2 : 1.4,
                  ),
                ),
                child: selected
                    ? const Icon(
                        Icons.check_rounded,
                        size: 18,
                        color: AppColors.success,
                      )
                    : Text(
                        _labels[index],
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: p.textFaint,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: controller,
              maxLength: 160,
              textCapitalization: TextCapitalization.sentences,
              style: theme.textTheme.bodyMedium,
              onChanged: (_) => onChanged(),
              decoration: InputDecoration(
                hintText: l10n.questionOptionHint(index),
                counterText: '',
                // The row already draws the border and the tint; a second one
                // from the field would double up and read as a seam.
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
