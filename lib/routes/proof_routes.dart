import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

void mountProofRoutes(Router app) {
  // Submit a new proof
  app.post('/api/v1/proof', (Request request) async {
    // TODO: Parse proof submission, initiate verification
    // Expects: { identityUsername, type (dns|url|keySigning), target, signature }
    return Response(501,
      body: jsonEncode({'error': 'Not yet implemented'}),
      headers: {'Content-Type': 'application/json'},
    );
  });

  // Get proof status
  app.get('/api/v1/proof/<id>', (Request request, String id) async {
    // TODO: Look up proof by ID, return status
    return Response(501,
      body: jsonEncode({'error': 'Not yet implemented'}),
      headers: {'Content-Type': 'application/json'},
    );
  });

  // Verify a proof (trigger re-verification)
  app.post('/api/v1/proof/<id>/verify', (Request request, String id) async {
    // TODO: Re-verify an existing proof
    return Response(501,
      body: jsonEncode({'error': 'Not yet implemented'}),
      headers: {'Content-Type': 'application/json'},
    );
  });

  // List proofs for an identity
  app.get('/api/v1/identity/<username>/proofs', (Request request, String username) async {
    // TODO: List all proofs for a given identity
    return Response(501,
      body: jsonEncode({'error': 'Not yet implemented'}),
      headers: {'Content-Type': 'application/json'},
    );
  });
}
