import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import 'db/database.dart';
import 'db/identity_repo.dart';
import 'db/message_repo.dart';
import 'db/proof_repo.dart';
import 'http/middleware.dart';
import 'routes/health_routes.dart';
import 'routes/identity_routes.dart';
import 'routes/key_signing_routes.dart';
import 'routes/message_routes.dart';
import 'routes/proof_routes.dart';
import 'verification.dart';

/// Build the Shelf [Handler] that serves the KeyCase API. Exposed so
/// tests can drive it in-process without binding a port.
Handler buildHandler({
  required Database database,
  ProofVerifiers? verifiers,
}) {
  final identities = IdentityRepo(database);
  final proofs = ProofRepo(database);
  final messages = MessageRepo(database);
  final v = verifiers ?? ProofVerifiers();

  final app = Router();
  mountHealthRoutes(app);
  mountIdentityRoutes(app, identities: identities, proofs: proofs);
  mountProofRoutes(app,
      identities: identities, proofs: proofs, verifiers: v);
  mountKeySigningRoutes(app,
      identities: identities, proofs: proofs, verifiers: v);
  mountMessageRoutes(app, identities: identities, messages: messages);

  return const Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(_corsMiddleware())
      .addMiddleware(errorMiddleware())
      .addMiddleware(authMiddleware(identities))
      .addHandler(app.call);
}

/// Start the KeyCase server bound to [host]:[port].
Future<HttpServer> startServer({
  required Database database,
  String host = 'localhost',
  int port = 8080,
  ProofVerifiers? verifiers,
}) {
  final handler = buildHandler(database: database, verifiers: verifiers);
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
