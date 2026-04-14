import 'package:keycase_core/keycase_core.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

import '../db/identity_repo.dart';
import '../db/proof_repo.dart';
import '../http/middleware.dart';
import '../http/responses.dart';
import '../verification.dart';
import '../ws/connection_manager.dart';

final _uuid = const Uuid();

void mountProofRoutes(
  Router app, {
  required IdentityRepo identities,
  required ProofRepo proofs,
  required ProofVerifiers verifiers,
  ConnectionManager? connections,
}) {
  // Submit a new proof. Verifies immediately and records result.
  app.post('/api/v1/proof', (Request request) async {
    final body = await readJsonBody(request);
    final identityUsername = _requireString(body, 'identityUsername');
    final typeStr = _requireString(body, 'type');
    final target = _requireString(body, 'target');
    final signature = _requireString(body, 'signature');
    final statement = body['statement'] as String?;

    final authUser = request.context[authContextKey] as String?;
    if (authUser != identityUsername) {
      throw const HttpError(401,
          'authorization must match identityUsername');
    }

    final ProofType type;
    try {
      type = ProofType.values.byName(typeStr);
    } catch (_) {
      throw HttpError(400, 'unknown proof type: $typeStr');
    }

    final owner = await identities.findByUsername(identityUsername);
    if (owner == null) {
      throw const HttpError(404, 'identity not found');
    }

    final pending = await proofs.insert(
      id: _uuid.v4(),
      identityUsername: identityUsername,
      type: type,
      status: ProofStatus.pending,
      target: target,
      signature: signature,
      statement: statement,
    );

    final ok = await verifiers.verify(
      proof: pending,
      owner: owner,
      identities: identities,
    );
    final updated = await proofs.updateStatus(
      id: pending.id,
      status: ok ? ProofStatus.verified : ProofStatus.failed,
      verifiedAt: DateTime.now().toUtc(),
    );
    // ignore: avoid_print
    print('proof ${updated.id} (${type.name}) for $identityUsername → '
        '${updated.status.name}');
    if (connections != null && updated.status == ProofStatus.verified) {
      connections.sendToUser(identityUsername, {
        'type': 'proof_verified',
        'proof': updated.toJson(),
      });
    }
    return jsonCreated(updated.toJson());
  });

  // Get a single proof.
  app.get('/api/v1/proof/<id>', (Request request, String id) async {
    final proof = await proofs.findById(id);
    if (proof == null) {
      throw const HttpError(404, 'proof not found');
    }
    return jsonOk(proof.toJson());
  });

  // Re-verify an existing proof.
  app.post('/api/v1/proof/<id>/verify',
      (Request request, String id) async {
    final proof = await proofs.findById(id);
    if (proof == null) {
      throw const HttpError(404, 'proof not found');
    }
    final authUser = request.context[authContextKey] as String?;
    if (authUser != proof.identityUsername) {
      throw const HttpError(401,
          'authorization must match proof owner');
    }
    final owner = await identities.findByUsername(proof.identityUsername);
    if (owner == null) {
      throw const HttpError(404, 'identity not found');
    }
    final ok = await verifiers.verify(
      proof: proof,
      owner: owner,
      identities: identities,
    );
    final newStatus = ok
        ? ProofStatus.verified
        : (proof.status == ProofStatus.verified
            ? ProofStatus.revoked
            : ProofStatus.failed);
    final updated = await proofs.updateStatus(
      id: proof.id,
      status: newStatus,
      verifiedAt: DateTime.now().toUtc(),
    );
    // ignore: avoid_print
    print('re-verified proof ${updated.id} → ${updated.status.name}');
    if (connections != null && updated.status == ProofStatus.verified) {
      connections.sendToUser(updated.identityUsername, {
        'type': 'proof_verified',
        'proof': updated.toJson(),
      });
    }
    return jsonOk(updated.toJson());
  });
}

String _requireString(Map<String, dynamic> body, String key) {
  final v = body[key];
  if (v is! String || v.isEmpty) {
    throw HttpError(400, '$key is required');
  }
  return v;
}
