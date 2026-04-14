import 'dart:io';

import 'package:shelf/shelf.dart';

import 'middleware.dart';

/// Structured access log: method, path, status, duration (ms), username
/// when authenticated. One line per request, written to stdout.
Middleware accessLogMiddleware() {
  return (Handler inner) {
    return (Request request) async {
      final start = DateTime.now();
      final sw = Stopwatch()..start();
      int status = 0;
      Response? response;
      Object? error;
      try {
        response = await inner(request);
        status = response.statusCode;
        return response;
      } catch (e) {
        error = e;
        status = 500;
        rethrow;
      } finally {
        sw.stop();
        final user = request.context[authContextKey];
        final userField = user is String ? user : '-';
        // Intentionally compact — one line, easy to grep.
        stdout.writeln(
          '${start.toUtc().toIso8601String()} '
          '${request.method.padRight(6)} '
          '/${request.url.path} '
          'status=$status '
          'dur=${sw.elapsedMilliseconds}ms '
          'user=$userField'
          '${error != null ? ' err=${_short(error)}' : ''}',
        );
      }
    };
  };
}

String _short(Object err) {
  final s = err.toString();
  if (s.length <= 120) return s.replaceAll('\n', ' ');
  return '${s.substring(0, 117).replaceAll('\n', ' ')}...';
}
