import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/auth/domain/auth_models.dart';
import 'package:speedquiz/features/welcome/data/welcome_store.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// The "who am I signed in as" block on the profile tab.
///
/// Every line is something the server or the device actually knows — no
/// invented "member since" for an account whose creation date the API does
/// not expose.
class AccountCard extends ConsumerWidget {
  const AccountCard({super.key, required this.user});

  final AuthUser? user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final l10n = context.l10n;
    final user = this.user;

    if (user == null) {
      return const SqShimmer(child: SqSkeletonCard());
    }

    final firstSeen = ref.watch(firstSeenProvider(user.id)).valueOrNull;
    final email = user.email;
    final linked = !user.isGuest && email != null && email.isNotEmpty;

    return SqSurface(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                linked
                    ? Icons.verified_user_rounded
                    : Icons.person_outline_rounded,
                size: 18,
                color: linked ? p.accent : p.textFaint,
              ),
              const SizedBox(width: 8),
              Text(
                l10n.accountTitle,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: p.textFaint,
                  letterSpacing: 1.2,
                ),
              ),
              const Spacer(),
              SqBadge(
                label: linked ? l10n.accountGoogle : l10n.accountGuest,
                color: linked ? p.accent : p.textSecondary,
                dense: true,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          // The display name is already the headline of the identity card
          // directly above; this block is for what you cannot see up there.
          _Row(label: l10n.accountUsername, value: '@${user.username}'),
          _Row(
            label: l10n.accountEmail,
            value: linked ? email : l10n.accountNotLinked,
            muted: !linked,
          ),
          _Row(
            label: l10n.accountPlayingSince,
            // intl carries the month names for every locale we ship, so this
            // reads "जनवरी 2026" in Hindi without a table of our own.
            value: firstSeen == null
                ? '—'
                : DateFormat.yMMMM(l10n.language.code).format(firstSeen),
            // Device-local, so say so rather than implying an account age.
            hint: firstSeen == null ? null : l10n.accountOnThisDevice,
          ),
          _Row(
            label: l10n.accountPlayerId,
            value: user.id.split('-').first,
            trailing: _CopyButton(value: user.id),
          ),
          if (!linked) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              l10n.accountGuestHint,
              style: theme.textTheme.bodySmall?.copyWith(color: p.textFaint),
            ),
          ],
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    required this.value,
    this.hint,
    this.muted = false,
    this.trailing,
  });

  final String label;
  final String value;
  final String? hint;
  final bool muted;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 108,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(color: p.textFaint),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: muted ? p.textFaint : p.textPrimary,
                    fontWeight: muted ? FontWeight.w500 : FontWeight.w600,
                  ),
                ),
                if (hint != null)
                  Text(
                    hint!,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: p.textFaint,
                      fontSize: 10,
                    ),
                  ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _CopyButton extends StatelessWidget {
  const _CopyButton({required this.value});

  final String value;

  @override
  Widget build(BuildContext context) {
    final p = context.sq;

    return SqPressable(
      pressedScale: 0.88,
      semanticLabel: context.l10n.accountCopyPlayerId,
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: value));
        Haptics.success();
        if (context.mounted) {
          SqToast.success(context, context.l10n.accountPlayerIdCopied);
        }
      },
      child: Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Icon(Icons.copy_rounded, size: 15, color: p.textFaint),
      ),
    );
  }
}
