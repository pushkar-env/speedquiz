import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/auth/presentation/auth_controller.dart';
import 'package:speedquiz/features/multiplayer/presentation/multiplayer_providers.dart';
import 'package:speedquiz/features/social/data/social_repository.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// Choose the handle other players find you by.
///
/// Availability is checked as you type against the *confusable* form of the
/// name, so `R4vi` reports taken when `ravi` exists. Suggestions come from the
/// server for the same reason: it is the only side that knows what is free.
class UsernameEditScreen extends ConsumerStatefulWidget {
  const UsernameEditScreen({super.key});

  @override
  ConsumerState<UsernameEditScreen> createState() => _UsernameEditScreenState();
}

class _UsernameEditScreenState extends ConsumerState<UsernameEditScreen> {
  final _controller = TextEditingController();
  String _draft = '';
  bool _saving = false;
  bool _seeded = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final status = ref.watch(usernameStatusProvider);

    return Scaffold(
      backgroundColor: context.sq.background,
      appBar: AppBar(title: Text(l10n.usernameTitle)),
      body: SqBackdrop(
        child: SafeArea(
          child: status.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => SqErrorState(
              message: l10n.matchError(errorCodeOf(error)),
              onRetry: () => ref.invalidate(usernameStatusProvider),
            ),
            data: (data) {
              if (!_seeded) {
                // Seed once. Doing it on every build would fight the keyboard.
                _seeded = true;
                _controller.text = data.username;
                _draft = data.username;
              }
              final locked = !data.canChangeNow;

              return ListView(
                padding: const EdgeInsets.all(AppSpacing.md),
                children: [
                  Text(l10n.usernameLabel, style: theme.textTheme.titleLarge),
                  const SizedBox(height: AppSpacing.sm),
                  TextField(
                    controller: _controller,
                    enabled: !locked,
                    autocorrect: false,
                    maxLength: 20,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9_]')),
                    ],
                    onChanged: (value) => setState(() => _draft = value),
                    decoration: InputDecoration(
                      hintText: l10n.usernameHint,
                      prefixText: '@',
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 6),
                  if (locked)
                    Text(
                      l10n.usernameLockedUntil(
                        DateFormat.yMMMd().format(
                          data.changeAvailableAt!.toLocal(),
                        ),
                      ),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppColors.warning,
                      ),
                    )
                  else
                    _AvailabilityLine(draft: _draft, current: data.username),
                  const SizedBox(height: AppSpacing.sm),
                  Text(l10n.usernameRules, style: theme.textTheme.bodySmall),
                  const SizedBox(height: AppSpacing.lg),
                  if (!locked) _Suggestions(draft: _draft, onPick: _pick),
                  const SizedBox(height: AppSpacing.lg),
                  SqButton(
                    label: l10n.usernameSave,
                    loading: _saving,
                    onPressed: locked || _draft.trim() == data.username
                        ? null
                        : _save,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  void _pick(String value) {
    _controller.text = value;
    _controller.selection = TextSelection.collapsed(offset: value.length);
    setState(() => _draft = value);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(socialRepositoryProvider).changeUsername(_draft.trim());
      ref.invalidate(usernameStatusProvider);
      // The handle appears on the profile and in every list, so the cached
      // account has to be refreshed too or the app shows the old one until
      // the next cold start.
      await ref.read(authControllerProvider.notifier).refreshMe();
      if (!mounted) return;
      SqToast.success(context, context.l10n.usernameSaved);
      context.pop();
    } catch (error) {
      if (!mounted) return;
      SqToast.error(
        context,
        context.l10n.usernameError(errorCodeOf(error)),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _AvailabilityLine extends ConsumerWidget {
  const _AvailabilityLine({required this.draft, required this.current});

  final String draft;
  final String current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final trimmed = draft.trim();

    if (trimmed.isEmpty || trimmed == current) return const SizedBox(height: 18);

    final result = ref.watch(usernameAvailabilityProvider(trimmed));
    return result.when(
      loading: () => Text(l10n.usernameChecking, style: theme.textTheme.bodySmall),
      error: (_, _) => Text(l10n.errorNetwork, style: theme.textTheme.bodySmall),
      data: (availability) {
        if (availability == null) return const SizedBox(height: 18);
        final ok = availability.available;
        return Row(
          children: [
            Icon(
              ok ? Icons.check_circle_rounded : Icons.error_rounded,
              size: 15,
              color: ok ? AppColors.success : AppColors.danger,
            ),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                ok
                    ? l10n.usernameAvailable
                    : l10n.usernameError(availability.reason ?? 'username_taken'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: ok ? AppColors.success : AppColors.danger,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Suggestions extends ConsumerWidget {
  const _Suggestions({required this.draft, required this.onPick});

  final String draft;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trimmed = draft.trim();
    if (trimmed.length < 3) return const SizedBox.shrink();

    final suggestions =
        ref.watch(usernameAvailabilityProvider(trimmed)).valueOrNull?.suggestions ??
            const <String>[];
    if (suggestions.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.l10n.usernameSuggestions,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          children: [
            for (final suggestion in suggestions)
              ActionChip(
                label: Text(suggestion),
                onPressed: () => onPick(suggestion),
              ),
          ],
        ),
      ],
    );
  }
}
