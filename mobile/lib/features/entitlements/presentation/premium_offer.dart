import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/i18n/l10n.dart';
import 'package:speedquiz/core/network/api_errors.dart';
import 'package:speedquiz/core/theme/app_theme.dart';
import 'package:speedquiz/features/auth/presentation/auth_controller.dart';
import 'package:speedquiz/features/entitlements/data/billing_service.dart';
import 'package:speedquiz/features/entitlements/data/entitlements_repository.dart';
import 'package:speedquiz/features/entitlements/presentation/subscription_status_card.dart';
import 'package:speedquiz/shared/widgets/sq_widgets.dart';

/// The premium pitch, plan picker and purchase flow.
///
/// Shared by the mid-game sheet and the full Premium screen so the billing
/// logic has one home rather than two drifting copies.
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
  String? _selectedPlan;

  static List<(IconData, String, String)> _benefits(SqStrings l10n) => [
        (
          Icons.all_inclusive_rounded,
          l10n.premiumBenefitQuestionsTitle,
          l10n.premiumBenefitQuestionsBody,
        ),
        (
          Icons.auto_awesome_rounded,
          l10n.premiumBenefitCustomTitle,
          l10n.premiumBenefitCustomBody,
        ),
        (
          Icons.palette_rounded,
          l10n.premiumBenefitCosmeticsTitle,
          l10n.premiumBenefitCosmeticsBody,
        ),
      ];

  @override
  void initState() {
    super.initState();
    Future.microtask(_loadOffers);
  }

  Future<void> _loadOffers() async {
    if (!mounted) return;
    try {
      final plans = await ref.read(premiumPlansProvider.future);
      if (!mounted) return;
      // Default to whichever plan the server marks as recommended.
      final recommended = plans.where((p) => p.recommended);
      _selectedPlan ??= recommended.isNotEmpty
          ? recommended.first.code
          : (plans.isNotEmpty ? plans.first.code : null);
      await ref.read(billingServiceProvider.notifier).refresh(plans: plans);
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() {});
    }
  }

  void _finish() => widget.onDone?.call();

  Future<void> _onPurchase() async {
    final entitlements = ref.read(entitlementsProvider).valueOrNull;
    final billing = ref.read(billingServiceProvider.notifier);
    final planCode = _selectedPlan;
    final allowDev = entitlements?.devToggleAllowed ?? false;

    setState(() => _busy = true);
    try {
      if (planCode != null && billing.offerFor(planCode)?.purchasable == true) {
        final me = await billing.buyPlan(
          planCode,
          // Ties the store purchase to this account, so a server notification
          // can be attributed even if the app never gets to call verify.
          accountId: ref.read(currentUserProvider)?.id,
          // Already subscribed means this is a plan switch, not a new sale.
          replaceExisting: entitlements?.isPremium ?? false,
        );
        if (!mounted) return;
        if (me?.isPremium == true) {
          SqToast.success(context, context.l10n.premiumUnlocked);
          _finish();
        }
        return;
      }

      // No store product — but the backend is in stub mode and will accept a
      // simulated purchase. Lets the whole paywall be exercised on a test
      // deployment before the store products exist.
      if (entitlements?.stubPurchaseAllowed == true) {
        final me = await billing.verifyStubPurchase(planCode: planCode);
        if (!mounted) return;
        if (me.isPremium) {
          SqToast.success(context, context.l10n.premiumUnlockedTest);
          _finish();
        } else {
          SqToast.warning(context, context.l10n.premiumVerifyReturnedFree);
        }
        return;
      }

      if (allowDev) {
        try {
          final me = await billing.verifyStubPurchase(planCode: planCode);
          if (!mounted) return;
          if (me.isPremium) {
            SqToast.success(context, context.l10n.premiumEnabledStub);
            _finish();
          } else {
            SqToast.warning(context, context.l10n.premiumVerifyReturnedFree);
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
          SqToast.success(context, context.l10n.premiumEnabledDev);
          _finish();
          return;
        }
      }

      if (!mounted) return;
      SqToast.info(context, context.l10n.premiumNotAvailableHere);
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
          SqToast.success(context, context.l10n.premiumRestored);
          _finish();
        } else {
          SqToast.info(context, context.l10n.premiumNoSubscription);
        }
        return;
      }

      if (allowDev) {
        final me = await billing.verifyStubPurchase(planCode: _selectedPlan);
        if (!mounted) return;
        if (me.isPremium) {
          SqToast.success(context, context.l10n.premiumRestoredStub);
          _finish();
        } else {
          SqToast.info(context, context.l10n.premiumNothingToRestore);
        }
        return;
      }

      if (mounted) {
        SqToast.warning(context, context.l10n.premiumRestoreUnavailable);
      }
    } catch (error) {
      if (mounted) SqToast.error(context, apiErrorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _primaryLabel({
    required SqStrings l10n,
    required bool canBuy,
    required bool allowDev,
    required bool stubAllowed,
    required bool isSwitch,
    required PlanOffer? offer,
  }) {
    if (canBuy) {
      if (isSwitch) {
        return l10n.premiumSwitchTo(
          offer?.plan.title.toUpperCase() ?? l10n.premiumSubscribe,
        );
      }
      final price = offer?.price;
      return price == null
          ? l10n.premiumSubscribe
          : l10n.premiumSubscribeWithPrice(price);
    }
    if (stubAllowed) {
      final title = offer?.plan.title.toUpperCase();
      return title == null
          ? l10n.premiumTestPurchase
          : l10n.premiumTestPurchaseWith(title);
    }
    if (allowDev) return l10n.premiumEnableDev;
    return l10n.premiumUnavailable;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final benefits = _benefits(context.l10n);
    final entitlements = ref.watch(entitlementsProvider).valueOrNull;
    final billingState = ref.watch(billingServiceProvider);
    final billing = ref.read(billingServiceProvider.notifier);
    final isGuest = ref.watch(currentUserProvider)?.isGuest ?? false;

    final allowDev = entitlements?.devToggleAllowed ?? false;
    final stubAllowed = entitlements?.stubPurchaseAllowed ?? false;
    final alreadyPremium = entitlements?.isPremium ?? false;
    final offers = billing.offers;
    final selectedOffer =
        _selectedPlan == null ? null : billing.offerFor(_selectedPlan!);
    final canBuy = selectedOffer?.purchasable ?? false;
    final loading = _busy || billingState is BillingBusy;
    final pending = billingState is BillingPending;

    // A player who already subscribed sees the other plan as a switch.
    final isSwitch = alreadyPremium &&
        entitlements?.planCode != null &&
        entitlements?.planCode != _selectedPlan;

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
          alreadyPremium
              ? context.l10n.premiumYourePremium
              : context.l10n.profileGoPremium,
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

        if (alreadyPremium && entitlements != null) ...[
          const SizedBox(height: AppSpacing.md),
          SubscriptionStatusCard(entitlements: entitlements),
        ],

        if (stubAllowed) ...[
          const SizedBox(height: AppSpacing.md),
          _Notice(
            icon: Icons.science_rounded,
            tone: AppColors.cyan,
            message: context.l10n.premiumTestModeNote,
          ),
        ],

        if (pending) ...[
          const SizedBox(height: AppSpacing.md),
          _Notice(
            icon: Icons.hourglass_top_rounded,
            tone: AppColors.warning,
            message: _noticeText(
              context,
              (billingState).notice,
              (billingState).message,
            ),
          ),
        ] else if (!stubAllowed &&
            billingState is BillingIdle &&
            billingState.message != null) ...[
          const SizedBox(height: AppSpacing.md),
          _Notice(
            icon: Icons.info_outline_rounded,
            tone: AppColors.warning,
            message: _noticeText(
              context,
              billingState.notice,
              billingState.message!,
            ),
          ),
        ],

        const SizedBox(height: AppSpacing.lg),
        for (var i = 0; i < benefits.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: SqStagger(
              index: i,
              child: _Benefit(
                icon: benefits[i].$1,
                title: benefits[i].$2,
                subtitle: benefits[i].$3,
              ),
            ),
          ),

        if (!alreadyPremium || isSwitch) ...[
          const SizedBox(height: AppSpacing.sm),
          for (final offer in offers)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _PlanTile(
                offer: offer,
                offers: offers,
                selected: offer.plan.code == _selectedPlan,
                currentPlan: entitlements?.planCode == offer.plan.code,
                // In test mode the store has no products, but the plan is
                // still selectable so the flow can be walked end to end.
                selectable: offer.purchasable || stubAllowed,
                onTap: loading
                    ? null
                    : () => setState(() => _selectedPlan = offer.plan.code),
              ),
            ),
        ],

        const SizedBox(height: AppSpacing.md),

        if (alreadyPremium && !isSwitch)
          SqButton(
            label: context.l10n.gotIt,
            variant: SqButtonVariant.gold,
            onPressed: loading ? null : _finish,
          )
        else ...[
          SqButton(
            label: _primaryLabel(
              l10n: context.l10n,
              canBuy: canBuy,
              allowDev: allowDev,
              stubAllowed: stubAllowed,
              isSwitch: isSwitch,
              offer: selectedOffer,
            ),
            variant: SqButtonVariant.gold,
            icon: Icons.lock_open_rounded,
            loading: loading,
            onPressed: loading || pending ? null : _onPurchase,
          ),
          const SizedBox(height: 4),
          Center(
            child: TextButton(
              onPressed: loading ? null : _onRestore,
              child: Text(context.l10n.premiumRestorePurchases),
            ),
          ),

          if (isGuest && !alreadyPremium)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _Notice(
                icon: Icons.person_outline_rounded,
                tone: AppColors.cyan,
                // Without a linked identity a reinstall creates a new account,
                // and recovering the subscription depends on the store's
                // restore flow alone.
                message: context.l10n.premiumSignInNote,
              ),
            ),

          // Both stores require the renewal terms to be visible on the screen
          // that starts the purchase.
          Text(
            _legalCopy(context.l10n, selectedOffer),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: p.textFaint),
          ),
        ],
      ],
    );
  }

  /// Renewal terms. Both stores require these to be visible on the screen
  /// that starts a purchase, so they follow the reader's language.
  String _legalCopy(SqStrings l10n, PlanOffer? offer) {
    final period = offer?.plan.isAnnual == true
        ? l10n.periodYear
        : l10n.periodMonth;
    final price = offer?.price;
    final opening = price == null
        ? l10n.premiumRenewsAutomatically
        : l10n.premiumRenewsAt(price, period);
    return '$opening ${l10n.premiumCancelAnytime(_storeName())}';
  }

  /// Billing copy the app owns is localized; anything the store said is shown
  /// exactly as the store said it.
  String _noticeText(BuildContext context, BillingNotice notice, String raw) {
    final l10n = context.l10n;
    return switch (notice) {
      BillingNotice.openingStore => l10n.billingOpeningStore,
      BillingNotice.restoring => l10n.billingRestoring,
      BillingNotice.verifying => l10n.billingVerifying,
      BillingNotice.couldNotStart => l10n.billingCouldNotStart,
      BillingNotice.purchaseFailed => l10n.billingPurchaseFailed,
      BillingNotice.waitingForPayment => l10n.billingWaitingForPayment,
      BillingNotice.storeUnavailable => l10n.billingStoreUnavailable,
      BillingNotice.noPlans => l10n.billingNoPlans,
      BillingNotice.none => raw,
    };
  }

  String _storeName() {
    final platform = ref.read(entitlementsProvider).valueOrNull?.platform;
    if (platform == 'ios') return 'App Store';
    return 'Google Play';
  }
}

/// Renders one plan with the store's own localised price.
class _PlanTile extends StatelessWidget {
  const _PlanTile({
    required this.offer,
    required this.offers,
    required this.selected,
    required this.currentPlan,
    required this.selectable,
    required this.onTap,
  });

  final PlanOffer offer;
  final List<PlanOffer> offers;
  final bool selected;
  final bool currentPlan;

  /// False only when the store has no product *and* no test purchase is
  /// available — i.e. there is genuinely no way to buy this plan.
  final bool selectable;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = theme.sq;
    final savings = offer.savingsPercentAgainst(offers);
    final unavailable = !selectable;
    // Test mode: no store price to show, so name the billing period instead of
    // leaving a bare dash.
    final priceLabel = offer.price ??
        (selectable ? (offer.plan.isAnnual ? 'per year' : 'per month') : '—');

    return SqPressable(
      onTap: unavailable ? null : onTap,
      haptic: true,
      pressedScale: 0.98,
      semanticLabel: '${offer.plan.title} plan',
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          color: selected ? AppColors.gold.withValues(alpha: 0.10) : p.surface,
          borderRadius: BorderRadius.circular(AppRadii.md),
          border: Border.all(
            color: selected ? AppColors.gold : p.border,
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Opacity(
          opacity: unavailable ? 0.5 : 1,
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 20,
                color: selected ? AppColors.gold : p.textFaint,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(offer.plan.title, style: theme.textTheme.titleSmall),
                        if (offer.plan.badge != null) ...[
                          const SizedBox(width: 8),
                          _Chip(label: offer.plan.badge!, color: AppColors.gold),
                        ],
                        if (currentPlan) ...[
                          const SizedBox(width: 8),
                          _Chip(
                            label: context.l10n.premiumCurrent,
                            color: AppColors.cyan,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      unavailable
                          ? context.l10n.premiumNotOnThisDevice
                          : offer.plan.subtitle,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    priceLabel,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: selected ? AppColors.gold : null,
                    ),
                  ),
                  if (savings != null)
                    Text(
                      context.l10n.premiumSavePercent(savings),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppColors.success,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: color,
              fontSize: 9,
              letterSpacing: 0.6,
            ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.tone,
    required this.message,
  });

  final IconData icon;
  final Color tone;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadii.sm),
        border: Border.all(color: tone.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: tone),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(color: tone),
            ),
          ),
        ],
      ),
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
