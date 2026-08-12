import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/entitlements/domain/entitlement_models.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';
import 'package:url_launcher/url_launcher.dart';

/// Shows what the player is actually subscribed to, and what happens next.
///
/// The failed-payment path matters more than it looks: a card e-mandate that
/// lapses is the single most common way an Indian subscriber churns
/// involuntarily, and the store will not tell them — the app has to.
class SubscriptionStatusCard extends StatelessWidget {
  const SubscriptionStatusCard({super.key, required this.entitlements});

  final EntitlementsMe entitlements;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final tone = _tone();
    final dateFormat = DateFormat.yMMMd();

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: tone.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_icon(), size: 18, color: tone),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  _headline(),
                  style: theme.textTheme.titleSmall?.copyWith(color: tone),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _detail(dateFormat),
            style: theme.textTheme.bodySmall?.copyWith(color: p.textSecondary),
          ),
          if (entitlements.manageUrl != null) ...[
            const SizedBox(height: 12),
            SqButton(
              label: entitlements.needsPaymentFix
                  ? 'FIX PAYMENT METHOD'
                  : 'MANAGE SUBSCRIPTION',
              variant: entitlements.needsPaymentFix
                  ? SqButtonVariant.gold
                  : SqButtonVariant.ghost,
              height: 46,
              icon: Icons.open_in_new_rounded,
              onPressed: () => _openManage(context),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _openManage(BuildContext context) async {
    final raw = entitlements.manageUrl;
    if (raw == null) return;
    final uri = Uri.tryParse(raw);
    if (uri == null) return;

    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && context.mounted) {
      SqToast.error(context, 'Could not open your store subscriptions.');
    }
  }

  Color _tone() {
    if (entitlements.needsPaymentFix) return AppColors.warning;
    if (entitlements.isPending) return AppColors.cyan;
    if (entitlements.endsAtPeriodEnd) return AppColors.cyan;
    return AppColors.success;
  }

  IconData _icon() {
    if (entitlements.needsPaymentFix) return Icons.credit_card_off_rounded;
    if (entitlements.isPending) return Icons.hourglass_top_rounded;
    if (entitlements.endsAtPeriodEnd) return Icons.event_busy_rounded;
    return Icons.verified_rounded;
  }

  String _headline() {
    switch (entitlements.state) {
      case SubscriptionState.grace:
        return 'Payment failed';
      case SubscriptionState.onHold:
        return 'Subscription on hold';
      case SubscriptionState.paused:
        return 'Subscription paused';
      case SubscriptionState.pending:
        return 'Payment processing';
      case SubscriptionState.cancelled:
        return 'Cancelled';
      case SubscriptionState.expired:
        return 'Subscription ended';
      case SubscriptionState.revoked:
        return 'Subscription refunded';
      case SubscriptionState.active:
      case SubscriptionState.none:
        return '${entitlements.planTitle ?? 'Premium'} · Active';
    }
  }

  String _detail(DateFormat dateFormat) {
    final expires = entitlements.expiresAt;
    final grace = entitlements.graceUntil;

    switch (entitlements.state) {
      case SubscriptionState.grace:
        final until = grace ?? expires;
        return until == null
            ? 'Update your payment method to keep Premium.'
            : 'Update your payment method by ${dateFormat.format(until)} to '
                'keep Premium. Nothing has been lost yet.';

      case SubscriptionState.onHold:
        return 'Your last payment did not go through, so Premium is paused. '
            'Update your payment method to pick up where you left off.';

      case SubscriptionState.paused:
        return 'Premium resumes automatically when your pause ends.';

      case SubscriptionState.pending:
        return 'Your bank is still confirming the payment. Premium unlocks by '
            'itself as soon as it clears — no need to pay again.';

      case SubscriptionState.cancelled:
        return expires == null
            ? 'Premium stays active until the end of your billing period.'
            : 'Premium stays active until ${dateFormat.format(expires)}. '
                'You will not be charged again.';

      case SubscriptionState.expired:
        return 'Resubscribe any time to unlock Premium again.';

      case SubscriptionState.revoked:
        return 'This purchase was refunded, so Premium has ended.';

      case SubscriptionState.active:
      case SubscriptionState.none:
        if (expires == null) return 'Thanks for supporting SpeedQuiz.';
        final prefix = entitlements.isIntroOffer
            ? 'Your introductory price applies until'
            : 'Renews on';
        return '$prefix ${dateFormat.format(expires)}.';
    }
  }
}
