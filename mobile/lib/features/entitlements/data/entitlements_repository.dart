import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:quizverse/core/config/app_config.dart';
import 'package:quizverse/core/network/dio_client.dart';
import 'package:quizverse/features/entitlements/domain/entitlement_models.dart';

class PurchasePayload {
  const PurchasePayload({
    required this.platform,
    required this.productId,
    required this.purchaseToken,
    this.originalTransactionId,
  });

  final String platform;
  final String productId;
  final String purchaseToken;
  final String? originalTransactionId;

  Map<String, dynamic> toJson() => {
        'platform': platform,
        'product_id': productId,
        'purchase_token': purchaseToken,
        if (originalTransactionId != null)
          'original_transaction_id': originalTransactionId,
      };

  static String currentPlatform() {
    if (Platform.isIOS) return 'ios';
    if (Platform.isAndroid) return 'android';
    return 'android';
  }
}

class EntitlementsRepository {
  EntitlementsRepository(this._dio);

  final Dio _dio;

  Future<EntitlementsMe> fetchMe() async {
    final response = await _dio.get('${AppConfig.apiPrefix}/entitlements/me');
    return EntitlementsMe.fromJson(response.data as Map<String, dynamic>);
  }

  Future<EntitlementsMe> setDevPremium({required bool enabled}) async {
    final response = await _dio.post(
      '${AppConfig.apiPrefix}/entitlements/dev/premium',
      data: {'enabled': enabled},
    );
    return EntitlementsMe.fromJson(response.data as Map<String, dynamic>);
  }

  Future<EntitlementsMe> verifyPurchase(PurchasePayload purchase) async {
    final response = await _dio.post(
      '${AppConfig.apiPrefix}/entitlements/purchases/verify',
      data: purchase.toJson(),
    );
    return EntitlementsMe.fromJson(response.data as Map<String, dynamic>);
  }

  Future<EntitlementsMe> restorePurchases(List<PurchasePayload> purchases) async {
    final response = await _dio.post(
      '${AppConfig.apiPrefix}/entitlements/purchases/restore',
      data: {'purchases': purchases.map((p) => p.toJson()).toList()},
    );
    return EntitlementsMe.fromJson(response.data as Map<String, dynamic>);
  }
}

final entitlementsRepositoryProvider = Provider<EntitlementsRepository>((ref) {
  return EntitlementsRepository(ref.watch(dioProvider));
});

final entitlementsProvider =
    FutureProvider.autoDispose<EntitlementsMe>((ref) {
  return ref.watch(entitlementsRepositoryProvider).fetchMe();
});
