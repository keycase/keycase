import 'package:postgres/postgres.dart';
import 'package:uuid/uuid.dart';

import '../http/responses.dart';
import 'database.dart';
import 'team_repo.dart';

class TeamMessageRecipient {
  final String recipientUsername;
  final String encryptedBody;
  final String nonce;

  TeamMessageRecipient({
    required this.recipientUsername,
    required this.encryptedBody,
    required this.nonce,
  });
}

class TeamMessage {
  final String id;
  final String teamId;
  final String senderUsername;
  final String recipientUsername;
  final String encryptedBody;
  final String nonce;
  final DateTime createdAt;

  TeamMessage({
    required this.id,
    required this.teamId,
    required this.senderUsername,
    required this.recipientUsername,
    required this.encryptedBody,
    required this.nonce,
    required this.createdAt,
  });

  Map<String, Object?> toJson() => {
        'id': id,
        'teamId': teamId,
        'senderUsername': senderUsername,
        'recipientUsername': recipientUsername,
        'encryptedBody': encryptedBody,
        'nonce': nonce,
        'createdAt': createdAt.toIso8601String(),
      };
}

/// Persistence for team messages. A single logical message is stored as
/// one row per recipient — the sender encrypts it separately for each
/// member so the server only ever sees ciphertext.
class TeamMessageRepo {
  final Database _db;
  final TeamRepo _teams;
  final Uuid _uuid;

  TeamMessageRepo(this._db, this._teams, {Uuid? uuid})
      : _uuid = uuid ?? const Uuid();

  Future<List<TeamMessage>> sendTeamMessage({
    required String teamId,
    required String senderUsername,
    required List<TeamMessageRecipient> recipientEntries,
  }) async {
    await _teams.requireMembership(teamId, senderUsername);
    if (recipientEntries.isEmpty) {
      throw const HttpError(400, 'recipients must not be empty');
    }
    // Every named recipient must be a current member; otherwise the
    // server would be storing ciphertext addressed to outsiders.
    for (final r in recipientEntries) {
      final role = await _teams.getRole(teamId, r.recipientUsername);
      if (role == null) {
        throw HttpError(400,
            'recipient ${r.recipientUsername} is not a member of this team');
      }
    }

    final inserted = <TeamMessage>[];
    for (final r in recipientEntries) {
      final id = _uuid.v4();
      final result = await _db.connection.execute(
        Sql.named(
          'INSERT INTO team_messages '
          '(id, team_id, sender_username, recipient_username, '
          'encrypted_body, nonce) '
          'VALUES (@id::uuid, @team::uuid, @sender, @recipient, @body, @nonce) '
          'RETURNING id, team_id, sender_username, recipient_username, '
          'encrypted_body, nonce, created_at',
        ),
        parameters: {
          'id': id,
          'team': teamId,
          'sender': senderUsername,
          'recipient': r.recipientUsername,
          'body': r.encryptedBody,
          'nonce': r.nonce,
        },
      );
      inserted.add(_rowToMessage(result.first));
    }
    return inserted;
  }

  Future<List<TeamMessage>> getTeamMessages({
    required String teamId,
    required String username,
    int limit = 50,
    int offset = 0,
  }) async {
    await _teams.requireMembership(teamId, username);
    final result = await _db.connection.execute(
      Sql.named(
        'SELECT id, team_id, sender_username, recipient_username, '
        'encrypted_body, nonce, created_at '
        'FROM team_messages '
        'WHERE team_id = @t::uuid AND recipient_username = @u '
        'ORDER BY created_at DESC '
        'LIMIT @limit OFFSET @offset',
      ),
      parameters: {
        't': teamId,
        'u': username,
        'limit': limit,
        'offset': offset,
      },
    );
    return [for (final row in result) _rowToMessage(row)];
  }

  TeamMessage _rowToMessage(ResultRow row) => TeamMessage(
        id: row[0].toString(),
        teamId: row[1].toString(),
        senderUsername: row[2] as String,
        recipientUsername: row[3] as String,
        encryptedBody: row[4] as String,
        nonce: row[5] as String,
        createdAt: (row[6] as DateTime).toUtc(),
      );
}
