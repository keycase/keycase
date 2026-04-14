import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import 'db/database.dart';
import 'db/file_repo.dart';
import 'db/identity_repo.dart';
import 'db/message_repo.dart';
import 'db/proof_repo.dart';
import 'db/team_message_repo.dart';
import 'db/team_repo.dart';
import 'http/access_log.dart';
import 'http/middleware.dart';
import 'http/rate_limit.dart';
import 'routes/file_routes.dart';
import 'routes/health_routes.dart';
import 'routes/identity_routes.dart';
import 'routes/key_signing_routes.dart';
import 'routes/message_routes.dart';
import 'routes/proof_routes.dart';
import 'routes/team_routes.dart';
import 'storage/file_store.dart';
import 'verification.dart';

/// Build the Shelf [Handler] that serves the KeyCase API. Exposed so
/// tests can drive it in-process without binding a port.
Handler buildHandler({
  required Database database,
  required FileStore fileStore,
  ProofVerifiers? verifiers,
  DateTime? startTime,
  RateLimiter? rateLimiter,
}) {
  final identities = IdentityRepo(database);
  final proofs = ProofRepo(database);
  final messages = MessageRepo(database);
  final teams = TeamRepo(database);
  final teamMessages = TeamMessageRepo(database, teams);
  final files = FileRepo(database);
  final v = verifiers ?? ProofVerifiers();
  final limiter = rateLimiter ?? RateLimiter();

  final app = Router();
  mountHealthRoutes(
    app,
    database: database,
    startTime: startTime ?? DateTime.now(),
  );
  mountIdentityRoutes(app, identities: identities, proofs: proofs);
  mountProofRoutes(app,
      identities: identities, proofs: proofs, verifiers: v);
  mountKeySigningRoutes(app,
      identities: identities, proofs: proofs, verifiers: v);
  mountMessageRoutes(app, identities: identities, messages: messages);
  mountTeamRoutes(app, teams: teams, teamMessages: teamMessages);
  mountFileRoutes(app, identities: identities, files: files, store: fileStore);

  // Order matters:
  //  access log wraps everything (to capture rejections too),
  //  CORS runs next so preflights never hit auth/rate limit,
  //  errors are converted to JSON before any handler runs,
  //  rate limit guards before auth (cheap denial path),
  //  auth resolves the username for downstream handlers and logs.
  return const Pipeline()
      .addMiddleware(accessLogMiddleware())
      .addMiddleware(_corsMiddleware())
      .addMiddleware(errorMiddleware())
      .addMiddleware(limiter.middleware())
      .addMiddleware(authMiddleware(identities))
      .addHandler(app.call);
}

/// Start the KeyCase server bound to [host]:[port].
Future<HttpServer> startServer({
  required Database database,
  required FileStore fileStore,
  String host = 'localhost',
  int port = 8080,
  ProofVerifiers? verifiers,
  DateTime? startTime,
  RateLimiter? rateLimiter,
}) {
  final handler = buildHandler(
    database: database,
    fileStore: fileStore,
    verifiers: verifiers,
    startTime: startTime,
    rateLimiter: rateLimiter,
  );
  return shelf_io.serve(handler, host, port);
}

Middleware _corsMiddleware() {
  return (Handler handler) {
    return (Request request) async {
      if (request.method == 'OPTIONS') {
        return Response.ok('', headers: _corsHeaders);
      }
      final response = await handler(request);
      return response.change(headers: _corsHeaders);
    };
  };
}

const _corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
  'Access-Control-Allow-Headers': 'Origin, Content-Type, Authorization',
};
