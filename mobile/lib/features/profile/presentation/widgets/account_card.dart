import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/feedback/haptics.dart';
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

  static const _months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final p = theme.sq;
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
                'ACCOUNT',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: p.textFaint,
                  letterSpacing: 1.2,
                ),
              ),
              const Spacer(),
              SqBadge(
                label: linked ? 'GOOGLE' : 'GUEST',
                color: linked ? p.accent : p.textSecondary,
                dense: true,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          // The display name is already the headline of the identity card
          // directly above; this block is for what you cannot see up there.
          _Row(label: 'Username', value: '@${user.username}'),
          _Row(
            label: 'Email',
            value: linked ? email : 'Not linked',
            muted: !linked,
          ),
          _Row(
            label: 'Playing since',
            value: firstSeen == null
                ? '—'
                : '${_months[firstSeen.month - 1]} ${firstSeen.year}',
            // Device-local, so say so rather than implying an account age.
            hint: firstSeen == null ? null : 'on this device',
          ),
          _Row(
            label: 'Player ID',
            value: user.id.split('-').first,
            trailing: _CopyButton(value: user.id),
          ),
          if (!linked) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Guest progress lives on this device. Link a Google account in '
              'Settings to carry it to your next phone.',
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
      semanticLabel: 'Copy player ID',
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: value));
        Haptics.success();
        if (context.mounted) {
          SqToast.success(context, 'Player ID copied.');
        }
      },
      child: Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Icon(Icons.copy_rounded, size: 15, color: p.textFaint),
      ),
    );
  }
}
