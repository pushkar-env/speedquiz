import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:quizverse/features/auth/presentation/auth_controller.dart';
import 'package:quizverse/features/entitlements/data/entitlements_repository.dart';
import 'package:quizverse/features/entitlements/domain/entitlement_models.dart';

sealed class BillingState {
  const BillingState();
}

class BillingIdle extends BillingState {
  const BillingIdle({
    this.storeAvailable = false,
    this.product,
    this.message,
  });

  final bool storeAvailable;
  final ProductDetails? product;
  final String? message;
}

class BillingBusy extends BillingState {
  const BillingBusy(this.message);
  final String message;
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
  String _productId = 'quizverse_premium';
  Completer<EntitlementsMe?>? _pendingBuy;

  @override
  void dispose() {
    _purchaseSub?.cancel();
    super.dispose();
  }

  Future<void> refresh({String? productId}) async {
    if (productId != null && productId.isNotEmpty) {
      _productId = productId;
    }
    final available = await _iap.isAvailable();
    if (!available) {
      state = const BillingIdle(
        storeAvailable: false,
        message: 'Store not available on this device',
      );
      return;
    }

    final response = await _iap.queryProductDetails({_productId});
    if (response.error != null) {
      state = BillingIdle(
        storeAvailable: true,
        message: response.error!.message,
      );
      return;
    }
    final product = response.productDetails.isEmpty
        ? null
        : response.productDetails.first;
    state = BillingIdle(
      storeAvailable: true,
      product: product,
      message: product == null
          ? 'Product $_productId not found in the store'
          : null,
    );
  }

  bool get canBuy {
    final s = state;
    return s is BillingIdle && s.storeAvailable && s.product != null;
  }

  ProductDetails? get product {
    final s = state;
    return s is BillingIdle ? s.product : null;
  }

  Future<EntitlementsMe?> buyPremium() async {
    final s = state;
    if (s is! BillingIdle || s.product == null) {
      return null;
    }
    state = const BillingBusy('Starting purchase…');
    _pendingBuy = Completer<EntitlementsMe?>();
    final launched = await _iap.buyNonConsumable(
      purchaseParam: PurchaseParam(productDetails: s.product!),
    );
    if (!launched) {
      state = BillingIdle(
        storeAvailable: s.storeAvailable,
        product: s.product,
        message: 'Could not start purchase',
      );
      final c = _pendingBuy;
      _pendingBuy = null;
      c?.complete(null);
      return null;
    }
    return _pendingBuy!.future;
  }

  Future<EntitlementsMe?> restore() async {
    final s = state;
    state = const BillingBusy('Restoring purchases…');
    try {
      await _iap.restorePurchases();
      // Restored items arrive on purchaseStream; give it a moment.
      await Future<void>.delayed(const Duration(milliseconds: 800));
      final me = await _ref.read(entitlementsRepositoryProvider).fetchMe();
      _ref.invalidate(entitlementsProvider);
      _ref.read(authControllerProvider.notifier).applyProgress(
            isPremium: me.isPremium,
          );
      state = BillingIdle(
        storeAvailable: s is BillingIdle ? s.storeAvailable : true,
        product: s is BillingIdle ? s.product : null,
      );
      return me;
    } catch (e) {
      state = BillingIdle(
        storeAvailable: s is BillingIdle ? s.storeAvailable : false,
        product: s is BillingIdle ? s.product : null,
        message: e.toString(),
      );
      rethrow;
    }
  }

  /// Dev / emulator path: verify a synthetic token against the stub API.
  Future<EntitlementsMe> verifyStubPurchase() async {
    state = const BillingBusy('Verifying…');
    final token =
        'stub_${DateTime.now().millisecondsSinceEpoch}_$_productId';
    final me = await _ref.read(entitlementsRepositoryProvider).verifyPurchase(
          PurchasePayload(
            platform: PurchasePayload.currentPlatform(),
            productId: _productId,
            purchaseToken: token,
            originalTransactionId: token,
          ),
        );
    _ref.invalidate(entitlementsProvider);
    _ref.read(authControllerProvider.notifier).applyProgress(
          isPremium: me.isPremium,
        );
    final prev = state;
    state = BillingIdle(
      storeAvailable: prev is BillingIdle ? prev.storeAvailable : false,
      product: prev is BillingIdle ? prev.product : null,
    );
    return me;
  }

  Future<void> _onPurchaseUpdates(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      if (purchase.status == PurchaseStatus.pending) {
        state = const BillingBusy('Waiting for store…');
        continue;
      }

      if (purchase.status == PurchaseStatus.error) {
        state = BillingIdle(
          storeAvailable: true,
          product: product,
          message: purchase.error?.message ?? 'Purchase failed',
        );
        _completePending(null);
        continue;
      }

      if (purchase.status == PurchaseStatus.canceled) {
        state = BillingIdle(
          storeAvailable: true,
          product: product,
          message: 'Purchase canceled',
        );
        _completePending(null);
        continue;
      }

      if (purchase.status == PurchaseStatus.purchased ||
          purchase.status == PurchaseStatus.restored) {
        try {
          final me = await _verifyStorePurchase(purchase);
          if (purchase.pendingCompletePurchase) {
            await _iap.completePurchase(purchase);
          }
          _completePending(me);
          state = BillingIdle(
            storeAvailable: true,
            product: product,
          );
        } catch (e) {
          debugPrint('purchase_verify_failed: $e');
          state = BillingIdle(
            storeAvailable: true,
            product: product,
            message: e.toString(),
          );
          _completePending(null);
        }
      }
    }
  }

  Future<EntitlementsMe> _verifyStorePurchase(PurchaseDetails purchase) async {
    final token = purchase.verificationData.serverVerificationData;
    final local = purchase.verificationData.localVerificationData;
    final purchaseToken = token.isNotEmpty ? token : local;
    final me = await _ref.read(entitlementsRepositoryProvider).verifyPurchase(
          PurchasePayload(
            platform: PurchasePayload.currentPlatform(),
            productId: purchase.productID,
            purchaseToken: purchaseToken,
            originalTransactionId: purchase.purchaseID ?? purchaseToken,
          ),
        );
    _ref.invalidate(entitlementsProvider);
    _ref.read(authControllerProvider.notifier).applyProgress(
          isPremium: me.isPremium,
        );
    return me;
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
