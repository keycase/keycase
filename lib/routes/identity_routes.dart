import 'package:keycase_core/keycase_core.dart' as core;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../db/identity_repo.dart';
import '../db/proof_repo.dart';
import '../http/middleware.dart';
import '../http/responses.dart';

final RegExp _usernameRegExp = RegExp(r'^[a-z0-9]{3,32}$');

/// Mount `/api/v1/identity` routes.
void mountIdentityRoutes(
  Router app, {
  required IdentityRepo identities,
  required ProofRepo proofs,
}) {
  // Register a new identity.
  // Body: { username, publicKey, signature } where signature is an
  // Ed25519 signature of the username (proof of private key ownership).
  app.post('/api/v1/identity', (Request request) async {
    final body = await readJsonBody(request);
    final username = body['username'];
    final publicKey = body['publicKey'];
    final signature = body['signature'];
    if (username is! String || publicKey is! String || signature is! String) {
      throw const HttpError(400,
          'username, publicKey, and signature are required strings');
    }
    if (!_usernameRegExp.hasMatch(username)) {
      throw const HttpError(400,
          'username must be 3-32 lowercase alphanumeric characters');
    }
    final ok = await core.verify(username, signature, publicKey);
    if (!ok) {
      throw const HttpError(400,
          'signature does not match publicKey (expected a signature of the '
          'username string)');
    }
    final existing = await identities.findByUsername(username);
    if (existing != null) {
      throw const HttpError(409, 'username already registered');
    }
    final identity = await identities.insert(
      username: username,
      publicKey: publicKey,
    );
    // ignore: avoid_print
    print('registered identity: $username');
    return jsonCreated(identity.toJson());
  });

  // Search identities by username prefix.
  app.get('/api/v1/identity', (Request request) async {
    final q = request.url.queryParameters['q']?.trim() ?? '';
    if (q.isEmpty) {
      return jsonOk({'results': <Object>[]});
    }
    final results = await identities.searchByPrefix(q);
    return jsonOk({
      'results': [for (final i in results) i.toJson()],
    });
  });

  // Look up a single identity.
  app.get('/api/v1/identity/<username>',
      (Request request, String username) async {
    final identity = await identities.findByUsername(username);
    if (identity == null) {
      throw const HttpError(404, 'identity not found');
    }
    return jsonOk(identity.toJson());
  });

  // List proofs for an identity.
  app.get('/api/v1/identity/<username>/proofs',
      (Request request, String username) async {
    final identity = await identities.findByUsername(username);
    if (identity == null) {
      throw const HttpError(404, 'identity not found');
    }
    final list = await proofs.listByIdentity(username);
    return jsonOk({
      'proofs': [for (final p in list) p.toJson()],
    });
  });
}
