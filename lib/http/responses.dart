import 'dart:convert';

import 'package:shelf/shelf.dart';

const _jsonHeaders = {'Content-Type': 'application/json; charset=utf-8'};

/// Thrown inside request handlers to short-circuit with a JSON error
/// body in the shape `{ "error": "...", "code": "..." }`. If [code] is
/// omitted it's derived from [status] so every response is consistent
/// without every call site having to spell out a code.
class HttpError implements Exception {
  final int status;
  final String message;
  final String? _code;
  final Map<String, Object?>? details;

  const HttpError(this.status, this.message, {String? code, this.details})
      : _code = code;

  String get code => _code ?? _codeForStatus(status);

  Response toResponse() => jsonResponse(
        status,
        {
          'error': message,
          'code': code,
          if (details != null) 'details': details,
        },
      );
}

String _codeForStatus(int status) {
  switch (status) {
    case 400:
      return 'BAD_REQUEST';
    case 401:
      return 'UNAUTHORIZED';
    case 403:
      return 'FORBIDDEN';
    case 404:
      return 'NOT_FOUND';
    case 409:
      return 'CONFLICT';
    case 413:
      return 'PAYLOAD_TOO_LARGE';
    case 415:
      return 'UNSUPPORTED_MEDIA_TYPE';
    case 422:
      return 'UNPROCESSABLE_ENTITY';
    case 429:
      return 'RATE_LIMITED';
    case 500:
      return 'INTERNAL_ERROR';
    case 503:
      return 'SERVICE_UNAVAILABLE';
    default:
      return 'HTTP_$status';
  }
}

Response jsonResponse(int status, Object? body) => Response(
      status,
      body: jsonEncode(body),
      headers: _jsonHeaders,
    );

Response jsonOk(Object? body) => jsonResponse(200, body);
Response jsonCreated(Object? body) => jsonResponse(201, body);

// ---------------------------------------------------------------------------
// Input validators. Route handlers should funnel JSON + path + query values
// through these so bad input never reaches repositories or the database.
// ---------------------------------------------------------------------------

final _uuidRegExp = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

/// Require [key] in [body] to be a non-empty string up to [maxLength].
String requireString(
  Map<String, dynamic> body,
  String key, {
  int maxLength = 4096,
  bool allowEmpty = false,
}) {
  final v = body[key];
  if (v is! String) {
    throw HttpError(400, '$key is required and must be a string');
  }
  if (!allowEmpty && v.trim().isEmpty) {
    throw HttpError(400, '$key must not be empty');
  }
  if (v.length > maxLength) {
    throw HttpError(400, '$key must be at most $maxLength characters');
  }
  return v;
}

/// Optional string variant — returns null when absent, validates when present.
String? optionalString(
  Map<String, dynamic> body,
  String key, {
  int maxLength = 4096,
}) {
  final v = body[key];
  if (v == null) return null;
  if (v is! String) {
    throw HttpError(400, '$key must be a string when provided');
  }
  if (v.length > maxLength) {
    throw HttpError(400, '$key must be at most $maxLength characters');
  }
  return v;
}

/// Validate [value] looks like a canonical UUID. Used for both path and
/// body ids so malformed input is rejected before it reaches Postgres.
String requireUuid(String value, {String field = 'id'}) {
  if (!_uuidRegExp.hasMatch(value)) {
    throw HttpError(400, '$field must be a valid UUID');
  }
  return value.toLowerCase();
}

String? optionalUuid(Object? value, {required String field}) {
  if (value == null) return null;
  if (value is! String) {
    throw HttpError(400, '$field must be a string when provided');
  }
  return requireUuid(value, field: field);
}

/// Parse a non-negative integer query parameter, returning [defaultValue]
/// if absent. Clamps to [max] when provided.
int parseNonNegativeIntQuery(
  Uri url,
  String name, {
  required int defaultValue,
  int? max,
}) {
  final raw = url.queryParameters[name];
  if (raw == null || raw.isEmpty) return defaultValue;
  final parsed = int.tryParse(raw);
  if (parsed == null || parsed < 0) {
    throw HttpError(400, '$name must be a non-negative integer');
  }
  if (max != null && parsed > max) return max;
  return parsed;
}
