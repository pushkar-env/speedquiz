import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
import 'package:speedquiz/core/network/api_errors.dart';
import 'package:speedquiz/core/routing/app_router.dart';
import 'package:speedquiz/core/routing/nav.dart';
import 'package:speedquiz/core/theme/app_motion.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/auth/presentation/auth_controller.dart';
import 'package:speedquiz/features/entitlements/data/entitlements_repository.dart';
import 'package:speedquiz/features/entitlements/presentation/premium_paywall_sheet.dart';
import 'package:speedquiz/features/profile/data/profile_repository.dart';
import 'package:speedquiz/features/profile/domain/avatar_catalog.dart';
import 'package:speedquiz/features/profile/presentation/widgets/profile_widgets.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// Where a player makes the account theirs: display name and avatar.
class ProfileEditScreen extends ConsumerStatefulWidget {
  const ProfileEditScreen({super.key});

  @override
  ConsumerState<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends ConsumerState<ProfileEditScreen> {
  final _saveKey = GlobalKey<SqButtonState>();
  late final TextEditingController _nameController;

  String? _avatarId;
  bool _saving = false;
  String? _error;

  static const _minName = 2;
  static const _maxName = 24;

  @override
  void initState() {
    super.initState();
    final user = ref.read(currentUserProvider);
    _nameController = TextEditingController(text: user?.displayName ?? '');
    _avatarId = user?.avatarId;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  String get _trimmedName => _nameController.text.trim();

  bool get _dirty {
    final user = ref.read(currentUserProvider);
    final nameChanged = _trimmedName != (user?.displayName ?? '').trim();
    return nameChanged || _avatarId != user?.avatarId;
  }

  Future<void> _save() async {
    final name = _trimmedName;
    if (name.isNotEmpty && name.length < _minName) {
      _saveKey.currentState?.reject();
      setState(() => _error = 'Names need at least $_minName characters.');
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final updated = await ref
          .read(profileRepositoryProvider)
          .update(
            // Empty means "go back to the generated username"; the server
            // rejects a blank string, so send nothing in that case.
            displayName: name.isEmpty ? null : name,
            avatarId: _avatarId,
          );
      if (!mounted) return;

      ref
          .read(authControllerProvider.notifier)
          .applyIdentity(
            displayName: updated.displayName,
            avatarId: updated.avatarId,
          );
      ref.invalidate(profileProvider);

      Haptics.success();
      SqToast.success(context, 'Profile updated.');
      context.popOrGo(Routes.profile);
    } catch (error) {
      if (!mounted) return;
      _saveKey.currentState?.reject();
      setState(() {
        _saving = false;
        _error = apiErrorMessage(
          error,
          fallback: 'Could not save your profile. Try again.',
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final user = ref.watch(currentUserProvider);
    final preview = _trimmedName.isEmpty
        ? (user?.username ?? 'Player')
        : _trimmedName;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SqBackdrop(
        intensity: 0.5,
        child: SafeArea(
          child: Column(
            children: [
              const SubScreenHeader(
                title: 'Profile details',
                subtitle: 'How you appear on leaderboards',
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.sm,
                    AppSpacing.lg,
                    AppSpacing.lg,
                  ),
                  children: [
                    SqStagger(
                      child: Center(
                        child: Column(
                          children: [
                            SqAvatar(
                              name: preview,
                              seed: user?.id,
                              avatarId: _avatarId,
                              size: 92,
                              ring: true,
                              premium: user?.isPremium ?? false,
                            ),
                            const SizedBox(height: AppSpacing.md),
                            Text(
                              preview,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.headlineSmall,
                            ),
                            if (user?.username != null) ...[
                              const SizedBox(height: 2),
                              Text(
                                '@${user!.username}',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: p.textFaint,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    SqStagger(
                      index: 1,
                      child: const SqSectionHeader(
                        title: 'Display name',
                        subtitle: 'Leave empty to use your handle',
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    SqStagger(
                      index: 2,
                      child: TextField(
                        controller: _nameController,
                        maxLength: _maxName,
                        textCapitalization: TextCapitalization.words,
                        textInputAction: TextInputAction.done,
                        style: theme.textTheme.bodyLarge,
                        inputFormatters: [
                          // Keep names renderable and board-safe.
                          FilteringTextInputFormatter.deny(RegExp(r'\s{2,}')),
                        ],
                        decoration: const InputDecoration(
                          hintText: 'e.g. Quiz Goblin',
                        ),
                        onChanged: (_) => setState(() => _error = null),
                        onSubmitted: (_) => _save(),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    SqStagger(
                      index: 3,
                      child: const SqSectionHeader(
                        title: 'Avatar',
                        subtitle: 'Pick the look that fits you',
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    SqStagger(
                      index: 4,
                      child: _AvatarPicker(
                        selectedId: _avatarId,
                        isPremium:
                            ref.watch(entitlementsProvider).valueOrNull?.isPremium ??
                                (ref.watch(currentUserProvider)?.isPremium ?? false),
                        onSelect: (id) {
                          Haptics.tap();
                          setState(() => _avatarId = id);
                        },
                        onLocked: () {
                          Haptics.tap();
                          showPremiumPaywall(
                            context,
                            reason: 'Premium avatars are part of Premium.',
                          );
                        },
                      ),
                    ),
                    AnimatedSize(
                      duration: AppMotion.normal,
                      curve: AppMotion.enter,
                      child: _error == null
                          ? const SizedBox(width: double.infinity)
                          : Padding(
                              padding: const EdgeInsets.only(
                                top: AppSpacing.md,
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
                    key: _saveKey,
                    label: 'SAVE CHANGES',
                    icon: Icons.check_rounded,
                    loading: _saving,
                    onPressed: _saving || !_dirty ? null : _save,
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

class _AvatarPicker extends StatelessWidget {
  const _AvatarPicker({
    required this.selectedId,
    required this.isPremium,
    required this.onSelect,
    required this.onLocked,
  });

  final String? selectedId;
  final bool isPremium;
  final ValueChanged<String> onSelect;
  final VoidCallback onLocked;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 96,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.82,
      ),
      itemCount: AvatarCatalog.all.length,
      itemBuilder: (context, index) {
        final preset = AvatarCatalog.all[index];
        final selected = preset.id == selectedId;
        // Show premium avatars to everyone — a locked one people want is a
        // better upgrade prompt than an avatar they never knew existed.
        final locked = preset.isPremium && !isPremium;

        return SqPressable(
          onTap: locked ? onLocked : () => onSelect(preset.id),
          haptic: false,
          pressedScale: 0.92,
          semanticLabel: locked ? '${preset.name} (Premium)' : preset.name,
          child: AnimatedContainer(
            duration: AppMotion.fast,
            curve: AppMotion.standard,
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: selected ? p.accentWash(0.14) : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadii.md),
              border: Border.all(
                color: selected
                    ? p.accent
                    : (preset.isPremium
                        ? AppColors.gold.withValues(alpha: 0.45)
                        : p.border),
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Opacity(
                      opacity: locked ? 0.45 : 1,
                      child: Container(
                        width: 44,
                        height: 44,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: preset.gradient,
                        ),
                        child: Text(
                          preset.glyph,
                          style: const TextStyle(fontSize: 20, height: 1),
                        ),
                      ),
                    ),
                    if (locked)
                      Positioned(
                        right: -2,
                        bottom: -2,
                        child: Container(
                          width: 18,
                          height: 18,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.gold,
                            border: Border.all(color: p.background, width: 1.5),
                          ),
                          child: const Icon(
                            Icons.lock_rounded,
                            size: 10,
                            color: Color(0xFF201400),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  preset.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: selected
                        ? p.accent
                        : (locked ? AppColors.gold : p.textFaint),
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
