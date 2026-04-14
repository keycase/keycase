import 'package:keycase_core/keycase_core.dart';

import 'db/identity_repo.dart';

/// Pluggable seam so tests can stub out real DNS/HTTP/key-signing
/// verification instead of hitting the network.
class ProofVerifiers {
  final DnsProofVerifier dns;
  final UrlProofVerifier url;
  final KeySigningVerifier keySigning;

  ProofVerifiers({
    DnsProofVerifier? dns,
    UrlProofVerifier? url,
    KeySigningVerifier? keySigning,
  })  : dns = dns ?? DnsProofVerifier(),
        url = url ?? UrlProofVerifier(),
        keySigning = keySigning ?? KeySigningVerifier();

  /// Verify a proof, looking up any extra identity state needed (e.g.
  /// the signer's public key for key-signing proofs). Returns `true`
  /// if the proof is currently valid.
  Future<bool> verify({
    required Proof proof,
    required Identity owner,
    required IdentityRepo identities,
  }) async {
    switch (proof.type) {
      case ProofType.dns:
        return dns.verify(proof.target, owner.username, owner.publicKey);
      case ProofType.url:
        return url.verify(proof.target, owner.username, owner.publicKey);
      case ProofType.keySigning:
        // For key-signing proofs, `target` is the signer's username and
        // the signature is over the owner's public key (see KeySigningVerifier).
        final signer = await identities.findByUsername(proof.target);
        if (signer == null) return false;
        return keySigning.verify(
          targetPublicKey: owner.publicKey,
          signerPublicKey: signer.publicKey,
          signature: proof.signature,
        );
    }
  }
}
