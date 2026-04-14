import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:keycase_core/keycase_core.dart' as core;
import 'package:shelf/shelf.dart';

import '../db/identity_repo.dart';
import 'responses.dart';

/// Catch [HttpError] and any other exception and render them as JSON.
///
/// Unexpected exceptions are logged server-side (with stack trace) but
/// never leak to clients — responses are always the sanitized
/// `{ error, code }` shape.
Middleware errorMiddleware() {
  return (Handler inner) {
    return (Request request) async {
      try {
        return await inner(request);
      } on HttpError catch (e) {
        return e.toResponse();
      } on FormatException catch (e) {
        return HttpError(
          400,
          'invalid request body: ${e.message}',
          code: 'INVALID_JSON',
        ).toResponse();
      } catch (e, st) {
        stderr.writeln('[error] ${request.method} ${request.url}: $e\n$st');
        return const HttpError(500, 'internal server error').toResponse();
      }
    };
  };
}

/// Context key under which the authenticated username is stored on the
/// request. Route handlers can read it back via `request.context['auth.username']`.
const String authContextKey = 'auth.username';

/// Authenticate mutation requests using the `Authorization: KeyCase` scheme.
///
/// The scheme is `Authorization: KeyCase <username>:<signature>` where the
/// signature is a base64 Ed25519 signature over the raw request body,
/// made with the private key corresponding to the identity's stored
/// public key.
///
/// GET requests, OPTIONS preflight, and the registration endpoint
/// (`POST /api/v1/identity`) are skipped — callers enforce auth
/// elsewhere for these.
Middleware authMiddleware(IdentityRepo identities) {
  return (Handler inner) {
    return (Request request) async {
      if (_skipAuth(request)) return inner(request);

      final header = request.headers['authorization'];
      if (header == null || !header.startsWith('KeyCase ')) {
        throw const HttpError(
          401,
          'missing KeyCase authorization header',
          code: 'MISSING_AUTH',
        );
      }
      final creds = header.substring('KeyCase '.length);
      final colon = creds.indexOf(':');
      if (colon <= 0 || colon == creds.length - 1) {
        throw const HttpError(
          401,
          'malformed authorization header',
          code: 'MALFORMED_AUTH',
        );
      }
      final username = creds.substring(0, colon);
      final signature = creds.substring(colon + 1);

      final identity = await identities.findByUsername(username);
      if (identity == null) {
        throw const HttpError(
          401,
          'unknown identity',
          code: 'UNKNOWN_IDENTITY',
        );
      }

      // Read the full body and re-inject it so downstream handlers can
      // still call readAsString/read.
      final body = await request.readAsString();
      final ok = await core.verify(body, signature, identity.publicKey);
      if (!ok) {
        throw const HttpError(
          401,
          'invalid signature',
          code: 'INVALID_SIGNATURE',
        );
      }

      final rebuilt = request.change(
        body: body,
        context: {...request.context, authContextKey: username},
      );
      return inner(rebuilt);
    };
  };
}

bool _skipAuth(Request request) {
  if (request.method == 'OPTIONS') return true;
  // Message and team endpoints always require auth, including GETs —
  // inboxes, conversations, and team state are private to the caller.
  if (request.url.path.startsWith('api/v1/messages')) return false;
  if (request.url.path.startsWith('api/v1/teams')) return false;
  if (request.url.path.startsWith('api/v1/files')) return false;
  if (request.url.path.startsWith('api/v1/folders')) return false;
  if (request.url.path == 'api/v1/presence') return false;
  // WebSocket upgrade uses in-protocol auth (first frame), not the
  // body-signing scheme, so skip HTTP-layer auth here.
  if (request.url.path == 'api/v1/ws') return true;
  if (request.method == 'GET') return true;
  // Registration is the bootstrap step and cannot use auth headers.
  if (request.method == 'POST' && request.url.path == 'api/v1/identity') {
    return true;
  }
  // File uploads are multipart/binary — the body is not UTF-8 safe, so
  // signature verification happens inside the handler against the
  // metadata part instead of the raw body.
  if (request.method == 'POST' && request.url.path == 'api/v1/files') {
    return true;
  }
  return false;
}

/// Decode a JSON request body into a map. Throws [HttpError] 400 if the
/// body is missing, not a JSON object, or malformed.
Future<Map<String, dynamic>> readJsonBody(Request request) async {
  final raw = await request.readAsString();
  if (raw.isEmpty) {
    throw const HttpError(400, 'request body is empty');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException catch (e) {
    throw HttpError(400, 'invalid JSON: ${e.message}');
  }
  if (decoded is! Map<String, dynamic>) {
    throw const HttpError(400, 'request body must be a JSON object');
  }
  return decoded;
}
