import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/i18n/language_providers.dart';
import 'package:speedquiz/core/i18n/widgets/language_picker.dart';
import 'package:speedquiz/core/network/api_errors.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/routing/nav.dart';
import 'package:speedquiz/core/theme/app_motion.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/custom_topics/data/custom_topics_repository.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

class CustomTopicScreen extends ConsumerStatefulWidget {
  const CustomTopicScreen({super.key});

  @override
  ConsumerState<CustomTopicScreen> createState() => _CustomTopicScreenState();
}

class _CustomTopicScreenState extends ConsumerState<CustomTopicScreen> {
  final _createKey = GlobalKey<SqButtonState>();
  final _promptController = TextEditingController();
  final _styleController = TextEditingController();

  String _difficulty = 'medium';
  String _mode = 'casual';
  bool _preparing = false;
  String? _error;

  List<(String, String)> _difficulties(SqStrings l10n) => [
        ('easy', l10n.difficultyEasy),
        ('medium', l10n.difficultyMedium),
        ('hard', l10n.difficultyHard),
        ('expert', l10n.difficultyExpert),
      ];

  List<(String, String)> _modes(SqStrings l10n) => [
        ('casual', l10n.setupModeCasual),
        ('speedrun', l10n.setupModeSpeedrun),
        ('survival', l10n.setupModeSurvival),
      ];

  @override
  void dispose() {
    _promptController.dispose();
    _styleController.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final l10n = context.l10n;
    final language = ref.read(quizLanguageProvider);
    final prompt = _promptController.text.trim();
    if (prompt.length < 3) {
      _createKey.currentState?.reject();
      setState(() => _error = l10n.customNeedPrompt);
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _preparing = true;
      _error = null;
    });

    try {
      final result = await ref
          .read(customTopicsRepositoryProvider)
          .create(
            prompt: prompt,
            difficulty: _difficulty,
            mode: _mode,
            style: _styleController.text.trim().isEmpty
                ? null
                : _styleController.text.trim(),
            language: language.code,
          );
      if (!mounted) return;

      final session = result.session;
      if (session == null || result.topicId == null) {
        setState(() {
          _preparing = false;
          _error = l10n.customNotEnoughQuestions;
        });
        return;
      }

      Haptics.success();
      context.pushReplacement(
        Routes.quizPlay,
        extra: {
          'topicId': result.topicId,
          'topicName': result.topicName ?? result.classifiedSubject,
          'mode': _mode,
          'difficulty': _difficulty,
          'language': language.code,
          'session': session,
        },
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _preparing = false;
        _error = apiErrorMessage(
          error,
          fallback: l10n.customFailed,
          strings: l10n,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final l10n = context.l10n;
    final quizLanguage = ref.watch(quizLanguageProvider);

    if (_preparing) return const _GeneratingView();

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SqBackdrop(
        intensity: 0.6,
        colors: const [AppColors.violet, AppColors.magenta, AppColors.accent],
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
                        l10n.customTitle,
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.md,
                    AppSpacing.lg,
                    AppSpacing.lg,
                  ),
                  children: [
                    SqStagger(
                      child: Text(
                        l10n.customHeadline,
                        style: theme.textTheme.headlineMedium?.copyWith(
                          height: 1.15,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SqStagger(
                      index: 1,
                      child: Text(
                        l10n.customBody,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    SqStagger(
                      index: 2,
                      child: TextField(
                        controller: _promptController,
                        maxLines: 3,
                        maxLength: 400,
                        textInputAction: TextInputAction.done,
                        style: theme.textTheme.bodyLarge,
                        onChanged: (_) {
                          if (_error != null) setState(() => _error = null);
                        },
                        decoration: InputDecoration(
                          hintText: l10n.customPromptHint,
                        ),
                      ),
                    ),
                    SqStagger(
                      index: 3,
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final suggestion in l10n.customSuggestions)
                            _SuggestionChip(
                              label: suggestion,
                              onTap: () {
                                Haptics.tap();
                                setState(() {
                                  _promptController.text = suggestion;
                                  _error = null;
                                });
                              },
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    // The bank is generated on demand, so a custom topic is
                    // the one place where *any* language is always available —
                    // there is no existing stock to be missing from.
                    SqStagger(
                      index: 4,
                      child: SqSectionHeader(
                        title: l10n.quizLanguageTitle,
                        subtitle: l10n.customLanguageNote(
                          quizLanguage.nativeLabel,
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    SqStagger(
                      index: 5,
                      child: SqLanguagePicker(
                        selected: quizLanguage,
                        tint: AppColors.violet,
                        onChanged: (language) {
                          if (language == quizLanguage) return;
                          Haptics.tap();
                          ref
                              .read(quizLanguageProvider.notifier)
                              .setLanguage(language);
                        },
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    SqStagger(
                      index: 6,
                      child: SqSectionHeader(title: l10n.customDifficulty),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    SqStagger(
                      index: 5,
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final (value, label) in _difficulties(l10n))
                            _Pill(
                              label: label,
                              selected: _difficulty == value,
                              onTap: () {
                                Haptics.tap();
                                setState(() => _difficulty = value);
                              },
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    SqStagger(
                      index: 8,
                      child: SqSectionHeader(title: l10n.customMode),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    SqStagger(
                      index: 7,
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final (value, label) in _modes(l10n))
                            _Pill(
                              label: label,
                              selected: _mode == value,
                              onTap: () {
                                Haptics.tap();
                                setState(() => _mode = value);
                              },
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    SqStagger(
                      index: 8,
                      child: SqSectionHeader(
                        title: l10n.customStyle,
                        subtitle: l10n.customStyleSubtitle,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    SqStagger(
                      index: 9,
                      child: TextField(
                        controller: _styleController,
                        maxLength: 120,
                        style: theme.textTheme.bodyLarge,
                        decoration: InputDecoration(
                          hintText: l10n.customStyleHint,
                        ),
                      ),
                    ),
                    AnimatedSize(
                      duration: AppMotion.normal,
                      curve: AppMotion.enter,
                      child: _error == null
                          ? const SizedBox(width: double.infinity)
                          : Padding(
                              padding: const EdgeInsets.only(
                                top: AppSpacing.sm,
                              ),
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
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(color: AppColors.danger),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                    ),
                  ],
                ),
              ),
              Container(
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
                  AppSpacing.md,
                ),
                child: SafeArea(
                  top: false,
                  child: SqButton(
                    key: _createKey,
                    label: l10n.customCreate,
                    icon: Icons.auto_awesome_rounded,
                    onPressed: _create,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Generation can take a while with a real LLM, so the wait gets its own
/// screen with rotating status copy instead of a bare spinner.
class _GeneratingView extends StatefulWidget {
  const _GeneratingView();

  @override
  State<_GeneratingView> createState() => _GeneratingViewState();
}

class _GeneratingViewState extends State<_GeneratingView>
    with SingleTickerProviderStateMixin {
  static const _glyphs = ['🧭', '✍️', '🔍', '🎲'];

  static List<String> _stageLabels(SqStrings l10n) => [
        l10n.customStageUnderstanding,
        l10n.customStageWriting,
        l10n.customStageChecking,
        l10n.customStageShuffling,
      ];

  late final AnimationController _controller =
      AnimationController(vsync: this, duration: const Duration(seconds: 3))
        ..addStatusListener((status) {
          if (status == AnimationStatus.completed && mounted) {
            setState(() => _stage = (_stage + 1) % _glyphs.length);
            _controller.forward(from: 0);
          }
        });

  int _stage = 0;

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final stages = _stageLabels(context.l10n);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SqBackdrop(
        colors: const [AppColors.violet, AppColors.magenta, AppColors.accent],
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 76,
                    height: 76,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: p.accent,
                      backgroundColor: p.border,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  Text(
                    context.l10n.customBuilding,
                    style: theme.textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AnimatedSwitcher(
                    duration: AppMotion.normal,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 0.4),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    ),
                    child: Row(
                      key: ValueKey(_stage),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _glyphs[_stage],
                          style: const TextStyle(fontSize: 17),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          stages[_stage],
                          style: theme.textTheme.bodyLarge,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  Text(
                    context.l10n.customBuildingHint,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: p.textFaint,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SuggestionChip extends StatelessWidget {
  const _SuggestionChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return SqPressable(
      onTap: onTap,
      haptic: false,
      pressedScale: 0.94,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.violet.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(AppRadii.pill),
          border: Border.all(color: AppColors.violet.withValues(alpha: 0.28)),
        ),
        child: Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: p.isDark ? AppColors.violet : const Color(0xFF5B4BD8),
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return SqPressable(
      onTap: onTap,
      haptic: false,
      pressedScale: 0.94,
      child: AnimatedContainer(
        duration: AppMotion.fast,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? p.accentWash(0.18) : p.surface,
          borderRadius: BorderRadius.circular(AppRadii.pill),
          border: Border.all(
            color: selected ? p.accent : p.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: selected ? p.accent : p.textPrimary,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
