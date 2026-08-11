import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/config/app_config.dart';
import 'package:speedquiz/core/network/dio_client.dart';
import 'package:speedquiz/features/auth/data/auth_token_store.dart';
import 'package:speedquiz/features/auth/domain/auth_models.dart';

class AuthRepository {
  AuthRepository(this._dio, this._tokenStore);

  final Dio _dio;
  final AuthTokenStore _tokenStore;

  Future<AuthSession> signInAsGuest() async {
    final response = await _dio.post(
      '${AppConfig.apiPrefix}/auth/guest',
      data: {'device_info': 'flutter'},
    );
    final session = AuthSession.fromJson(response.data as Map<String, dynamic>);
    await _tokenStore.saveTokens(
      accessToken: session.accessToken,
      refreshToken: session.refreshToken,
    );
    return session;
  }

  Future<AuthSession> signInWithGoogle(String idToken) async {
    final response = await _dio.post(
      '${AppConfig.apiPrefix}/auth/google',
      data: {'id_token': idToken},
    );
    final session = AuthSession.fromJson(response.data as Map<String, dynamic>);
    await _tokenStore.saveTokens(
      accessToken: session.accessToken,
      refreshToken: session.refreshToken,
    );
    return session;
  }

  Future<AuthUser?> fetchMe() async {
    final token = await _tokenStore.readAccessToken();
    if (token == null || token.isEmpty) return null;
    try {
      final response = await _dio.get('${AppConfig.apiPrefix}/auth/me');
      return AuthUser.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (error) {
      // Stale/invalid token after DB reset or JWT secret change.
      if (error.response?.statusCode == 401) {
        await _tokenStore.clear();
        return null;
      }
      rethrow;
    }
  }

  Future<void> signOut() => _tokenStore.clear();
}

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository(ref.watch(dioProvider), ref.watch(authTokenStoreProvider));
});
