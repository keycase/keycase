import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../db/identity_repo.dart';
import '../db/message_repo.dart';
import '../http/middleware.dart';
import '../http/responses.dart';

/// Mount `/api/v1/messages` routes.
///
/// The server stores ciphertext only — encryption and decryption happen
/// on the clients. Each row carries the sender's X25519 public key and
/// the AES-GCM nonce so the recipient can run `decryptFrom`.
void mountMessageRoutes(
  Router app, {
  required IdentityRepo identities,
  required MessageRepo messages,
}) {
  // Send a message.
  app.post('/api/v1/messages', (Request request) async {
    final sender = _requireAuth(request);
    final body = await readJsonBody(request);
    final recipientUsername =
        requireString(body, 'recipientUsername', maxLength: 64);
    final encryptedBody = requireString(body, 'encryptedBody');
    final nonce = requireString(body, 'nonce');

    final senderIdentity = await identities.findByUsername(sender);
    if (senderIdentity == null) {
      throw const HttpError(401, 'unknown sender');
    }
    final recipient = await identities.findByUsername(recipientUsername);
    if (recipient == null) {
      throw const HttpError(404, 'recipient not found');
    }

    final message = await messages.sendMessage(
      sender: sender,
      recipient: recipientUsername,
      encryptedBody: encryptedBody,
      nonce: nonce,
      senderPublicKey: senderIdentity.publicKey,
    );
    return jsonCreated(message.toJson());
  });

  // Inbox.
  app.get('/api/v1/messages', (Request request) async {
    final username = _requireAuth(request);
    final unreadOnly = request.url.queryParameters['unread'] == 'true';
    final list = await messages.getMessagesForUser(
      username,
      unreadOnly: unreadOnly,
    );
    return jsonOk({
      'messages': [for (final m in list) m.toJson()],
    });
  });

  // Conversation with a specific user.
  app.get('/api/v1/messages/<username>',
      (Request request, String username) async {
    final me = _requireAuth(request);
    final other = await identities.findByUsername(username);
    if (other == null) {
      throw const HttpError(404, 'identity not found');
    }
    final limit =
        parseNonNegativeIntQuery(request.url, 'limit', defaultValue: 50, max: 200);
    final offset =
        parseNonNegativeIntQuery(request.url, 'offset', defaultValue: 0);
    final list = await messages.getConversation(
      me,
      username,
      limit: limit,
      offset: offset,
    );
    return jsonOk({
      'messages': [for (final m in list) m.toJson()],
    });
  });

  // Mark a message read. Only the recipient may do so.
  app.put('/api/v1/messages/<id>/read',
      (Request request, String id) async {
    final username = _requireAuth(request);
    final messageId = requireUuid(id, field: 'id');
    final existing = await messages.findById(messageId);
    if (existing == null) {
      throw const HttpError(404, 'message not found');
    }
    if (existing.recipientUsername != username) {
      throw const HttpError(403,
          'only the recipient can mark this message read');
    }
    final updated = await messages.markRead(messageId, username);
    // Already-read messages return null from markRead; fall back to the
    // existing row so the client still gets a sensible response.
    return jsonOk((updated ?? existing).toJson());
  });
}

String _requireAuth(Request request) {
  final username = request.context[authContextKey];
  if (username is! String) {
    throw const HttpError(401, 'authentication required');
  }
  return username;
}
