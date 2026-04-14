import 'package:postgres/postgres.dart';
import 'package:uuid/uuid.dart';

import 'database.dart';

/// A stored encrypted message. The server never sees plaintext —
/// [encryptedBody] is ciphertext produced client-side with
/// [senderPublicKey] + [nonce] so the recipient can decrypt.
class Message {
  final String id;
  final String senderUsername;
  final String recipientUsername;
  final String encryptedBody;
  final String nonce;
  final String senderPublicKey;
  final DateTime createdAt;
  final DateTime? readAt;

  Message({
    required this.id,
    required this.senderUsername,
    required this.recipientUsername,
    required this.encryptedBody,
    required this.nonce,
    required this.senderPublicKey,
    required this.createdAt,
    required this.readAt,
  });

  Map<String, Object?> toJson() => {
        'id': id,
        'senderUsername': senderUsername,
        'recipientUsername': recipientUsername,
        'encryptedBody': encryptedBody,
        'nonce': nonce,
        'senderPublicKey': senderPublicKey,
        'createdAt': createdAt.toIso8601String(),
        'readAt': readAt?.toIso8601String(),
      };
}

/// Persistence for encrypted [Message] records.
class MessageRepo {
  final Database _db;
  final Uuid _uuid;

  MessageRepo(this._db, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  static const _columns =
      'id, sender_username, recipient_username, encrypted_body, nonce, '
      'sender_public_key, created_at, read_at';

  Future<Message> sendMessage({
    required String sender,
    required String recipient,
    required String encryptedBody,
    required String nonce,
    required String senderPublicKey,
  }) async {
    final id = _uuid.v4();
    final result = await _db.connection.execute(
      Sql.named(
        'INSERT INTO messages '
        '(id, sender_username, recipient_username, encrypted_body, nonce, '
        'sender_public_key) '
        'VALUES (@id::uuid, @sender, @recipient, @body, @nonce, @spk) '
        'RETURNING $_columns',
      ),
      parameters: {
        'id': id,
        'sender': sender,
        'recipient': recipient,
        'body': encryptedBody,
        'nonce': nonce,
        'spk': senderPublicKey,
      },
    );
    return _rowToMessage(result.first);
  }

  Future<List<Message>> getMessagesForUser(
    String username, {
    bool unreadOnly = false,
  }) async {
    final where = unreadOnly
        ? 'recipient_username = @u AND read_at IS NULL'
        : 'recipient_username = @u';
    final result = await _db.connection.execute(
      Sql.named(
        'SELECT $_columns FROM messages '
        'WHERE $where '
        'ORDER BY created_at DESC LIMIT 100',
      ),
      parameters: {'u': username},
    );
    return [for (final row in result) _rowToMessage(row)];
  }

  Future<Message?> findById(String id) async {
    final result = await _db.connection.execute(
      Sql.named('SELECT $_columns FROM messages WHERE id = @id::uuid'),
      parameters: {'id': id},
    );
    if (result.isEmpty) return null;
    return _rowToMessage(result.first);
  }

  /// Mark [messageId] read, but only when [username] is the recipient.
  /// Returns the updated message, or `null` if no row matched (wrong
  /// recipient or unknown id).
  Future<Message?> markRead(String messageId, String username) async {
    final result = await _db.connection.execute(
      Sql.named(
        'UPDATE messages SET read_at = NOW() '
        'WHERE id = @id::uuid AND recipient_username = @u '
        'AND read_at IS NULL '
        'RETURNING $_columns',
      ),
      parameters: {'id': messageId, 'u': username},
    );
    if (result.isEmpty) return null;
    return _rowToMessage(result.first);
  }

  Future<List<Message>> getConversation(
    String user1,
    String user2, {
    int limit = 50,
    int offset = 0,
  }) async {
    final result = await _db.connection.execute(
      Sql.named(
        'SELECT $_columns FROM messages '
        'WHERE (sender_username = @a AND recipient_username = @b) '
        '   OR (sender_username = @b AND recipient_username = @a) '
        'ORDER BY created_at ASC LIMIT @limit OFFSET @offset',
      ),
      parameters: {
        'a': user1,
        'b': user2,
        'limit': limit,
        'offset': offset,
      },
    );
    return [for (final row in result) _rowToMessage(row)];
  }

  Message _rowToMessage(ResultRow row) {
    return Message(
      id: row[0] is String ? row[0] as String : row[0].toString(),
      senderUsername: row[1] as String,
      recipientUsername: row[2] as String,
      encryptedBody: row[3] as String,
      nonce: row[4] as String,
      senderPublicKey: row[5] as String,
      createdAt: (row[6] as DateTime).toUtc(),
      readAt: row[7] == null ? null : (row[7] as DateTime).toUtc(),
    );
  }
}
