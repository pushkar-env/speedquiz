import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/network/api_errors.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/auth/presentation/auth_controller.dart';
import 'package:speedquiz/features/entitlements/data/billing_service.dart';
import 'package:speedquiz/features/entitlements/data/entitlements_repository.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// The premium pitch and its purchase/restore flow.
///
/// Shared by the bottom sheet (shown mid-game when a cap is hit) and the
/// full Premium screen reachable from Profile, so the billing logic has one
/// home rather than two drifting copies.
class PremiumOffer extends ConsumerStatefulWidget {
  const PremiumOffer({super.key, this.reason, this.onDone});

  final String? reason;

  /// Called after a successful purchase/restore, or when the player dismisses.
  final VoidCallback? onDone;

  @override
  ConsumerState<PremiumOffer> createState() => _PremiumOfferState();
}

class _PremiumOfferState extends ConsumerState<PremiumOffer> {
  bool _busy = false;

  static const _benefits = [
    (
      Icons.all_inclusive_rounded,
      'Unlimited unique questions',
      'No soft cap per topic when entitlements are enforced',
    ),
    (
      Icons.auto_awesome_rounded,
      'Unlimited custom topics',
      'Keep generating quizzes past the free daily limit',
    ),
    (
      Icons.favorite_rounded,
      'Support SpeedQuiz',
      'Fund the growing question bank and new game modes',
    ),
  ];

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      final productId =
          ref.read(entitlementsProvider).valueOrNull?.premiumProductId;
      ref.read(billingServiceProvider.notifier).refresh(productId: productId);
    });
  }

  void _finish() => widget.onDone?.call();

  Future<void> _onPrimary() async {
    final entitlements = ref.read(entitlementsProvider).valueOrNull;
    final billing = ref.read(billingServiceProvider.notifier);
    final allowDev = entitlements?.devToggleAllowed ?? false;

    setState(() => _busy = true);
    try {
      if (billing.canBuy) {
        final me = await billing.buyPremium();
        if (!mounted) return;
        if (me?.isPremium == true) {
          SqToast.success(context, 'Premium unlocked. Enjoy.');
          _finish();
        }
        return;
      }

      if (allowDev) {
        // Non-prod: exercise the verify pipeline with a stub token, then fall
        // back to the legacy dev toggle if verification is unavailable.
        try {
          final me = await billing.verifyStubPurchase();
          if (!mounted) return;
          if (me.isPremium) {
            SqToast.success(context, 'Premium enabled (stub purchase)');
            _finish();
          } else {
            SqToast.warning(context, 'Purchase verify returned free');
          }
          return;
        } catch (_) {
          final updated = await ref
              .read(entitlementsRepositoryProvider)
              .setDevPremium(enabled: true);
          ref.invalidate(entitlementsProvider);
          ref
              .read(authControllerProvider.notifier)
              .applyProgress(isPremium: updated.isPremium);
          if (!mounted) return;
          SqToast.success(context, 'Premium enabled (dev)');
          _finish();
          return;
        }
      }

      if (!mounted) return;
      SqToast.info(
        context,
        'Store billing is coming soon — nothing has been charged.',
      );
      _finish();
    } catch (error) {
      if (mounted) SqToast.error(context, apiErrorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onRestore() async {
    setState(() => _busy = true);
    try {
      final billing = ref.read(billingServiceProvider.notifier);
      final billingState = ref.read(billingServiceProvider);
      final allowDev =
          ref.read(entitlementsProvider).valueOrNull?.devToggleAllowed ?? false;
      final storeReachable = billing.canBuy ||
          (billingState is BillingIdle && billingState.storeAvailable);

      if (storeReachable) {
        final me = await billing.restore();
        if (!mounted) return;
        if (me?.isPremium == true) {
          SqToast.success(context, 'Purchases restored.');
          _finish();
        } else {
          SqToast.info(context, 'No premium purchase found on this account.');
        }
        return;
      }

      if (allowDev) {
        final me = await billing.verifyStubPurchase();
        if (!mounted) return;
        if (me.isPremium) {
          SqToast.success(context, 'Premium restored (stub)');
          _finish();
        } else {
          SqToast.info(context, 'Nothing to restore.');
        }
        return;
      }

      if (mounted) {
        SqToast.warning(context, 'Restore is unavailable on this device.');
      }
    } catch (error) {
      if (mounted) SqToast.error(context, apiErrorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _primaryLabel({
    required bool canBuy,
    required bool allowDev,
    required String? price,
  }) {
    if (canBuy) return price == null ? 'BUY PREMIUM' : 'BUY PREMIUM · $price';
    if (allowDev) return 'ENABLE PREMIUM (DEV)';
    return 'COMING SOON';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final entitlements = ref.watch(entitlementsProvider).valueOrNull;
    final billingState = ref.watch(billingServiceProvider);
    final billing = ref.read(billingServiceProvider.notifier);

    final allowDev = entitlements?.devToggleAllowed ?? false;
    final alreadyPremium = entitlements?.isPremium ?? false;
    final canBuy = billing.canBuy;
    final price = billing.product?.price;
    final loading = _busy || billingState is BillingBusy;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            width: 66,
            height: 66,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: AppColors.premiumGradient,
              borderRadius: BorderRadius.circular(AppRadii.md),
              boxShadow: AppShadows.glow(AppColors.gold, strength: 0.4),
            ),
            child: const Icon(
              Icons.workspace_premium_rounded,
              color: Color(0xFF201400),
              size: 32,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          alreadyPremium ? 'You’re Premium' : 'Go Premium',
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall,
        ),
        if (widget.reason != null) ...[
          const SizedBox(height: 6),
          Text(
            widget.reason!,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
        ],
        if (billingState is BillingIdle && billingState.message != null) ...[
          const SizedBox(height: 8),
          Text(
            billingState.message!,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppColors.warning,
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        for (var i = 0; i < _benefits.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: SqStagger(
              index: i,
              child: _Benefit(
                icon: _benefits[i].$1,
                title: _benefits[i].$2,
                subtitle: _benefits[i].$3,
              ),
            ),
          ),
        const SizedBox(height: AppSpacing.lg),
        if (alreadyPremium)
          SqButton(
            label: 'GOT IT',
            variant: SqButtonVariant.gold,
            onPressed: loading ? null : _finish,
          )
        else ...[
          SqButton(
            label: _primaryLabel(
              canBuy: canBuy,
              allowDev: allowDev,
              price: price,
            ),
            variant: SqButtonVariant.gold,
            icon: Icons.lock_open_rounded,
            loading: loading,
            onPressed: loading ? null : _onPrimary,
          ),
          const SizedBox(height: 4),
          Center(
            child: TextButton(
              onPressed: loading ? null : _onRestore,
              child: const Text('Restore purchases'),
            ),
          ),
          if (!canBuy && !allowDev)
            Text(
              'Buy unlocks once App Store / Play products are live. '
              'Nothing is charged until then.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: p.textFaint),
            ),
        ],
      ],
    );
  }
}

class _Benefit extends StatelessWidget {
  const _Benefit({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: p.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.gold.withValues(alpha: 0.16),
            ),
            child: Icon(icon, size: 17, color: AppColors.gold),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleSmall),
                const SizedBox(height: 1),
                Text(subtitle, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
