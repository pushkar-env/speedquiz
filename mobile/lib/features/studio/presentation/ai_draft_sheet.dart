import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/theme/app_motion.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/studio/data/custom_quiz_repository.dart';
import 'package:speedquiz/features/studio/domain/custom_quiz_models.dart';
import 'package:speedquiz/features/studio/presentation/widgets/quiz_widgets.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// Ask the AI for starter questions, then hand back the ones the author kept.
///
/// Writing ten questions by hand is where most people abandon a quiz creator,
/// so this exists to get past the blank page — but nothing it produces is
/// saved until the author says so, and every draft stays editable afterwards.
/// The author is the one publishing it, so the review step is the product, not
/// a formality.
Future<List<CustomQuizQuestion>?> showAiDraftSheet(
  BuildContext context, {
  required int roomLeft,
}) {
  return showModalBottomSheet<List<CustomQuizQuestion>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: context.sq.scrim.withValues(alpha: 0.7),
    useSafeArea: true,
    builder: (sheetContext) => Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xl),
      child: SqSheetShell(child: _AiDraftSheet(roomLeft: roomLeft)),
    ),
  );
}

class _AiDraftSheet extends ConsumerStatefulWidget {
  const _AiDraftSheet({required this.roomLeft});

  /// How many more questions fit in this quiz. Caps the request, so the author
  /// is never offered drafts the quiz has no room to hold.
  final int roomLeft;

  @override
  ConsumerState<_AiDraftSheet> createState() => _AiDraftSheetState();
}

class _AiDraftSheetState extends ConsumerState<_AiDraftSheet> {
  final _promptController = TextEditingController();
  final _draftKey = GlobalKey<SqButtonState>();

  int _count = 5;
  String _difficulty = 'medium';
  bool _working = false;
  String? _error;
  List<CustomQuizQuestion> _drafts = const [];

  /// Which drafts the author still wants. Keyed by list index because a draft
  /// has no id until it is saved.
  final Set<int> _kept = {};

  int? _remainingToday;

  int get _maxCount => widget.roomLeft.clamp(1, 10);

  @override
  void initState() {
    super.initState();
    _count = _maxCount < 5 ? _maxCount : 5;
  }

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    final l10n = context.l10n;
    final prompt = _promptController.text.trim();
    if (prompt.length < 3) {
      Haptics.error();
      _draftKey.currentState?.reject();
      setState(() => _error = l10n.aiDraftNeedPrompt);
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _working = true;
      _error = null;
    });

    try {
      final batch = await ref
          .read(customQuizRepositoryProvider)
          .aiDraft(prompt: prompt, count: _count, difficulty: _difficulty);
      if (!mounted) return;
      Haptics.success();
      setState(() {
        _working = false;
        _drafts = batch.questions.take(_maxCount).toList(growable: false);
        _remainingToday = batch.remainingToday;
        _kept
          ..clear()
          // Everything starts kept: the common case is "these are fine, add
          // them", and asking the author to tick five boxes to get there would
          // undo the point of the feature.
          ..addAll(List.generate(_drafts.length, (i) => i));
      });
    } catch (error) {
      if (!mounted) return;
      Haptics.error();
      setState(() {
        _working = false;
        _error = quizErrorMessage(context, error);
      });
    }
  }

  void _accept() {
    final kept = [
      for (var i = 0; i < _drafts.length; i++)
        if (_kept.contains(i)) _drafts[i],
    ];
    if (kept.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    Haptics.success();
    Navigator.of(context).pop(kept);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final l10n = context.l10n;
    final hasDrafts = _drafts.isNotEmpty;

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
                const Icon(
                  Icons.auto_awesome_rounded,
                  size: 20,
                  color: AppColors.violet,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.aiDraftTitle,
                    style: theme.textTheme.titleLarge,
                  ),
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
                if (!hasDrafts) ...[
                  Text(l10n.aiDraftBody, style: theme.textTheme.bodyMedium),
                  const SizedBox(height: AppSpacing.md),
                  TextField(
                    controller: _promptController,
                    maxLines: 2,
                    maxLength: 200,
                    autofocus: true,
                    enabled: !_working,
                    textCapitalization: TextCapitalization.sentences,
                    style: theme.textTheme.bodyLarge,
                    onChanged: (_) {
                      if (_error != null) setState(() => _error = null);
                    },
                    decoration: InputDecoration(hintText: l10n.aiDraftHint),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(l10n.aiDraftCount, style: theme.textTheme.titleSmall),
                  const SizedBox(height: AppSpacing.sm),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final n in const [3, 5, 8, 10])
                        if (n <= _maxCount)
                          QuizChip(
                            label: '$n',
                            selected: _count == n,
                            tint: AppColors.violet,
                            onTap: () {
                              Haptics.tap();
                              setState(() => _count = n);
                            },
                          ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    l10n.questionDifficultyLabel,
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final (value, label) in [
                        ('easy', l10n.difficultyEasy),
                        ('medium', l10n.difficultyMedium),
                        ('hard', l10n.difficultyHard),
                        ('expert', l10n.difficultyExpert),
                      ])
                        QuizChip(
                          label: label,
                          selected: _difficulty == value,
                          tint: AppColors.violet,
                          onTap: () {
                            Haptics.tap();
                            setState(() => _difficulty = value);
                          },
                        ),
                    ],
                  ),
                ] else ...[
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.aiDraftReviewNote,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                      if (_remainingToday != null)
                        SqBadge(
                          label: l10n.aiDraftRemaining(_remainingToday!),
                          color: AppColors.violet,
                          dense: true,
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  for (var i = 0; i < _drafts.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: _DraftRow(
                        draft: _drafts[i],
                        kept: _kept.contains(i),
                        onToggle: () {
                          Haptics.tap();
                          setState(() {
                            if (!_kept.remove(i)) _kept.add(i);
                          });
                        },
                      ),
                    ),
                ],
                AnimatedSize(
                  duration: AppMotion.normal,
                  curve: AppMotion.enter,
                  alignment: Alignment.topCenter,
                  child: _error == null
                      ? const SizedBox(width: double.infinity)
                      : Padding(
                          padding: const EdgeInsets.only(top: AppSpacing.sm),
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
            child: hasDrafts
                ? Row(
                    children: [
                      Expanded(
                        child: SqButton(
                          label: l10n.aiDraftAddAll(_kept.length),
                          icon: Icons.playlist_add_rounded,
                          onPressed: _kept.isEmpty ? null : _accept,
                        ),
                      ),
                      const SizedBox(width: 10),
                      SqIconButton(
                        icon: Icons.refresh_rounded,
                        tooltip: l10n.aiDraftGenerate,
                        size: 54,
                        color: p.textSecondary,
                        onPressed: () => setState(() {
                          _drafts = const [];
                          _kept.clear();
                        }),
                      ),
                    ],
                  )
                : SqButton(
                    key: _draftKey,
                    label: _working ? l10n.aiDraftWorking : l10n.aiDraftGenerate,
                    icon: Icons.auto_awesome_rounded,
                    loading: _working,
                    onPressed: _working ? null : _generate,
                  ),
          ),
        ],
      ),
    );
  }
}

/// One proposed question, with its answer key shown so the author can judge it
/// without opening anything.
class _DraftRow extends StatelessWidget {
  const _DraftRow({
    required this.draft,
    required this.kept,
    required this.onToggle,
  });

  final CustomQuizQuestion draft;
  final bool kept;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return SqSurface(
      onTap: onToggle,
      accent: AppColors.violet,
      highlighted: kept,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            kept
                ? Icons.check_circle_rounded
                : Icons.radio_button_unchecked_rounded,
            size: 20,
            color: kept ? AppColors.violet : p.textFaint,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  draft.prompt,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: p.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    const Icon(
                      Icons.check_rounded,
                      size: 14,
                      color: AppColors.success,
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        draft.correctOption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: AppColors.success,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
