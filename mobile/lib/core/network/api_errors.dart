import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:speedquiz/core/i18n/l10n.dart';

/// Extract a human-readable message from SpeedQuiz API / Dio errors.
///
/// Supports:
/// - `{ "detail": "..." }`
/// - `{ "detail": { "message": "...", "code": "..." } }`
/// - `{ "error": { "message": "..." } }` (app envelope)
///
/// Server-sent prose comes back as-is: the API speaks one language, and
/// inventing a translation for a message we did not write would be worse than
/// showing it verbatim. Anything the *client* words — timeouts, connection
/// failures, the default fallback — is localized, which covers the failures a
/// player actually hits day to day. See [localizedApiErrorMessage] for the
/// context-aware entry point.
String apiErrorMessage(
  Object error, {
  String fallback = 'Something went wrong. Please try again.',
  SqStrings? strings,
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
      return strings?.errorTimeout ??
          'Request timed out. Check your connection and try again.';
    case DioExceptionType.connectionError:
      return strings?.errorNoConnection ??
          'Cannot reach the server. Is the API running?';
    case DioExceptionType.badResponse:
      final code = error.response?.statusCode;
      if (code == 401) {
        return strings?.errorSessionExpired ??
            'Session expired. Go home and reopen the app to sign in again.';
      }
      if (code == 429) {
        return strings?.errorTooManyRequests ??
            'Too many requests. Please wait a moment and try again.';
      }
      break;
    default:
      break;
  }

  return fallback;
}

/// [apiErrorMessage] with the active language wired in.
///
/// Use this anywhere a `BuildContext` is in reach; the bare function stays for
/// controllers and repositories that have none.
String localizedApiErrorMessage(
  BuildContext context,
  Object error, {
  String? fallback,
}) {
  final strings = context.l10n;
  return apiErrorMessage(
    error,
    fallback: fallback ?? strings.errorGeneric,
    strings: strings,
  );
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

/// The machine-readable `code` on a structured API error, if there is one.
///
/// The server sends `{"detail": {"code": ..., "message": ...}}` for every
/// failure the client is expected to *do* something about, precisely so the
/// client never has to pattern-match on prose.
String? apiErrorCode(Object error) {
  if (error is! DioException) return null;
  final data = error.response?.data;
  if (data is! Map) return null;

  final detail = data['detail'];
  if (detail is Map) {
    final code = detail['code'];
    if (code is String && code.isNotEmpty) return code;
  }
  final nested = data['error'];
  if (nested is Map) {
    final message = nested['message'];
    if (message is Map) {
      final code = message['code'];
      if (code is String && code.isNotEmpty) return code;
    }
  }
  return null;
}

/// True when the API signaled free unique-question cap.
bool isEntitlementUniqueCap(Object error) =>
    apiErrorCode(error) == 'entitlement_unique_cap';

/// True when the topic has no questions in the run's language yet.
bool isContentLanguageUnavailable(Object error) =>
    apiErrorCode(error) == 'content_language_unavailable';
