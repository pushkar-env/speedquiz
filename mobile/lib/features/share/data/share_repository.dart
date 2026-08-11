import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/config/app_config.dart';
import 'package:speedquiz/core/network/dio_client.dart';
import 'package:speedquiz/features/share/domain/share_models.dart';

class ShareRepository {
  ShareRepository(this._dio);

  final Dio _dio;

  Future<SharedResult> fetchSharedResult(String sessionId) async {
    final response = await _dio.get(
      '${AppConfig.apiPrefix}/share/results/$sessionId',
    );
    return SharedResult.fromJson(response.data as Map<String, dynamic>);
  }
}

final shareRepositoryProvider = Provider<ShareRepository>((ref) {
  return ShareRepository(ref.watch(dioProvider));
});

final sharedResultProvider =
    FutureProvider.autoDispose.family<SharedResult, String>((ref, sessionId) {
  return ref.watch(shareRepositoryProvider).fetchSharedResult(sessionId);
});
