import 'package:keycase_core/keycase_core.dart';
import 'package:postgres/postgres.dart';

import 'database.dart';

/// Persistence for [Proof] records plus key-signing rows.
class ProofRepo {
  final Database _db;

  ProofRepo(this._db);

  Future<Proof> insert({
    required String id,
    required String identityUsername,
    required ProofType type,
    required ProofStatus status,
    required String target,
    required String signature,
    String? statement,
  }) async {
    final result = await _db.connection.execute(
      Sql.named(
        'INSERT INTO proofs '
        '(id, identity_username, type, status, target, signature, statement) '
        'VALUES (@id, @u, @type, @status, @target, @sig, @stmt) '
        'RETURNING id, identity_username, type, status, target, signature, '
        'created_at, verified_at',
      ),
      parameters: {
        'id': id,
        'u': identityUsername,
        'type': type.name,
        'status': status.name,
        'target': target,
        'sig': signature,
        'stmt': statement,
      },
    );
    return _rowToProof(result.first);
  }

  Future<Proof?> findById(String id) async {
    final result = await _db.connection.execute(
      Sql.named(
        'SELECT id, identity_username, type, status, target, signature, '
        'created_at, verified_at FROM proofs WHERE id = @id',
      ),
      parameters: {'id': id},
    );
    if (result.isEmpty) return null;
    return _rowToProof(result.first);
  }

  /// Fetch the raw signed statement for a proof (used for re-verification).
  Future<String?> findStatement(String id) async {
    final result = await _db.connection.execute(
      Sql.named('SELECT statement FROM proofs WHERE id = @id'),
      parameters: {'id': id},
    );
    if (result.isEmpty) return null;
    return result.first[0] as String?;
  }

  Future<List<Proof>> listByIdentity(String username) async {
    final result = await _db.connection.execute(
      Sql.named(
        'SELECT id, identity_username, type, status, target, signature, '
        'created_at, verified_at FROM proofs '
        'WHERE identity_username = @u ORDER BY created_at ASC',
      ),
      parameters: {'u': username},
    );
    return [for (final row in result) _rowToProof(row)];
  }

  Future<Proof> updateStatus({
    required String id,
    required ProofStatus status,
    DateTime? verifiedAt,
  }) async {
    final result = await _db.connection.execute(
      Sql.named(
        'UPDATE proofs SET status = @s, verified_at = @v WHERE id = @id '
        'RETURNING id, identity_username, type, status, target, signature, '
        'created_at, verified_at',
      ),
      parameters: {
        'id': id,
        's': status.name,
        'v': verifiedAt,
      },
    );
    return _rowToProof(result.first);
  }

  /// Insert a key-signing row. Returns the generated row id.
  Future<void> insertKeySignature({
    required String id,
    required String signerUsername,
    required String targetUsername,
    required String signature,
  }) async {
    await _db.connection.execute(
      Sql.named(
        'INSERT INTO key_signatures '
        '(id, signer_username, target_username, signature) '
        'VALUES (@id, @signer, @target, @sig) '
        'ON CONFLICT (signer_username, target_username) '
        'DO UPDATE SET signature = EXCLUDED.signature, '
        'created_at = NOW()',
      ),
      parameters: {
        'id': id,
        'signer': signerUsername,
        'target': targetUsername,
        'sig': signature,
      },
    );
  }

  Proof _rowToProof(ResultRow row) {
    return Proof(
      id: row[0] as String,
      identityUsername: row[1] as String,
      type: ProofType.values.byName(row[2] as String),
      status: ProofStatus.values.byName(row[3] as String),
      target: row[4] as String,
      signature: row[5] as String,
      createdAt: (row[6] as DateTime).toUtc(),
      verifiedAt: row[7] == null ? null : (row[7] as DateTime).toUtc(),
    );
  }
}
