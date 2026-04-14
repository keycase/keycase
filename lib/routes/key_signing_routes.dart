import 'package:keycase_core/keycase_core.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

import '../db/identity_repo.dart';
import '../db/proof_repo.dart';
import '../http/middleware.dart';
import '../http/responses.dart';
import '../verification.dart';

final _uuid = const Uuid();

/// Mount the key-signing endpoint. When user A signs user B's public key
/// we store a `key_signatures` row *and* materialize a keySigning Proof
/// on B's identity so that normal proof listings surface it.
void mountKeySigningRoutes(
  Router app, {
  required IdentityRepo identities,
  required ProofRepo proofs,
  required ProofVerifiers verifiers,
}) {
  app.post('/api/v1/identity/<username>/sign',
      (Request request, String username) async {
    final body = await readJsonBody(request);
    final signerUsername = body['signerUsername'];
    final signature = body['signature'];
    if (signerUsername is! String || signature is! String) {
      throw const HttpError(400,
          'signerUsername and signature are required strings');
    }
    final authUser = request.context[authContextKey] as String?;
    if (authUser != signerUsername) {
      throw const HttpError(401,
          'authorization must match signerUsername');
    }
    if (signerUsername == username) {
      throw const HttpError(400, 'cannot sign your own key');
    }

    final target = await identities.findByUsername(username);
    if (target == null) {
      throw const HttpError(404, 'target identity not found');
    }
    final signer = await identities.findByUsername(signerUsername);
    if (signer == null) {
      throw const HttpError(404, 'signer identity not found');
    }

    final ok = await verifiers.keySigning.verify(
      targetPublicKey: target.publicKey,
      signerPublicKey: signer.publicKey,
      signature: signature,
    );
    if (!ok) {
      throw const HttpError(400, 'signature is not valid');
    }

    await proofs.insertKeySignature(
      id: _uuid.v4(),
      signerUsername: signerUsername,
      targetUsername: username,
      signature: signature,
    );
    final proof = await proofs.insert(
      id: _uuid.v4(),
      identityUsername: username,
      type: ProofType.keySigning,
      status: ProofStatus.verified,
      target: signerUsername,
      signature: signature,
    );
    final verified = await proofs.updateStatus(
      id: proof.id,
      status: ProofStatus.verified,
      verifiedAt: DateTime.now().toUtc(),
    );
    // ignore: avoid_print
    print('$signerUsername signed key of $username');
    return jsonCreated(verified.toJson());
  });
}
