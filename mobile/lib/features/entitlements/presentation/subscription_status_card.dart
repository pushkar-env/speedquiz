import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
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
    final l10n = context.l10n;
    final tone = _tone();
    // Locale-aware dates: "12 Feb 2026" in English, "12 फ़र॰ 2026" in Hindi.
    final dateFormat = DateFormat.yMMMd(l10n.language.code);

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
                  _headline(l10n),
                  style: theme.textTheme.titleSmall?.copyWith(color: tone),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _detail(l10n, dateFormat),
            style: theme.textTheme.bodySmall?.copyWith(color: p.textSecondary),
          ),
          if (entitlements.manageUrl != null) ...[
            const SizedBox(height: 12),
            SqButton(
              label: entitlements.needsPaymentFix
                  ? l10n.subFixPaymentMethod
                  : l10n.subManageSubscription,
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
      SqToast.error(context, context.l10n.subCouldNotOpenStore);
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

  String _headline(SqStrings l10n) {
    switch (entitlements.state) {
      case SubscriptionState.grace:
        return l10n.subPaymentFailed;
      case SubscriptionState.onHold:
        return l10n.subOnHold;
      case SubscriptionState.paused:
        return l10n.subPaused;
      case SubscriptionState.pending:
        return l10n.subPaymentProcessing;
      case SubscriptionState.cancelled:
        return l10n.subCancelled;
      case SubscriptionState.expired:
        return l10n.subEnded;
      case SubscriptionState.revoked:
        return l10n.subRefunded;
      case SubscriptionState.active:
      case SubscriptionState.none:
        // The plan title comes from the store, already in the store account's
        // language — it is not ours to translate.
        return l10n.subActivePlan(
          entitlements.planTitle ?? l10n.profilePremium,
        );
    }
  }

  String _detail(SqStrings l10n, DateFormat dateFormat) {
    final expires = entitlements.expiresAt;
    final grace = entitlements.graceUntil;

    switch (entitlements.state) {
      case SubscriptionState.grace:
        final until = grace ?? expires;
        return until == null
            ? l10n.subUpdatePaymentNow
            : l10n.subUpdatePaymentBy(dateFormat.format(until));

      case SubscriptionState.onHold:
        return l10n.subOnHoldBody;

      case SubscriptionState.paused:
        return l10n.subPausedBody;

      case SubscriptionState.pending:
        return l10n.subProcessingBody(
          dateFormat.format(expires ?? DateTime.now()),
        );

      case SubscriptionState.cancelled:
        return expires == null
            ? l10n.subCancelledBodyNoDate
            : l10n.subCancelledBody(dateFormat.format(expires));

      case SubscriptionState.expired:
        return l10n.subEndedBody;

      case SubscriptionState.revoked:
        return l10n.subRefundedBody;

      case SubscriptionState.active:
      case SubscriptionState.none:
        if (expires == null) return l10n.subThanks;
        final on = dateFormat.format(expires);
        return entitlements.isIntroOffer
            ? l10n.subIntroPriceUntil(on)
            : l10n.subRenewsOn(on);
    }
  }
}
