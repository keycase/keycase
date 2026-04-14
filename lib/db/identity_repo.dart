import 'package:keycase_core/keycase_core.dart';
import 'package:postgres/postgres.dart';

import 'database.dart';

/// Persistence for [Identity] records.
class IdentityRepo {
  final Database _db;

  IdentityRepo(this._db);

  /// Insert a new identity. Throws if the username already exists.
  Future<Identity> insert({
    required String username,
    required String publicKey,
  }) async {
    final result = await _db.connection.execute(
      Sql.named(
        'INSERT INTO identities (username, public_key) '
        'VALUES (@username, @publicKey) '
        'RETURNING username, public_key, created_at',
      ),
      parameters: {'username': username, 'publicKey': publicKey},
    );
    return _rowToIdentity(result.first);
  }

  /// Fetch an identity by username, or `null` if absent.
  Future<Identity?> findByUsername(String username) async {
    final result = await _db.connection.execute(
      Sql.named(
        'SELECT username, public_key, created_at '
        'FROM identities WHERE username = @username',
      ),
      parameters: {'username': username},
    );
    if (result.isEmpty) return null;
    final proofIds = await _proofIdsFor(username);
    return _rowToIdentity(result.first, proofIds: proofIds);
  }

  /// Prefix search by username, case-sensitive (usernames are lowercase).
  Future<List<Identity>> searchByPrefix(String prefix, {int limit = 20}) async {
    final result = await _db.connection.execute(
      Sql.named(
        'SELECT username, public_key, created_at '
        'FROM identities WHERE username LIKE @prefix '
        'ORDER BY username ASC LIMIT @limit',
      ),
      parameters: {'prefix': '$prefix%', 'limit': limit},
    );
    return [for (final row in result) _rowToIdentity(row)];
  }

  Future<List<String>> _proofIdsFor(String username) async {
    final rows = await _db.connection.execute(
      Sql.named(
        'SELECT id FROM proofs WHERE identity_username = @u '
        "AND status = 'verified' ORDER BY created_at ASC",
      ),
      parameters: {'u': username},
    );
    return [for (final r in rows) r[0] as String];
  }

  Identity _rowToIdentity(ResultRow row, {List<String> proofIds = const []}) {
    return Identity(
      username: row[0] as String,
      publicKey: row[1] as String,
      createdAt: (row[2] as DateTime).toUtc(),
      proofIds: proofIds,
    );
  }
}
