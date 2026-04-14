import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

void mountIdentityRoutes(Router app) {
  // Register a new identity
  app.post('/api/v1/identity', (Request request) async {
    // TODO: Parse request body, validate, create identity
    // Expects: { username, publicKey }
    return Response(501,
      body: jsonEncode({'error': 'Not yet implemented'}),
      headers: {'Content-Type': 'application/json'},
    );
  });

  // Look up an identity by username
  app.get('/api/v1/identity/<username>', (Request request, String username) async {
    // TODO: Look up identity from database, return with proofs
    return Response(501,
      body: jsonEncode({'error': 'Not yet implemented'}),
      headers: {'Content-Type': 'application/json'},
    );
  });

  // Search for identities
  app.get('/api/v1/identity', (Request request) async {
    // TODO: Search identities by query param
    return Response(501,
      body: jsonEncode({'error': 'Not yet implemented'}),
      headers: {'Content-Type': 'application/json'},
    );
  });
}
