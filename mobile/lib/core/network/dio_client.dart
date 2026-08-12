import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speedquiz/core/config/app_config.dart';
import 'package:speedquiz/core/i18n/language_providers.dart';
import 'package:speedquiz/features/auth/data/auth_token_store.dart';

final dioProvider = Provider<Dio>((ref) {
  final dio = Dio(
    BaseOptions(
      baseUrl: AppConfig.apiBaseUrl,
      connectTimeout: const Duration(seconds: 15),
      // Custom topic generation can take a while with a real LLM.
      receiveTimeout: const Duration(seconds: 120),
      headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
    ),
  );

  dio.interceptors.add(_AuthInterceptor(ref, dio));
  dio.interceptors.add(_LanguageInterceptor(ref));
  return dio;
});

/// Advertises the app language on every request.
///
/// Endpoints that localize take an explicit `language` parameter — this header
/// is the fallback for anything that does not, and it is what server logs and
/// analytics read to tell how many players are actually on each language.
///
/// It deliberately carries the *app* language: content language is a property
/// of a run, not of a connection, and travels in the request body where it
/// cannot be confused with chrome.
class _LanguageInterceptor extends Interceptor {
  _LanguageInterceptor(this._ref);

  final Ref _ref;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.headers['Accept-Language'] = _ref.read(appLanguageProvider).code;
    handler.next(options);
  }
}

class _AuthInterceptor extends Interceptor {
  _AuthInterceptor(this._ref, this._dio);

  final Ref _ref;
  final Dio _dio;
  static Future<bool>? _refreshing;

  AuthTokenStore get _store => _ref.read(authTokenStoreProvider);

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final token = await _store.readAccessToken();
    if (token != null && token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    // 1. Transparent retry for socket / connection abort drops on Android emulator / networks.
    final isConnectionAbort = err.error != null &&
        (err.error.toString().contains('Software caused connection abort') ||
            err.error.toString().contains('Connection closed'));
    final connectionRetried = err.requestOptions.extra['conn_retried'] == true;

    if (isConnectionAbort && !connectionRetried) {
      try {
        final req = err.requestOptions;
        req.extra['conn_retried'] = true;
        final response = await _dio.fetch(req);
        handler.resolve(response);
        return;
      } catch (_) {}
    }

    // 2. Token refresh for 401 Unauthorized errors.
    final status = err.response?.statusCode;
    final path = err.requestOptions.path;
    final alreadyRetried = err.requestOptions.extra['auth_retried'] == true;
    final isAuthEndpoint = path.contains('/auth/guest') ||
        path.contains('/auth/refresh') ||
        path.contains('/auth/login') ||
        path.contains('/auth/register') ||
        path.contains('/auth/google');

    if (status != 401 || alreadyRetried || isAuthEndpoint) {
      handler.next(err);
      return;
    }

    final refreshed = await _refreshTokens();
    if (!refreshed) {
      await _store.clear();
      handler.next(err);
      return;
    }

    try {
      final token = await _store.readAccessToken();
      final req = err.requestOptions;
      req.headers['Authorization'] = 'Bearer $token';
      req.extra['auth_retried'] = true;
      final response = await _dio.fetch(req);
      handler.resolve(response);
    } catch (e) {
      if (e is DioException) {
        handler.next(e);
      } else {
        handler.next(err);
      }
    }
  }

  Future<bool> _refreshTokens() async {
    if (_refreshing != null) return _refreshing!;
    _refreshing = _doRefresh();
    try {
      return await _refreshing!;
    } finally {
      _refreshing = null;
    }
  }

  Future<bool> _doRefresh() async {
    final refresh = await _store.readRefreshToken();
    if (refresh == null || refresh.isEmpty) return false;

    try {
      // Bare client avoids interceptor recursion.
      final bare = Dio(
        BaseOptions(
          baseUrl: AppConfig.apiBaseUrl,
          connectTimeout: const Duration(seconds: 12),
          receiveTimeout: const Duration(seconds: 20),
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
        ),
      );
      final response = await bare.post(
        '${AppConfig.apiPrefix}/auth/refresh',
        data: {'refresh_token': refresh},
      );
      final data = response.data as Map<String, dynamic>;
      final access = data['access_token'] as String?;
      final newRefresh = data['refresh_token'] as String?;
      if (access == null || newRefresh == null) return false;
      await _store.saveTokens(accessToken: access, refreshToken: newRefresh);
      return true;
    } catch (_) {
      return false;
    }
  }
}
