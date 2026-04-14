import 'dart:convert';

import 'package:shelf/shelf.dart';

const _jsonHeaders = {'Content-Type': 'application/json; charset=utf-8'};

/// Thrown inside request handlers to short-circuit with a JSON error body.
class HttpError implements Exception {
  final int status;
  final String message;
  final Map<String, Object?>? details;

  const HttpError(this.status, this.message, {this.details});

  Response toResponse() => jsonResponse(
        status,
        {
          'error': message,
          if (details != null) 'details': details,
        },
      );
}

Response jsonResponse(int status, Object? body) => Response(
      status,
      body: jsonEncode(body),
      headers: _jsonHeaders,
    );

Response jsonOk(Object? body) => jsonResponse(200, body);
Response jsonCreated(Object? body) => jsonResponse(201, body);
