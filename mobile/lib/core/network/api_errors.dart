import 'package:dio/dio.dart';

/// Extract a human-readable message from QuizVerse API / Dio errors.
///
/// Supports:
/// - `{ "detail": "..." }`
/// - `{ "detail": { "message": "...", "code": "..." } }`
/// - `{ "error": { "message": "..." } }` (app envelope)
String apiErrorMessage(
  Object error, {
  String fallback = 'Something went wrong. Please try again.',
}) {
  if (error is! DioException) {
    return fallback;
  }

  final data = error.response?.data;
  final fromBody = _messageFromBody(data);
  if (fromBody != null && fromBody.isNotEmpty) {
    return fromBody;
  }

  switch (error.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
      return 'Request timed out. Check your connection and try again.';
    case DioExceptionType.connectionError:
      return 'Cannot reach the server. Is the API running?';
    case DioExceptionType.badResponse:
      final code = error.response?.statusCode;
      if (code == 401) {
        return 'Session expired. Go home and reopen the app to sign in again.';
      }
      if (code == 429) {
        return 'Too many requests. Please wait a moment and try again.';
      }
      break;
    default:
      break;
  }

  return fallback;
}

String? _messageFromBody(Object? data) {
  if (data is! Map) return null;

  final detail = data['detail'];
  final fromDetail = _coerceMessage(detail);
  if (fromDetail != null) return fromDetail;

  final error = data['error'];
  if (error is Map) {
    return _coerceMessage(error['message']);
  }
  return null;
}

String? _coerceMessage(Object? value) {
  if (value is String && value.trim().isNotEmpty) {
    return value.trim();
  }
  if (value is Map) {
    final message = value['message'];
    if (message is String && message.trim().isNotEmpty) {
      return message.trim();
    }
  }
  return null;
}

/// True when the API signaled free unique-question cap.
bool isEntitlementUniqueCap(Object error) {
  if (error is! DioException) return false;
  final data = error.response?.data;
  if (data is! Map) return false;
  final detail = data['detail'];
  if (detail is Map && detail['code'] == 'entitlement_unique_cap') {
    return true;
  }
  final nested = data['error'];
  if (nested is Map) {
    final message = nested['message'];
    if (message is Map && message['code'] == 'entitlement_unique_cap') {
      return true;
    }
  }
  return false;
}
