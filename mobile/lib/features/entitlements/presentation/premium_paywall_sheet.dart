import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:quizverse/core/network/api_errors.dart';
import 'package:quizverse/core/theme/app_theme.dart';
import 'package:quizverse/features/auth/presentation/auth_controller.dart';
import 'package:quizverse/features/entitlements/data/billing_service.dart';
import 'package:quizverse/features/entitlements/data/entitlements_repository.dart';
import 'package:quizverse/shared/widgets/qv_button.dart';

Future<void> showPremiumPaywall(
  BuildContext context, {
  String? reason,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => PremiumPaywallSheet(reason: reason),
  );
}

class PremiumPaywallSheet extends ConsumerStatefulWidget {
  const PremiumPaywallSheet({super.key, this.reason});

  final String? reason;

  @override
  ConsumerState<PremiumPaywallSheet> createState() =>
      _PremiumPaywallSheetState();
}

class _PremiumPaywallSheetState extends ConsumerState<PremiumPaywallSheet> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      final productId =
          ref.read(entitlementsProvider).valueOrNull?.premiumProductId;
      ref.read(billingServiceProvider.notifier).refresh(productId: productId);
    });
  }

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
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Premium unlocked')),
          );
          Navigator.of(context).pop();
        }
        return;
      }

      if (allowDev) {
        // Non-prod: exercise the verify pipeline with a stub token, then
        // fall back to the legacy toggle if verify fails.
        try {
          final me = await billing.verifyStubPurchase();
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                me.isPremium
                    ? 'Premium enabled (stub purchase)'
                    : 'Purchase verify returned free',
              ),
            ),
          );
          if (me.isPremium) Navigator.of(context).pop();
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
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Premium enabled (dev)')),
          );
          Navigator.of(context).pop();
          return;
        }
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Store billing is coming soon. Premium unlocks unlimited unique questions and custom topics.',
          ),
        ),
      );
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(apiErrorMessage(e))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onRestore() async {
    setState(() => _busy = true);
    try {
      final billing = ref.read(billingServiceProvider.notifier);
      final entitlements = ref.read(entitlementsProvider).valueOrNull;
      final allowDev = entitlements?.devToggleAllowed ?? false;

      if (billing.canBuy ||
          (ref.read(billingServiceProvider) is BillingIdle &&
              (ref.read(billingServiceProvider) as BillingIdle).storeAvailable)) {
        final me = await billing.restore();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              me?.isPremium == true
                  ? 'Purchases restored'
                  : 'No premium purchase found',
            ),
          ),
        );
        if (me?.isPremium == true) Navigator.of(context).pop();
        return;
      }

      if (allowDev) {
        final me = await billing.verifyStubPurchase();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              me.isPremium
                  ? 'Premium restored (stub)'
                  : 'Nothing to restore',
            ),
          ),
        );
        if (me.isPremium) Navigator.of(context).pop();
        return;
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Restore unavailable on this device')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(apiErrorMessage(e))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _primaryLabel({
    required bool alreadyPremium,
    required bool allowDev,
    required bool canBuy,
    required ProductPrice? price,
  }) {
    if (alreadyPremium) return 'GOT IT';
    if (canBuy) {
      final p = price?.label;
      return p == null ? 'BUY PREMIUM' : 'BUY PREMIUM · $p';
    }
    if (allowDev) return 'ENABLE PREMIUM (DEV)';
    return 'COMING SOON';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final entitlements = ref.watch(entitlementsProvider).valueOrNull;
    final billingState = ref.watch(billingServiceProvider);
    final billing = ref.read(billingServiceProvider.notifier);
    final allowDev = entitlements?.devToggleAllowed ?? false;
    final alreadyPremium = entitlements?.isPremium ?? false;
    final canBuy = billing.canBuy;
    final product = billing.product;
    final price = product == null
        ? null
        : ProductPrice(label: product.price);

    final busyFromBilling = billingState is BillingBusy;
    final loading = _busy || busyFromBilling;

    return Container(
      decoration: BoxDecoration(
        color: dark ? AppColors.surfaceDark : AppColors.surfaceLight,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.lg + MediaQuery.paddingOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: (dark ? Colors.white : Colors.black).withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            alreadyPremium ? "You're Premium" : 'Go Premium',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          if (widget.reason != null) ...[
            const SizedBox(height: 6),
            Text(widget.reason!, style: theme.textTheme.bodyMedium),
          ],
          if (billingState is BillingIdle && billingState.message != null) ...[
            const SizedBox(height: 6),
            Text(
              billingState.message!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.warning,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          const _Benefit(
            title: 'Unlimited unique questions',
            subtitle: 'No soft-cap when entitlements are enforced',
          ),
          const SizedBox(height: 10),
          const _Benefit(
            title: 'Unlimited custom topics',
            subtitle: 'Keep creating quizzes beyond the free daily limit',
          ),
          const SizedBox(height: 10),
          const _Benefit(
            title: 'Support QuizVerse',
            subtitle: 'Help us grow the question bank and polish the game',
          ),
          const SizedBox(height: AppSpacing.xl),
          if (alreadyPremium)
            QvButton(
              label: 'GOT IT',
              onPressed: loading ? null : () => Navigator.of(context).pop(),
            )
          else
            QvButton(
              label: _primaryLabel(
                alreadyPremium: alreadyPremium,
                allowDev: allowDev,
                canBuy: canBuy,
                price: price,
              ),
              onPressed: loading
                  ? null
                  : () {
                      if (alreadyPremium) {
                        Navigator.of(context).pop();
                        return;
                      }
                      _onPrimary();
                    },
            ),
          if (!alreadyPremium) ...[
            const SizedBox(height: 4),
            Center(
              child: TextButton(
                onPressed: loading ? null : _onRestore,
                child: const Text('Restore purchases'),
              ),
            ),
          ],
          if (!canBuy && !allowDev && !alreadyPremium) ...[
            Text(
              'Real App Store / Play products unlock Buy when configured. No charge until then.',
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }
}

class ProductPrice {
  const ProductPrice({required this.label});
  final String label;
}

class _Benefit extends StatelessWidget {
  const _Benefit({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.accent.withValues(alpha: 0.16),
          ),
          child: const Icon(Icons.check, size: 16, color: AppColors.accent),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(subtitle, style: theme.textTheme.bodyMedium),
            ],
          ),
        ),
      ],
    );
  }
}
