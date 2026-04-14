import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:keycase_core/keycase_core.dart' as core;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../db/identity_repo.dart';
import '../http/middleware.dart';
import '../http/responses.dart';
import '../ws/connection_manager.dart';

/// Max age of the signed timestamp in the auth message. Short enough
/// that a leaked handshake can't be replayed long-term; long enough to
/// absorb reasonable clock skew between client and server.
const Duration _authMaxAge = Duration(seconds: 30);

/// Server → client heartbeat period. Clients must reply with
/// `{type: pong}` within [_heartbeatTimeout] or the socket is closed.
const Duration _heartbeatInterval = Duration(seconds: 30);
const Duration _heartbeatTimeout = Duration(seconds: 10);

/// Bound on the first "auth" message — anything beyond is a protocol
/// violation and we disconnect rather than wait indefinitely.
const Duration _authDeadline = Duration(seconds: 15);

void mountWsRoutes(
  Router app, {
  required IdentityRepo identities,
  required ConnectionManager connections,
}) {
  // We implement JSON ping/pong ourselves rather than relying on
  // protocol-level pings so the heartbeat is visible to client code
  // and can carry typed payloads in future.
  final handler = webSocketHandler(
    (WebSocketChannel channel, String? _) {
      _handleSocket(channel, identities: identities, connections: connections);
    },
  );
  app.get('/api/v1/ws', handler);

  // Simple presence lookup. Returns `{ username: bool }` for every
  // username passed in the `usernames` query param (comma-separated).
  app.get('/api/v1/presence', (Request request) {
    final auth = request.context[authContextKey];
    if (auth is! String) {
      throw const HttpError(401, 'authentication required');
    }
    final raw = request.url.queryParameters['usernames'];
    if (raw == null || raw.trim().isEmpty) {
      throw const HttpError(400, 'usernames query parameter is required');
    }
    final names = raw
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet();
    if (names.length > 100) {
      throw const HttpError(400, 'at most 100 usernames may be queried');
    }
    return jsonOk({
      for (final n in names) n: connections.isOnline(n),
    });
  });
}

/// Drives one WebSocket from handshake through disconnect. Auth lives
/// entirely in the first message so browsers (which can't set custom
/// headers on the upgrade request) can connect directly.
void _handleSocket(
  WebSocketChannel channel, {
  required IdentityRepo identities,
  required ConnectionManager connections,
}) {
  // State we need to clean up on disconnect. Assigned after auth.
  String? username;
  void Function()? unregister;
  Timer? heartbeatTimer;
  Timer? heartbeatDeadline;
  var authed = false;
  var closed = false;

  Future<void> closeWith(int code, String reason) async {
    if (closed) return;
    closed = true;
    heartbeatTimer?.cancel();
    heartbeatDeadline?.cancel();
    if (username != null) unregister?.call();
    try {
      await channel.sink.close(code, reason);
    } catch (_) {
      // already closed
    }
  }

  void sendJson(Map<String, dynamic> payload) {
    if (closed) return;
    try {
      channel.sink.add(jsonEncode(payload));
    } catch (e) {
      stderr.writeln('[ws] send error: $e');
    }
  }

  void scheduleHeartbeat() {
    heartbeatTimer?.cancel();
    heartbeatDeadline?.cancel();
    heartbeatTimer = Timer(_heartbeatInterval, () {
      if (closed) return;
      sendJson({'type': 'ping'});
      heartbeatDeadline = Timer(_heartbeatTimeout, () {
        closeWith(
          WsCloseCodes.heartbeatTimeout,
          'pong not received in time',
        );
      });
    });
  }

  // Auth has a deadline: if no "auth" message arrives, tear down.
  final authTimer = Timer(_authDeadline, () {
    if (!authed) {
      closeWith(
        WsCloseCodes.authRequired,
        'auth message not received',
      );
    }
  });

  channel.stream.listen(
    (dynamic raw) async {
      if (closed) return;
      if (raw is! String) {
        await closeWith(
          WsCloseCodes.protocolViolation,
          'binary frames are not supported',
        );
        return;
      }
      Map<String, dynamic> msg;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic>) {
          await closeWith(
            WsCloseCodes.protocolViolation,
            'message must be a JSON object',
          );
          return;
        }
        msg = decoded;
      } on FormatException {
        await closeWith(
          WsCloseCodes.protocolViolation,
          'invalid JSON frame',
        );
        return;
      }

      final type = msg['type'];
      if (type is! String) {
        await closeWith(
          WsCloseCodes.protocolViolation,
          'message.type is required',
        );
        return;
      }

      if (!authed) {
        if (type != 'auth') {
          await closeWith(
            WsCloseCodes.authRequired,
            'auth message required before any other frame',
          );
          return;
        }
        final ok = await _performAuth(msg, identities);
        if (ok == null) {
          await closeWith(
            WsCloseCodes.authRequired,
            'auth failed',
          );
          return;
        }
        authed = true;
        authTimer.cancel();
        username = ok;
        unregister = connections.register(ok, channel);
        sendJson({'type': 'auth_ok', 'username': ok});
        scheduleHeartbeat();
        return;
      }

      // Post-auth message handling.
      switch (type) {
        case 'pong':
          heartbeatDeadline?.cancel();
          scheduleHeartbeat();
          break;
        case 'ping':
          // Courtesy reply so clients can use the same frame shape.
          sendJson({'type': 'pong'});
          break;
        default:
          // Unknown frames are ignored; this leaves room for clients
          // to forward-compatibly send hints we haven't defined yet.
          break;
      }
    },
    onError: (Object err, StackTrace st) {
      stderr.writeln('[ws] stream error for ${username ?? "pre-auth"}: $err');
      closeWith(1011, 'server error');
    },
    onDone: () {
      closed = true;
      authTimer.cancel();
      heartbeatTimer?.cancel();
      heartbeatDeadline?.cancel();
      if (username != null) unregister?.call();
    },
    cancelOnError: true,
  );
}

/// Verify an auth frame, returning the authenticated username on
/// success or `null` if anything about it is off. We deliberately do
/// not leak *why* auth failed — attackers get one bit of information.
Future<String?> _performAuth(
  Map<String, dynamic> msg,
  IdentityRepo identities,
) async {
  final username = msg['username'];
  final signature = msg['signature'];
  final timestampStr = msg['timestamp'];
  if (username is! String || signature is! String || timestampStr is! String) {
    return null;
  }

  final DateTime ts;
  try {
    ts = DateTime.parse(timestampStr).toUtc();
  } on FormatException {
    return null;
  }
  final now = DateTime.now().toUtc();
  final age = now.difference(ts);
  // Reject replays and far-future timestamps alike.
  if (age > _authMaxAge || age < -_authMaxAge) {
    return null;
  }

  final identity = await identities.findByUsername(username);
  if (identity == null) return null;

  final ok = await core.verify(timestampStr, signature, identity.publicKey);
  if (!ok) return null;
  return username;
}
