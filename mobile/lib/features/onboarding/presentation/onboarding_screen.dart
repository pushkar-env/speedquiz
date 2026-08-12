import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/i18n/language_providers.dart';
import 'package:speedquiz/core/i18n/widgets/language_picker.dart';
import 'package:speedquiz/core/theme/app_motion.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/onboarding/presentation/onboarding_controller.dart';
import 'package:speedquiz/shared/widgets/sq_logo.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// First run, before there is an account: language, then name.
///
/// Two questions and no more. Both are things the app is visibly worse without
/// — chrome in a language the player cannot read, and a home screen that
/// greets them as `player_a1b2c3d4` — and neither needs a server, which is why
/// this comes *before* sign-in rather than after it. What it collects is held
/// on the device and written to the profile the moment a session exists.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  static const _stepCount = 2;
  static const _minName = 2;
  static const _maxName = 24;

  final _pageController = PageController();
  final _nameFocus = FocusNode();
  final _continueKey = GlobalKey<SqButtonState>();
  late final TextEditingController _nameController;

  int _step = 0;
  String? _error;
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    // Restores the answer of anyone who got this far, closed the app on the
    // landing screen, and came back before signing in.
    _nameController = TextEditingController(
      text: ref.read(onboardingControllerProvider).pendingName ?? '',
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    _nameController.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  String get _trimmedName => _nameController.text.trim();

  Future<void> _goToStep(int step) async {
    setState(() => _step = step);
    if (MediaQuery.disableAnimationsOf(context)) {
      _pageController.jumpToPage(step);
    } else {
      await _pageController.animateToPage(
        step,
        duration: AppMotion.normal,
        curve: AppMotion.enter,
      );
    }
    if (!mounted) return;
    if (step == 1) {
      _nameFocus.requestFocus();
    } else {
      FocusScope.of(context).unfocus();
    }
  }

  Future<void> _pickLanguage(AppLanguage language) async {
    Haptics.tap();
    await ref.read(appLanguageProvider.notifier).setLanguage(language);
    // One question, both settings. Someone reading the app in Hindi almost
    // always wants Hindi questions on day one; Settings splits the two for the
    // minority who want them different.
    await ref.read(quizLanguageProvider.notifier).setLanguage(language);
  }

  Future<void> _next() async {
    if (_finishing) return;
    if (_step == 0) {
      await _goToStep(1);
      return;
    }

    final name = _trimmedName;
    if (name.length < _minName) {
      _continueKey.currentState?.reject();
      setState(() => _error = context.l10n.editNameTooShort(_minName));
      return;
    }
    await _finish(name);
  }

  Future<void> _finish(String? name) async {
    if (_finishing) return;
    setState(() => _finishing = true);
    FocusScope.of(context).unfocus();
    Haptics.success();
    // No navigation here: the router is watching the onboarding status and
    // moves a signed-out player on to the landing screen by itself.
    await ref.read(onboardingControllerProvider.notifier).complete(name: name);
    if (mounted) setState(() => _finishing = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final l10n = context.l10n;

    return PopScope(
      // Back walks the flow rather than leaving it — there is nothing behind
      // this screen to go back to on a first run.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _step == 0) return;
        _goToStep(_step - 1);
      },
      child: Scaffold(
        body: SqBackdrop(
          intensity: 0.75,
          child: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.sm,
                    AppSpacing.lg,
                    0,
                  ),
                  child: _StepBar(
                    step: _step,
                    total: _stepCount,
                    onBack: _step == 0 ? null : () => _goToStep(_step - 1),
                  ),
                ),
                Expanded(
                  child: PageView(
                    controller: _pageController,
                    // Driven by the buttons only: a half-swipe between two
                    // questions has no meaning, and the CTA changes per step.
                    physics: const NeverScrollableScrollPhysics(),
                    children: [
                      _LanguageStep(onPick: _pickLanguage),
                      _NameStep(
                        controller: _nameController,
                        focusNode: _nameFocus,
                        maxLength: _maxName,
                        error: _error,
                        onChanged: () {
                          if (_error != null) setState(() => _error = null);
                        },
                        onSubmitted: _next,
                      ),
                    ],
                  ),
                ),
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        p.background.withValues(alpha: 0),
                        p.background,
                      ],
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.md,
                    AppSpacing.lg,
                    AppSpacing.sm,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SqButton(
                        key: _continueKey,
                        label: _step == 0
                            ? l10n.onboardingContinue
                            : l10n.onboardingLetsGo,
                        icon: _step == 0
                            ? Icons.arrow_forward_rounded
                            : Icons.check_rounded,
                        loading: _finishing,
                        onPressed: _finishing ? null : _next,
                      ),
                      SizedBox(height: _step == 0 ? 0 : 4),
                      // Only on the name step: the language question has a
                      // right answer already selected, so skipping it is a
                      // choice without a meaning.
                      AnimatedSize(
                        duration: AppMotion.normal,
                        curve: AppMotion.enter,
                        child: _step == 0
                            ? const SizedBox(width: double.infinity)
                            : TextButton(
                                onPressed:
                                    _finishing ? null : () => _finish(null),
                                child: Text(l10n.onboardingSkip),
                              ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Segmented progress. Unlabelled on purpose — two bars say "nearly nothing to
/// do here" faster than any sentence — with the count carried in semantics for
/// anyone who cannot see them.
class _StepBar extends StatelessWidget {
  const _StepBar({
    required this.step,
    required this.total,
    required this.onBack,
  });

  final int step;
  final int total;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final p = context.sq;

    return Row(
      children: [
        SizedBox(
          width: 42,
          child: onBack == null
              ? null
              : SqIconButton(
                  icon: Icons.arrow_back_rounded,
                  tooltip: context.l10n.onboardingBack,
                  onPressed: onBack,
                ),
        ),
        Expanded(
          child: Semantics(
            label: context.l10n.onboardingStepOf(step + 1, total),
            child: Row(
              children: [
                for (var i = 0; i < total; i++) ...[
                  Expanded(
                    child: AnimatedContainer(
                      duration: AppMotion.normal,
                      curve: AppMotion.standard,
                      height: 4,
                      decoration: BoxDecoration(
                        color: i <= step ? p.accent : p.border,
                        borderRadius: BorderRadius.circular(AppRadii.pill),
                      ),
                    ),
                  ),
                  if (i != total - 1) const SizedBox(width: 6),
                ],
              ],
            ),
          ),
        ),
        // Balances the back button so the bar stays centred between steps.
        const SizedBox(width: 42),
      ],
    );
  }
}

class _LanguageStep extends ConsumerWidget {
  const _LanguageStep({required this.onPick});

  final ValueChanged<AppLanguage> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final l10n = context.l10n;
    final selected = ref.watch(appLanguageProvider);

    return _StepBody(
      children: [
        const SqStagger(
          child: Center(child: SqFloat(child: SqLogoMark(size: 76))),
        ),
        const SizedBox(height: AppSpacing.lg),
        SqStagger(
          index: 1,
          child: Text(
            l10n.onboardingLanguageTitle,
            textAlign: TextAlign.center,
            style: theme.textTheme.displaySmall?.copyWith(height: 1.08),
          ),
        ),
        const SizedBox(height: 10),
        SqStagger(
          index: 2,
          child: Text(
            l10n.onboardingLanguageBody,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: p.textSecondary,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        SqStagger(
          index: 3,
          child: SqLanguagePicker(selected: selected, onChanged: onPick),
        ),
        const SizedBox(height: AppSpacing.md),
        SqStagger(
          index: 4,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline_rounded, size: 15, color: p.textFaint),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.onboardingLanguageQuizNote,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: p.textFaint,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _NameStep extends StatelessWidget {
  const _NameStep({
    required this.controller,
    required this.focusNode,
    required this.maxLength,
    required this.error,
    required this.onChanged,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final int maxLength;
  final String? error;
  final VoidCallback onChanged;
  final VoidCallback onSubmitted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final l10n = context.l10n;

    return _StepBody(
      children: [
        // Rebuilt on every keystroke so the avatar and the heading become the
        // player's while they are still typing — the whole reason to ask.
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, value, _) {
            final typed = value.text.trim();
            final preview = typed.isEmpty ? l10n.player : typed;
            return Column(
              children: [
                SqAvatar(name: preview, size: 88, ring: true, showGlyph: false),
                const SizedBox(height: AppSpacing.md),
                Text(
                  preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: typed.isEmpty ? p.textFaint : p.textPrimary,
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: AppSpacing.lg),
        SqStagger(
          index: 1,
          child: Text(
            l10n.onboardingNameTitle,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineMedium,
          ),
        ),
        const SizedBox(height: 8),
        SqStagger(
          index: 2,
          child: Text(
            l10n.onboardingNameBody,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: p.textSecondary,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        SqStagger(
          index: 3,
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            maxLength: maxLength,
            textAlign: TextAlign.center,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.done,
            style: theme.textTheme.bodyLarge,
            inputFormatters: [
              // Same rule as the profile editor: keep names renderable and
              // board-safe.
              FilteringTextInputFormatter.deny(RegExp(r'\s{2,}')),
            ],
            decoration: InputDecoration(hintText: l10n.onboardingNameHint),
            onChanged: (_) => onChanged(),
            onSubmitted: (_) => onSubmitted(),
          ),
        ),
        AnimatedSize(
          duration: AppMotion.normal,
          curve: AppMotion.enter,
          child: error == null
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
                          error!,
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
    );
  }
}

/// Shared frame: centred on a tall screen, scrollable on a short one or with
/// the keyboard up.
class _StepBody extends StatelessWidget {
  const _StepBody({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.md,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: constraints.maxHeight - AppSpacing.xl,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
