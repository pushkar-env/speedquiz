import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/network/api_errors.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/routing/nav.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/entitlements/presentation/premium_paywall_sheet.dart';
import 'package:speedquiz/features/studio/data/custom_quiz_repository.dart';
import 'package:speedquiz/features/studio/domain/custom_quiz_models.dart';
import 'package:speedquiz/features/studio/presentation/widgets/quiz_widgets.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// The quiz studio: everything you wrote, and everything shared with you.
///
/// Two lists rather than one merged feed. They are different objects to their
/// owner — yours have a state you are responsible for (draft, live, archived)
/// and a friend's has only a score to beat — and interleaving them by date
/// buries whichever you came here for.
class StudioScreen extends ConsumerStatefulWidget {
  const StudioScreen({super.key});

  @override
  ConsumerState<StudioScreen> createState() => _StudioScreenState();
}

class _StudioScreenState extends ConsumerState<StudioScreen> {
  Future<void> _refresh() async {
    ref.invalidate(customQuizLibraryProvider);
    await ref.read(customQuizLibraryProvider.future);
  }

  Future<void> _create(CustomQuizLibrary library) async {
    if (library.atLimit) {
      Haptics.error();
      // The limit is the one place this feature meets the paywall, so it opens
      // the offer rather than a dialog whose only button is "OK". Archiving a
      // quiz frees a slot too, which the copy says.
      await showPremiumPaywall(context, reason: context.l10n.studioSlotsNoneBody);
      if (mounted) await _refresh();
      return;
    }
    Haptics.tap();
    await context.push(Routes.quizEditorNew);
    if (mounted) await _refresh();
  }

  Future<void> _openByCode() async {
    Haptics.tap();
    final code = await showSqSheet<String>(
      context,
      builder: (sheetContext) => const _CodeSheet(),
    );
    if (code == null || !mounted) return;

    final l10n = context.l10n;
    try {
      final quiz = await ref.read(customQuizRepositoryProvider).openByCode(code);
      if (!mounted) return;
      Haptics.success();
      // Redeeming grants standing access, so the library now holds it too.
      ref.invalidate(customQuizLibraryProvider);
      context.push(Routes.quizDetailPath(quiz.id));
    } catch (error) {
      if (!mounted) return;
      Haptics.error();
      SqToast.error(
        context,
        quizErrorMessage(context, error, fallback: l10n.studioCodeInvalid),
      );
    }
  }

  void _open(CustomQuiz quiz) {
    Haptics.tap();
    context.push(Routes.quizDetailPath(quiz.id));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final l10n = context.l10n;
    final libraryAsync = ref.watch(customQuizLibraryProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SqBackdrop(
        intensity: 0.55,
        colors: const [AppColors.gold, AppColors.magenta, AppColors.violet],
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.sm,
                  AppSpacing.lg,
                  0,
                ),
                child: Row(
                  children: [
                    SqIconButton(
                      icon: Icons.close_rounded,
                      tooltip: l10n.close,
                      onPressed: () => context.popOrGo(Routes.home),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        l10n.studioTitle,
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                    SqIconButton(
                      icon: Icons.vpn_key_rounded,
                      tooltip: l10n.studioOpenWithCode,
                      onPressed: _openByCode,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: libraryAsync.when(
                  loading: () => const _StudioSkeleton(),
                  error: (error, _) => Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: SqErrorState(
                      title: l10n.studioCouldNotLoad,
                      message: localizedApiErrorMessage(context, error),
                      onRetry: _refresh,
                    ),
                  ),
                  data: (library) => RefreshIndicator(
                    onRefresh: _refresh,
                    color: p.accent,
                    backgroundColor: p.surfaceElevated,
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.lg,
                        AppSpacing.md,
                        AppSpacing.lg,
                        AppSpacing.xxl,
                      ),
                      children: [
                        SqStagger(
                          child: _StudioHero(
                            library: library,
                            onCreate: () => _create(library),
                            onCode: _openByCode,
                          ),
                        ),
                        if (library.isEmpty) ...[
                          const SizedBox(height: AppSpacing.lg),
                          SqStagger(
                            index: 1,
                            child: SqEmptyState(
                              icon: '✍️',
                              title: l10n.studioEmptyTitle,
                              message: l10n.studioEmptyBody,
                            ),
                          ),
                        ],
                        if (library.mine.isNotEmpty) ...[
                          const SizedBox(height: AppSpacing.xl),
                          SqStagger(
                            index: 1,
                            child: SqSectionHeader(
                              title: l10n.studioMine,
                              subtitle: _slotsLine(l10n, library),
                            ),
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          for (var i = 0; i < library.mine.length; i++)
                            Padding(
                              padding: const EdgeInsets.only(
                                bottom: AppSpacing.sm,
                              ),
                              child: SqStagger(
                                index: 2 + i,
                                child: QuizCard(
                                  quiz: library.mine[i],
                                  onTap: () => _open(library.mine[i]),
                                ),
                              ),
                            ),
                        ],
                        if (library.shared.isNotEmpty) ...[
                          const SizedBox(height: AppSpacing.xl),
                          SqSectionHeader(
                            title: l10n.studioShared,
                            subtitle: l10n.studioSharedSubtitle,
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          for (final quiz in library.shared)
                            Padding(
                              padding: const EdgeInsets.only(
                                bottom: AppSpacing.sm,
                              ),
                              child: QuizCard(
                                quiz: quiz,
                                onTap: () => _open(quiz),
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _slotsLine(SqStrings l10n, CustomQuizLibrary library) {
    final remaining = library.remainingSlots;
    if (remaining == null) return l10n.studioSlotsUnlimited;
    if (remaining <= 0) return l10n.studioSlotsNone;
    final published = library.mine
        .where((q) => q.status == QuizStatus.published)
        .length;
    return l10n.studioSlotsLeft(remaining, remaining + published);
  }
}

class _StudioHero extends StatelessWidget {
  const _StudioHero({
    required this.library,
    required this.onCreate,
    required this.onCode,
  });

  final CustomQuizLibrary library;
  final VoidCallback onCreate;
  final VoidCallback onCode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final l10n = context.l10n;

    return SqSurface(
      padding: const EdgeInsets.all(AppSpacing.lg),
      radius: AppRadii.lg,
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          AppColors.gold.withValues(alpha: p.isDark ? 0.16 : 0.12),
          p.surface,
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SqBadge(
            label: l10n.studioTitle,
            icon: Icons.edit_note_rounded,
            color: AppColors.gold,
            dense: true,
          ),
          const SizedBox(height: AppSpacing.md),
          Text(l10n.studioHeadline, style: theme.textTheme.headlineMedium),
          const SizedBox(height: 6),
          Text(l10n.studioBody, style: theme.textTheme.bodyMedium),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: SqButton(
                  label: l10n.studioCreate,
                  icon: Icons.add_rounded,
                  onPressed: onCreate,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: SqButton(
                  label: l10n.studioOpenWithCode,
                  variant: SqButtonVariant.ghost,
                  onPressed: onCode,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Enter a friend's share code.
class _CodeSheet extends StatefulWidget {
  const _CodeSheet();

  @override
  State<_CodeSheet> createState() => _CodeSheetState();
}

class _CodeSheetState extends State<_CodeSheet> {
  final _controller = TextEditingController();

  /// Mirrors the server's alphabet: no vowels, no 0/O or 1/I. Filtering as the
  /// player types means a code copied with a stray space or dash still lands.
  static final _formatters = [
    FilteringTextInputFormatter.allow(RegExp('[2-9bcdfghjkmnpqrstvwxyzBCDFGHJKMNPQRSTVWXYZ]')),
    LengthLimitingTextInputFormatter(6),
    TextInputFormatter.withFunction(
      (_, next) => next.copyWith(text: next.text.toUpperCase()),
    ),
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final code = _controller.text.trim();
    if (code.length < 6) {
      Haptics.error();
      SqToast.warning(context, context.l10n.studioCodeInvalid);
      return;
    }
    Navigator.of(context).pop(code);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.lg + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.studioOpenWithCode, style: theme.textTheme.titleLarge),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _controller,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: _formatters,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(letterSpacing: 8),
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(hintText: l10n.studioCodeHint),
          ),
          const SizedBox(height: AppSpacing.md),
          SqButton(
            label: l10n.studioOpen,
            icon: Icons.arrow_forward_rounded,
            onPressed: _submit,
          ),
        ],
      ),
    );
  }
}

class _StudioSkeleton extends StatelessWidget {
  const _StudioSkeleton();

  @override
  Widget build(BuildContext context) {
    return SqShimmer(
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        physics: const NeverScrollableScrollPhysics(),
        children: const [
          SqSkeleton(height: 190, radius: AppRadii.lg),
          SizedBox(height: AppSpacing.xl),
          SqSkeletonCard(),
          SizedBox(height: AppSpacing.sm),
          SqSkeletonCard(),
          SizedBox(height: AppSpacing.sm),
          SqSkeletonCard(),
        ],
      ),
    );
  }
}
