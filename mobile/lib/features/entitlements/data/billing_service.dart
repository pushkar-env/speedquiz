import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart';
import 'package:speedquiz/features/auth/presentation/auth_controller.dart';
import 'package:speedquiz/features/entitlements/data/entitlements_repository.dart';
import 'package:speedquiz/features/entitlements/domain/entitlement_models.dart';

/// A plan paired with the store's own product record.
///
/// [details] is null when the store has no such product — usually because the
/// SKU has not finished propagating in the console, which is normal for a few
/// hours after creating it and permanent if the id is misspelt.
class PlanOffer {
  const PlanOffer({required this.plan, this.details});

  final PremiumPlan plan;
  final ProductDetails? details;

  bool get purchasable => details != null;

  /// Localised, tax-inclusive price string straight from the store —
  /// "₹399.00" or "$4.99" depending on the account's country.
  String? get price => details?.price;

  double? get rawPrice => details?.rawPrice;
  String? get currencyCode => details?.currencyCode;

  /// Price per month, for comparing an annual plan against a monthly one.
  double? get monthlyEquivalent {
    final raw = details?.rawPrice;
    if (raw == null || plan.months <= 0) return null;
    return raw / plan.months;
  }

  /// How much cheaper per month this plan is than the shortest one on offer.
  ///
  /// Derived from real store prices rather than a hardcoded number, so the
  /// claim stays true in every currency and survives a price change in either
  /// console without shipping a new build. Returns null when there is nothing
  /// honest to claim.
  int? savingsPercentAgainst(Iterable<PlanOffer> others) {
    final mine = monthlyEquivalent;
    if (mine == null || plan.months <= 1) return null;

    double? baseline;
    for (final other in others) {
      if (other.plan.months != 1) continue;
      final monthly = other.monthlyEquivalent;
      if (monthly == null) continue;
      if (baseline == null || monthly > baseline) baseline = monthly;
    }
    if (baseline == null || baseline <= 0) return null;

    // Comparing across currencies would be meaningless.
    final saved = ((baseline - mine) / baseline * 100).round();
    return saved > 0 ? saved : null;
  }
}

/// Copy this service owns, as a code rather than a sentence.
///
/// A `StateNotifier` has no `BuildContext`, and giving it a string table would
/// pin it to whatever language was active when it was created. So it names the
/// situation and the widget words it. Anything the *store* said — a decline
/// reason, a missing product id — stays in [BillingState.message] verbatim:
/// inventing a translation for text we did not write would be worse than
/// showing it as-is.
enum BillingNotice {
  none,
  openingStore,
  restoring,
  verifying,
  couldNotStart,
  purchaseFailed,
  waitingForPayment,
  storeUnavailable,
  noPlans,
}

sealed class BillingState {
  const BillingState();
}

class BillingIdle extends BillingState {
  const BillingIdle({
    this.storeAvailable = false,
    this.offers = const [],
    this.message,
    this.notice = BillingNotice.none,
  });

  final bool storeAvailable;
  final List<PlanOffer> offers;
  final String? message;
  final BillingNotice notice;

  bool get hasPurchasableOffer => offers.any((o) => o.purchasable);
}

class BillingBusy extends BillingState {
  const BillingBusy(this.message, {this.notice = BillingNotice.none});
  final String message;
  final BillingNotice notice;
}

/// A purchase is awaiting payment.
///
/// UPI, net banking and wallet payments on Play settle asynchronously and are
/// the dominant payment methods in India — treating this as a failure would
/// tell a paying user their purchase did not work. The entitlement arrives via
/// the store's server notification once the payment clears.
class BillingPending extends BillingState {
  const BillingPending(this.message, {this.notice = BillingNotice.none});
  final String message;
  final BillingNotice notice;
}

class BillingService extends StateNotifier<BillingState> {
  BillingService(this._ref)
      : _iap = InAppPurchase.instance,
        super(const BillingIdle()) {
    _purchaseSub = _iap.purchaseStream.listen(
      _onPurchaseUpdates,
      onError: (Object e) {
        state = BillingIdle(
          storeAvailable: false,
          message: 'Purchase stream error: $e',
        );
      },
    );
  }

  final Ref _ref;
  final InAppPurchase _iap;
  StreamSubscription<List<PurchaseDetails>>? _purchaseSub;

  List<PremiumPlan> _plans = const [];
  final Map<String, ProductDetails> _details = {};
  Completer<EntitlementsMe?>? _pendingBuy;

  @override
  void dispose() {
    _purchaseSub?.cancel();
    super.dispose();
  }

  List<PlanOffer> get offers => [
        for (final plan in _plans)
          PlanOffer(plan: plan, details: _details[plan.productId]),
      ];

  PlanOffer? offerFor(String planCode) {
    for (final offer in offers) {
      if (offer.plan.code == planCode) return offer;
    }
    return null;
  }

  /// Load the plan catalog and ask the store to price it.
  Future<void> refresh({List<PremiumPlan>? plans}) async {
    if (plans != null) _plans = plans;
    if (_plans.isEmpty) {
      state = const BillingIdle(
        storeAvailable: false,
        message: 'No plans configured',
        notice: BillingNotice.noPlans,
      );
      return;
    }

    final available = await _iap.isAvailable();
    if (!available) {
      state = BillingIdle(
        storeAvailable: false,
        offers: offers,
        message: 'Store not available on this device',
        notice: BillingNotice.storeUnavailable,
      );
      return;
    }

    final ids = _plans.map((p) => p.productId).toSet();
    final response = await _iap.queryProductDetails(ids);

    _details.clear();
    for (final product in response.productDetails) {
      // A Play subscription with several base plans or offers yields one
      // ProductDetails per offer under the same id. Keep the first — our
      // products carry a single base plan each, so the rest are intro offers
      // the store applies automatically at purchase time.
      _details.putIfAbsent(product.id, () => product);
    }

    final missing = response.notFoundIDs;
    state = BillingIdle(
      storeAvailable: true,
      offers: offers,
      message: response.error?.message ??
          (missing.isNotEmpty && _details.isEmpty
              ? 'Products not found in the store: ${missing.join(', ')}'
              : null),
    );
  }

  bool get canBuy {
    final s = state;
    return s is BillingIdle && s.storeAvailable && s.hasPurchasableOffer;
  }

  /// Start a purchase for [planCode].
  ///
  /// [accountId] is passed to the store as the obfuscated account id
  /// (Play) / app account token (StoreKit). That is what lets a server
  /// notification be attributed to this account even when the app never gets
  /// to call verify — the phone died, the network dropped, or a UPI payment
  /// settled hours later.
  Future<EntitlementsMe?> buyPlan(
    String planCode, {
    String? accountId,
    bool replaceExisting = false,
  }) async {
    final offer = offerFor(planCode);
    final details = offer?.details;
    if (details == null) return null;

    GooglePlayPurchaseDetails? oldPurchase;
    if (Platform.isAndroid && replaceExisting) {
      oldPurchase = await _resolveActiveAndroidSubscription();
    }

    state = const BillingBusy(
      'Opening the store…',
      notice: BillingNotice.openingStore,
    );
    _pendingBuy = Completer<EntitlementsMe?>();

    try {
      final launched = await _iap.buyNonConsumable(
        purchaseParam: _purchaseParam(
          details,
          accountId: accountId,
          oldPurchase: oldPurchase,
        ),
      );
      if (!launched) {
        _resetIdle(
          message: 'Could not start purchase',
          notice: BillingNotice.couldNotStart,
        );
        _completePending(null);
        return null;
      }
    } catch (e) {
      _resetIdle(message: e.toString());
      _completePending(null);
      rethrow;
    }

    return _pendingBuy!.future;
  }

  /// The Play purchase a plan switch should replace.
  ///
  /// Monthly and annual are separate Play products, so without this Play would
  /// happily sell the second one alongside the first and bill for both. If the
  /// stream has not delivered the existing purchase this session, ask the
  /// store to replay it.
  Future<GooglePlayPurchaseDetails?> _resolveActiveAndroidSubscription() async {
    if (_activeAndroidSubscription != null) return _activeAndroidSubscription;
    try {
      await _iap.restorePurchases();
      await Future<void>.delayed(const Duration(milliseconds: 900));
    } catch (e) {
      debugPrint('restore_before_switch_failed: $e');
    }
    return _activeAndroidSubscription;
  }

  PurchaseParam _purchaseParam(
    ProductDetails details, {
    String? accountId,
    GooglePlayPurchaseDetails? oldPurchase,
  }) {
    if (Platform.isAndroid) {
      return GooglePlayPurchaseParam(
        productDetails: details,
        applicationUserName: accountId,
        // Present only when moving between plans: Play credits the unused
        // remainder rather than leaving two subscriptions running.
        changeSubscriptionParam: oldPurchase == null
            ? null
            : ChangeSubscriptionParam(
                oldPurchaseDetails: oldPurchase,
                replacementMode: ReplacementMode.withTimeProration,
              ),
      );
    }
    return AppStorePurchaseParam(
      productDetails: details,
      applicationUserName: accountId,
    );
  }

  /// The live Play subscription, kept so a plan switch can reference it.
  GooglePlayPurchaseDetails? _activeAndroidSubscription;

  Future<EntitlementsMe?> restore() async {
    final previous = state;
    state = const BillingBusy(
      'Restoring purchases…',
      notice: BillingNotice.restoring,
    );
    try {
      await _iap.restorePurchases();
      // Restored items arrive on purchaseStream; give it a moment to drain
      // before asking the server what it now knows.
      await Future<void>.delayed(const Duration(milliseconds: 900));
      final me = await _ref.read(entitlementsRepositoryProvider).fetchMe();
      _syncEntitlements(me);
      state = BillingIdle(
        storeAvailable: previous is BillingIdle ? previous.storeAvailable : true,
        offers: offers,
      );
      return me;
    } catch (e) {
      _resetIdle(message: e.toString());
      rethrow;
    }
  }

  /// Dev / emulator path: exercise the verify pipeline with a synthetic token.
  Future<EntitlementsMe> verifyStubPurchase({String? planCode}) async {
    state = const BillingBusy('Verifying…', notice: BillingNotice.verifying);
    final productId = planCode == null
        ? (_plans.isEmpty ? 'speedquiz_premium_monthly' : _plans.first.productId)
        : (offerFor(planCode)?.plan.productId ?? _plans.first.productId);
    final token = 'stub_${DateTime.now().millisecondsSinceEpoch}_$productId';

    final me = await _ref.read(entitlementsRepositoryProvider).verifyPurchase(
          PurchasePayload(
            platform: PurchasePayload.currentPlatform(),
            productId: productId,
            purchaseToken: token,
            originalTransactionId: token,
          ),
        );
    _syncEntitlements(me);
    _resetIdle();
    return me;
  }

  Future<void> _onPurchaseUpdates(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      switch (purchase.status) {
        case PurchaseStatus.pending:
          // Do not complete the pending buy — the payment is still in flight
          // and the server will hear about it from the store.
          state = const BillingPending(
            'Waiting for your payment to clear. '
            'Premium unlocks automatically once it does.',
            notice: BillingNotice.waitingForPayment,
          );
          continue;

        case PurchaseStatus.error:
          _resetIdle(
            message: purchase.error?.message ?? 'Purchase failed',
            // Only ours when the store gave no reason of its own.
            notice: purchase.error?.message == null
                ? BillingNotice.purchaseFailed
                : BillingNotice.none,
          );
          _completePending(null);
          continue;

        case PurchaseStatus.canceled:
          _resetIdle();
          _completePending(null);
          continue;

        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          await _handleSuccessfulPurchase(purchase);
          continue;
      }
    }
  }

  Future<void> _handleSuccessfulPurchase(PurchaseDetails purchase) async {
    if (purchase is GooglePlayPurchaseDetails) {
      _activeAndroidSubscription = purchase;
    }

    try {
      final me = await _verifyStorePurchase(purchase);
      _completePending(me);
      _resetIdle();
    } catch (e) {
      debugPrint('purchase_verify_failed: $e');
      _resetIdle(message: e.toString());
      _completePending(null);
    } finally {
      // Always complete the purchase, even if our verification call failed.
      // Play refunds anything left unacknowledged for three days, and StoreKit
      // replays an uncompleted transaction on every launch. A verify failure
      // is recoverable server-side; a refund is not.
      if (purchase.pendingCompletePurchase) {
        try {
          await _iap.completePurchase(purchase);
        } catch (e) {
          debugPrint('complete_purchase_failed: $e');
        }
      }
    }
  }

  Future<EntitlementsMe> _verifyStorePurchase(PurchaseDetails purchase) async {
    final serverToken = purchase.verificationData.serverVerificationData;
    final localToken = purchase.verificationData.localVerificationData;
    final purchaseToken = serverToken.isNotEmpty ? serverToken : localToken;

    final me = await _ref.read(entitlementsRepositoryProvider).verifyPurchase(
          PurchasePayload(
            platform: PurchasePayload.currentPlatform(),
            productId: purchase.productID,
            purchaseToken: purchaseToken,
            originalTransactionId: purchase.purchaseID ?? purchaseToken,
          ),
        );
    _syncEntitlements(me);
    return me;
  }

  void _syncEntitlements(EntitlementsMe me) {
    _ref.invalidate(entitlementsProvider);
    _ref.read(authControllerProvider.notifier).applyProgress(
          isPremium: me.isPremium,
        );
  }

  void _resetIdle({String? message, BillingNotice notice = BillingNotice.none}) {
    final s = state;
    state = BillingIdle(
      storeAvailable: s is BillingIdle ? s.storeAvailable : true,
      offers: offers,
      message: message,
      notice: notice,
    );
  }

  void _completePending(EntitlementsMe? me) {
    final c = _pendingBuy;
    _pendingBuy = null;
    if (c != null && !c.isCompleted) {
      c.complete(me);
    }
  }
}

final billingServiceProvider =
    StateNotifierProvider<BillingService, BillingState>((ref) {
  return BillingService(ref);
});
