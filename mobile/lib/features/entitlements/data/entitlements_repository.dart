import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:quizverse/core/config/app_config.dart';
import 'package:quizverse/core/network/dio_client.dart';
import 'package:quizverse/features/entitlements/domain/entitlement_models.dart';

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
}

final entitlementsRepositoryProvider = Provider<EntitlementsRepository>((ref) {
  return EntitlementsRepository(ref.watch(dioProvider));
});

final entitlementsProvider =
    FutureProvider.autoDispose<EntitlementsMe>((ref) {
  return ref.watch(entitlementsRepositoryProvider).fetchMe();
});
