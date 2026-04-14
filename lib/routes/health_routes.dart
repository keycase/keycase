import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../db/database.dart';
import '../http/responses.dart';

/// Server version. Kept in sync with pubspec.yaml; surfaced through
/// `/health` for operators and for client compatibility checks.
const String serverVersion = '0.1.0';

void mountHealthRoutes(
  Router app, {
  required Database database,
  required DateTime startTime,
}) {
  app.get('/health', (Request request) async {
    final uptime = DateTime.now().difference(startTime);
    final dbStatus = await _pingDatabase(database);
    final allOk = dbStatus == 'ok';
    return jsonResponse(allOk ? 200 : 503, {
      'status': allOk ? 'ok' : 'degraded',
      'service': 'keycase',
      'version': serverVersion,
      'uptimeSeconds': uptime.inSeconds,
      'checks': {
        'database': dbStatus,
      },
    });
  });
}

/// Fire a trivial query with a short timeout. We intentionally swallow
/// the error type and just report "down" so details don't leak to
/// unauthenticated callers — logs carry the root cause.
Future<String> _pingDatabase(Database database) async {
  try {
    await database.connection
        .execute('SELECT 1')
        .timeout(const Duration(seconds: 2));
    return 'ok';
  } catch (_) {
    return 'down';
  }
}
