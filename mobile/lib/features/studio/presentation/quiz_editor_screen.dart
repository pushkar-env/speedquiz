import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/i18n/language_providers.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/entitlements/presentation/premium_paywall_sheet.dart';
import 'package:speedquiz/features/studio/data/custom_quiz_repository.dart';
import 'package:speedquiz/features/studio/domain/custom_quiz_models.dart';
import 'package:speedquiz/features/studio/presentation/ai_draft_sheet.dart';
import 'package:speedquiz/features/studio/presentation/question_editor_sheet.dart';
import 'package:speedquiz/features/studio/presentation/widgets/quiz_widgets.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// Write a quiz.
///
/// One screen for creating and for editing. A new quiz exists only on the
/// device until the author does something that needs an id — adds a question,
/// asks for AI drafts, publishes — at which point [_ensureQuiz] creates it.
/// Creating a row the moment the screen opens would leave a trail of "Untitled"
/// drafts behind every player who tapped the button and changed their mind.
///
/// Metadata saves itself. Chips write through immediately, text fields after a
/// pause, and leaving the screen flushes whatever is still pending — so there
/// is no "you have unsaved changes" dialog, because there are none.
class QuizEditorScreen extends ConsumerStatefulWidget {
  const QuizEditorScreen({super.key, this.quizId});

  /// Null for a quiz that does not exist yet.
  final String? quizId;

  @override
  ConsumerState<QuizEditorScreen> createState() => _QuizEditorScreenState();
}

class _QuizEditorScreenState extends ConsumerState<QuizEditorScreen> {
  static const _icons = [
    '🧠', '🎬', '⚽', '🎵', '🧪', '🌍', '📚', '🍿',
    '🎮', '🐾', '🚀', '🍕', '🏛️', '💡', '🎨', '🔥',
  ];

  /// How long a text edit sits before it is written. Long enough that typing a
  /// title is one request rather than twenty, short enough that backing out
  /// immediately after still lands (the flush on exit covers the rest).
  static const _saveDebounce = Duration(milliseconds: 900);

  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();

  CustomQuiz? _quiz;
  String _icon = '🧠';
  QuizVisibility _visibility = QuizVisibility.private;
  String _mode = 'casual';
  String _difficulty = 'medium';

  bool _loading = false;
  bool _busy = false;
  bool _metaDirty = false;
  Timer? _saveTimer;
  Object? _loadError;

  bool get _isNew => _quiz == null;

  @override
  void initState() {
    super.initState();
    if (widget.quizId != null) _load(widget.quizId!);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _load(String quizId) async {
    setState(() => _loading = true);
    try {
      final quiz = await ref.read(customQuizRepositoryProvider).fetchQuiz(quizId);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _adopt(quiz, syncControllers: true);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = error;
      });
    }
  }

  /// Take a server payload as the new truth.
  ///
  /// Text controllers are only rewritten on the first load: the author may be
  /// mid-word when a question save returns, and replacing the field's contents
  /// under their cursor would eat the keystroke.
  void _adopt(CustomQuiz quiz, {bool syncControllers = false}) {
    _quiz = quiz;
    _icon = quiz.icon;
    _visibility = quiz.visibility;
    _mode = quiz.defaultMode;
    _difficulty = quiz.defaultDifficulty;
    if (syncControllers) {
      _titleController.text = quiz.title;
      _descriptionController.text = quiz.description ?? '';
    }
  }

  bool get _locked => _quiz?.isHidden ?? false;

  // --- Persistence ----------------------------------------------------------

  /// The quiz, creating it first if this is still a local draft.
  ///
  /// Returns null when the title is missing — the one field the server needs
  /// and the only reason creation can fail on the author's side.
  Future<CustomQuiz?> _ensureQuiz() async {
    final existing = _quiz;
    if (existing != null) return existing;

    final title = _titleController.text.trim();
    if (title.length < 2) {
      Haptics.error();
      SqToast.warning(context, context.l10n.editorNeedTitle);
      return null;
    }

    try {
      final created = await ref
          .read(customQuizRepositoryProvider)
          .create(
            title: title,
            description: _descriptionController.text.trim(),
            icon: _icon,
            language: ref.read(quizLanguageProvider).code,
            visibility: _visibility,
            defaultMode: _mode,
            defaultDifficulty: _difficulty,
          );
      if (!mounted) return null;
      setState(() {
        _adopt(created);
        _metaDirty = false;
      });
      return created;
    } catch (error) {
      if (!mounted) return null;
      _showError(error);
      return null;
    }
  }

  void _touchMeta() {
    _metaDirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounce, _flushMeta);
  }

  /// Write pending metadata. Silent on success — an author who changed a chip
  /// does not need a toast telling them the chip changed.
  Future<void> _flushMeta({bool notify = false}) async {
    _saveTimer?.cancel();
    final quiz = _quiz;
    if (!_metaDirty || quiz == null || _locked) return;
    _metaDirty = false;

    final title = _titleController.text.trim();
    try {
      final updated = await ref
          .read(customQuizRepositoryProvider)
          .update(
            quiz.id,
            title: title.length >= 2 ? title : null,
            description: _descriptionController.text.trim(),
            icon: _icon,
            visibility: _visibility,
            defaultMode: _mode,
            defaultDifficulty: _difficulty,
          );
      if (!mounted) return;
      setState(() => _adopt(updated));
      if (notify) SqToast.success(context, context.l10n.editorSaved);
    } catch (error) {
      if (!mounted) return;
      // Put the flag back so the next flush retries rather than dropping it.
      _metaDirty = true;
      _showError(error);
    }
  }

  void _showError(Object error) {
    Haptics.error();
    SqToast.error(context, quizErrorMessage(context, error));
  }

  /// Run a mutation that returns the whole quiz, and adopt the result.
  Future<void> _mutate(
    Future<CustomQuiz> Function(CustomQuizRepository repo) action, {
    String? success,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final updated = await action(ref.read(customQuizRepositoryProvider));
      if (!mounted) return;
      setState(() {
        _busy = false;
        _adopt(updated);
      });
      ref.invalidate(customQuizLibraryProvider);
      ref.invalidate(customQuizProvider(updated.id));
      if (success != null && mounted) SqToast.success(context, success);
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      _showError(error);
    }
  }

  // --- Questions ------------------------------------------------------------

  Future<void> _addQuestion() async {
    final quiz = await _ensureQuiz();
    if (quiz == null || !mounted) return;

    final result = await showQuestionEditor(
      context,
      question: CustomQuizQuestion.blank(),
    );
    if (result is! QuestionSaved || !mounted) return;
    await _mutate((repo) => repo.addQuestion(quiz.id, result.question));
  }

  Future<void> _editQuestion(CustomQuizQuestion question) async {
    final quiz = _quiz;
    if (quiz == null) return;

    final result = await showQuestionEditor(
      context,
      question: question,
      canDelete: true,
    );
    if (!mounted || result == null) return;
    switch (result) {
      case QuestionSaved(:final question):
        await _mutate(
          (repo) => repo.updateQuestion(quiz.id, question.id, question),
        );
      case QuestionDeleted(:final questionId):
        await _mutate((repo) => repo.deleteQuestion(quiz.id, questionId));
    }
  }

  Future<void> _aiDraft() async {
    final quiz = await _ensureQuiz();
    if (quiz == null || !mounted) return;

    final room = _maxQuestions - quiz.questionCount;
    if (room <= 0) {
      Haptics.error();
      await showPremiumPaywall(context, reason: context.l10n.editorQuestionLimit);
      return;
    }

    final drafts = await showAiDraftSheet(context, roomLeft: room);
    if (drafts == null || drafts.isEmpty || !mounted) return;

    // Posted one at a time: the endpoint takes a single question, and a
    // partial failure part-way through still leaves everything before it
    // saved rather than losing the batch.
    setState(() => _busy = true);
    CustomQuiz current = quiz;
    Object? failure;
    for (final draft in drafts) {
      try {
        current = await ref
            .read(customQuizRepositoryProvider)
            .addQuestion(current.id, draft);
      } catch (error) {
        failure = error;
        break;
      }
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _adopt(current);
    });
    ref.invalidate(customQuizLibraryProvider);
    if (failure != null) _showError(failure);
  }

  Future<void> _reorder(int oldIndex, int newIndex) async {
    final quiz = _quiz;
    if (quiz == null || _locked) return;

    final ids = quiz.questions.map((q) => q.id).toList();
    ids.insert(newIndex, ids.removeAt(oldIndex));

    // Reorder optimistically: the list has already animated to the new order
    // under the author's finger, and snapping back while a request flies would
    // read as the drag having failed.
    final reordered = [...quiz.questions]
      ..sort((a, b) => ids.indexOf(a.id).compareTo(ids.indexOf(b.id)));
    setState(() => _quiz = _withQuestions(quiz, reordered));
    Haptics.tap();

    try {
      final updated = await ref
          .read(customQuizRepositoryProvider)
          .reorderQuestions(quiz.id, ids);
      if (!mounted) return;
      setState(() => _adopt(updated));
    } catch (error) {
      if (!mounted) return;
      setState(() => _quiz = quiz);
      _showError(error);
    }
  }

  static CustomQuiz _withQuestions(
    CustomQuiz quiz,
    List<CustomQuizQuestion> questions,
  ) {
    return CustomQuiz(
      id: quiz.id,
      topicId: quiz.topicId,
      title: quiz.title,
      description: quiz.description,
      icon: quiz.icon,
      language: quiz.language,
      visibility: quiz.visibility,
      status: quiz.status,
      code: quiz.code,
      questionCount: quiz.questionCount,
      defaultMode: quiz.defaultMode,
      defaultDifficulty: quiz.defaultDifficulty,
      playCount: quiz.playCount,
      playerCount: quiz.playerCount,
      topScore: quiz.topScore,
      author: quiz.author,
      isOwner: quiz.isOwner,
      myBestScore: quiz.myBestScore,
      publishBlockers: quiz.publishBlockers,
      maxQuestions: quiz.maxQuestions,
      minQuestions: quiz.minQuestions,
      moderationNote: quiz.moderationNote,
      createdAt: quiz.createdAt,
      updatedAt: quiz.updatedAt,
      publishedAt: quiz.publishedAt,
      questions: questions,
    );
  }

  // --- Lifecycle ------------------------------------------------------------

  Future<void> _publish() async {
    final quiz = await _ensureQuiz();
    if (quiz == null || !mounted) return;
    await _flushMeta();
    if (!mounted) return;
    await _mutate(
      (repo) => repo.publish(quiz.id),
      success: context.l10n.editorPublished,
    );
    if (mounted && (_quiz?.status.isLive ?? false)) Haptics.success();
  }

  Future<void> _archive() async {
    final quiz = _quiz;
    if (quiz == null) return;
    await _mutate(
      (repo) => repo.archive(quiz.id),
      success: context.l10n.editorArchived,
    );
  }

  Future<void> _delete() async {
    final quiz = _quiz;
    final l10n = context.l10n;
    if (quiz == null) {
      // Never created — nothing to delete, just leave.
      if (mounted) context.pop();
      return;
    }
    final confirmed = await showSqConfirm(
      context,
      title: l10n.editorDeleteTitle,
      message: l10n.editorDeleteBody,
      confirmLabel: l10n.editorDelete,
      tone: SqDialogTone.danger,
      glyph: '🗑️',
    );
    if (!confirmed || !mounted) return;

    try {
      await ref.read(customQuizRepositoryProvider).delete(quiz.id);
      if (!mounted) return;
      ref.invalidate(customQuizLibraryProvider);
      context.pop();
    } catch (error) {
      if (!mounted) return;
      _showError(error);
    }
  }

  Future<void> _close() async {
    await _flushMeta();
    if (mounted) context.pop();
  }

  /// The ceiling this author's plan puts on one quiz.
  ///
  /// Prefers the value the quiz itself carries: the library provider is not
  /// guaranteed to have loaded when the editor is reached directly, and
  /// falling back to the free number would cap a Premium author at twenty.
  int get _maxQuestions =>
      _quiz?.maxQuestions ??
      ref.read(customQuizLibraryProvider).valueOrNull?.maxQuestions ??
      20;

  // --- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final l10n = context.l10n;
    final quiz = _quiz;
    final questions = quiz?.questions ?? const <CustomQuizQuestion>[];

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _close();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SqBackdrop(
          intensity: 0.5,
          colors: const [AppColors.gold, AppColors.violet, AppColors.accent],
          child: SafeArea(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _loadError != null
                ? Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: SqErrorState(
                      message: quizErrorMessage(context, _loadError!),
                      onRetry: () => _load(widget.quizId!),
                    ),
                  )
                : Column(
                    children: [
                      _header(theme, l10n, quiz),
                      Expanded(
                        child: ReorderableListView.builder(
                          padding: const EdgeInsets.fromLTRB(
                            AppSpacing.lg,
                            0,
                            AppSpacing.lg,
                            AppSpacing.xxl,
                          ),
                          buildDefaultDragHandles: false,
                          header: _metadataForm(theme, l10n, quiz, questions),
                          footer: _questionsFooter(l10n, quiz, questions),
                          itemCount: questions.length,
                          onReorderItem: _reorder,
                          proxyDecorator: (child, _, _) => Material(
                            color: Colors.transparent,
                            child: child,
                          ),
                          itemBuilder: (context, index) => Padding(
                            key: ValueKey(questions[index].id),
                            padding: const EdgeInsets.only(
                              bottom: AppSpacing.sm,
                            ),
                            child: _QuestionRow(
                              question: questions[index],
                              index: index,
                              enabled: !_locked,
                              onTap: () => _editQuestion(questions[index]),
                            ),
                          ),
                        ),
                      ),
                      _actionBar(theme, p, l10n, quiz),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _header(ThemeData theme, SqStrings l10n, CustomQuiz? quiz) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        AppSpacing.sm,
      ),
      child: Row(
        children: [
          SqIconButton(
            icon: Icons.arrow_back_rounded,
            tooltip: l10n.close,
            onPressed: _close,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _isNew ? l10n.editorNewTitle : l10n.editorEditTitle,
              style: theme.textTheme.titleLarge,
            ),
          ),
          if (quiz != null && !_locked)
            SqIconButton(
              icon: quiz.status == QuizStatus.archived
                  ? Icons.unarchive_rounded
                  : Icons.more_horiz_rounded,
              tooltip: l10n.editorArchive,
              onPressed: () => _showMoreMenu(quiz),
            ),
        ],
      ),
    );
  }

  Future<void> _showMoreMenu(CustomQuiz quiz) async {
    Haptics.tap();
    final l10n = context.l10n;
    await showSqSheet<void>(
      context,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (quiz.status.isLive)
              ListTile(
                leading: const Icon(Icons.unpublished_outlined),
                title: Text(l10n.editorUnpublish),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _mutate(
                    (repo) => repo.unpublish(quiz.id),
                    success: l10n.editorUnpublished,
                  );
                },
              ),
            if (quiz.status == QuizStatus.archived)
              ListTile(
                leading: const Icon(Icons.unarchive_outlined),
                title: Text(l10n.editorRestore),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _mutate((repo) => repo.restore(quiz.id));
                },
              )
            else
              ListTile(
                leading: const Icon(Icons.archive_outlined),
                title: Text(l10n.editorArchive),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _archive();
                },
              ),
            // Deleting cascades to every score posted on the quiz, so it is
            // offered only while nobody has played it. Everyone else archives.
            if (quiz.canHardDelete)
              ListTile(
                leading: const Icon(
                  Icons.delete_outline_rounded,
                  color: AppColors.danger,
                ),
                title: Text(
                  l10n.editorDelete,
                  style: const TextStyle(color: AppColors.danger),
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _delete();
                },
              ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    );
  }

  Widget _metadataForm(
    ThemeData theme,
    SqStrings l10n,
    CustomQuiz? quiz,
    List<CustomQuizQuestion> questions,
  ) {
    final p = theme.sq;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_locked) ...[
          SqSurface(
            accent: AppColors.danger,
            highlighted: true,
            child: Row(
              children: [
                const Icon(
                  Icons.gpp_maybe_rounded,
                  color: AppColors.danger,
                  size: 20,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    quiz?.moderationNote ?? l10n.editorHiddenNote,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SqPressable(
              onTap: _locked ? null : _pickIcon,
              pressedScale: 0.94,
              borderRadius: BorderRadius.circular(AppRadii.sm),
              child: QuizGlyph(icon: _icon, size: 56, tint: AppColors.gold),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: TextField(
                controller: _titleController,
                enabled: !_locked,
                maxLength: 80,
                textCapitalization: TextCapitalization.words,
                style: theme.textTheme.titleMedium,
                onChanged: (_) => _touchMeta(),
                onEditingComplete: () => _flushMeta(),
                decoration: InputDecoration(
                  labelText: l10n.editorTitleLabel,
                  hintText: l10n.editorTitleHint,
                  counterText: '',
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          controller: _descriptionController,
          enabled: !_locked,
          maxLength: 280,
          maxLines: 2,
          textCapitalization: TextCapitalization.sentences,
          style: theme.textTheme.bodyMedium,
          onChanged: (_) => _touchMeta(),
          onEditingComplete: () => _flushMeta(),
          decoration: InputDecoration(
            labelText: l10n.editorDescriptionLabel,
            hintText: l10n.editorDescriptionHint,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        SqSectionHeader(title: l10n.editorVisibilityLabel),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final option in QuizVisibility.values)
              QuizChip(
                label: quizVisibilityLabel(l10n, option),
                icon: quizVisibilityIcon(option),
                selected: _visibility == option,
                tint: AppColors.gold,
                onTap: _locked
                    ? () {}
                    : () {
                        Haptics.tap();
                        setState(() => _visibility = option);
                        _touchMeta();
                        // A visibility change is the one metadata edit with a
                        // real consequence, so it writes through at once
                        // rather than waiting out the debounce.
                        _flushMeta();
                      },
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          quizVisibilityBody(l10n, _visibility),
          style: theme.textTheme.labelSmall?.copyWith(color: p.textFaint),
        ),
        const SizedBox(height: AppSpacing.md),
        SqSectionHeader(
          title: l10n.editorDefaultsLabel,
          subtitle: l10n.editorDefaultsSubtitle,
        ),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (value, label) in [
              ('casual', l10n.setupModeCasual),
              ('speedrun', l10n.setupModeSpeedrun),
              ('survival', l10n.setupModeSurvival),
            ])
              QuizChip(
                label: label,
                selected: _mode == value,
                onTap: _locked
                    ? () {}
                    : () {
                        Haptics.tap();
                        setState(() => _mode = value);
                        _touchMeta();
                      },
              ),
          ],
        ),
        const SizedBox(height: 8),
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
                tint: AppColors.cyan,
                onTap: _locked
                    ? () {}
                    : () {
                        Haptics.tap();
                        setState(() => _difficulty = value);
                        _touchMeta();
                      },
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        Row(
          children: [
            Expanded(
              child: SqSectionHeader(
                title: l10n.editorQuestionsLabel,
                subtitle: questions.length > 1 ? l10n.editorReorderHint : null,
              ),
            ),
            SqBadge(
              label: l10n.editorQuestionsCounter(
                questions.length,
                _maxQuestions,
              ),
              color: questions.length >= _maxQuestions
                  ? AppColors.warning
                  : null,
              dense: true,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        if (questions.isEmpty)
          SqEmptyState(
            icon: '📝',
            title: l10n.editorNoQuestionsTitle,
            message: l10n.editorNoQuestionsBody,
          ),
      ],
    );
  }

  Widget _questionsFooter(
    SqStrings l10n,
    CustomQuiz? quiz,
    List<CustomQuizQuestion> questions,
  ) {
    if (_locked) return const SizedBox.shrink();
    final full = questions.length >= _maxQuestions;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: SqButton(
              label: l10n.editorAddQuestion,
              icon: Icons.add_rounded,
              variant: SqButtonVariant.ghost,
              onPressed: full || _busy ? null : _addQuestion,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 3,
            child: SqButton(
              label: l10n.editorAiDraft,
              icon: Icons.auto_awesome_rounded,
              variant: SqButtonVariant.ghost,
              onPressed: full || _busy ? null : _aiDraft,
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionBar(
    ThemeData theme,
    SqPalette p,
    SqStrings l10n,
    CustomQuiz? quiz,
  ) {
    if (_locked) return const SizedBox.shrink();
    final questions = quiz?.questions.length ?? 0;
    final live = quiz?.status.isLive ?? false;
    final blocked = quiz?.publishBlockers ?? const [];
    final minimum = quiz?.minQuestions ?? 3;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [p.background.withValues(alpha: 0), p.background],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!live && blocked.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: Text(
                  blocked.contains('too_few_questions')
                      ? l10n.editorNeedQuestions(minimum)
                      : l10n.quizError(blocked.first),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: AppColors.warning,
                  ),
                ),
              ),
            if (live)
              SqButton(
                label: l10n.quizPlaySolo,
                icon: Icons.play_arrow_rounded,
                onPressed: _busy || quiz == null
                    ? null
                    : () => context.push(Routes.quizDetailPath(quiz.id)),
              )
            else
              SqButton(
                label: l10n.editorPublish,
                icon: Icons.rocket_launch_rounded,
                loading: _busy,
                onPressed: (_busy || questions < minimum || blocked.isNotEmpty)
                    ? null
                    : _publish,
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickIcon() async {
    Haptics.tap();
    final picked = await showSqSheet<String>(
      context,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                sheetContext.l10n.editorIconLabel,
                style: Theme.of(sheetContext).textTheme.titleLarge,
              ),
              const SizedBox(height: AppSpacing.md),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final icon in _icons)
                    SqPressable(
                      onTap: () => Navigator.of(sheetContext).pop(icon),
                      pressedScale: 0.9,
                      borderRadius: BorderRadius.circular(AppRadii.sm),
                      child: QuizGlyph(
                        icon: icon,
                        size: 52,
                        tint: icon == _icon ? AppColors.gold : null,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _icon = picked);
    _touchMeta();
    _flushMeta();
  }
}

/// One question in the editor list.
class _QuestionRow extends StatelessWidget {
  const _QuestionRow({
    required this.question,
    required this.index,
    required this.enabled,
    required this.onTap,
  });

  final CustomQuizQuestion question;
  final int index;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return SqSurface(
      onTap: enabled ? onTap : null,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (enabled)
            ReorderableDragStartListener(
              index: index,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Icon(
                  Icons.drag_indicator_rounded,
                  size: 20,
                  color: p.textFaint,
                ),
              ),
            )
          else
            const SizedBox(width: 8),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '${index + 1}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: p.textFaint,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (question.aiDrafted) ...[
                      const SizedBox(width: 8),
                      const Icon(
                        Icons.auto_awesome_rounded,
                        size: 12,
                        color: AppColors.violet,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  question.prompt,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: p.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(
                      Icons.check_rounded,
                      size: 13,
                      color: AppColors.success,
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        question.correctOption,
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
          const SizedBox(width: 6),
          Icon(Icons.edit_rounded, size: 16, color: p.textFaint),
          const SizedBox(width: 6),
        ],
      ),
    );
  }
}
