import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../db/team_repo.dart';

/// Codes we use when the server closes a connection. 4000-4999 is
/// reserved for application use by the WebSocket spec.
class WsCloseCodes {
  static const int authRequired = 4001;
  static const int protocolViolation = 4002;
  static const int heartbeatTimeout = 4003;
}

/// In-memory registry of live WebSocket connections keyed by
/// username. A single user can have multiple connections (multiple
/// devices or tabs); a payload fanned out to a username lands on all of
/// them.
///
/// Thread safety: Dart's event loop is single-threaded within an
/// isolate, so the maps are only mutated between awaits. We never
/// suspend inside a mutation, which means no explicit lock is needed —
/// but every public method is careful to finish its map edit
/// synchronously before performing any I/O.
class ConnectionManager {
  final Map<String, Set<WebSocketChannel>> _byUser = {};
  final TeamRepo? teams;

  ConnectionManager({this.teams});

  /// Attach [channel] to [username]. Returns a disposer that removes it
  /// again — callers should invoke it when the socket closes.
  void Function() register(String username, WebSocketChannel channel) {
    final set = _byUser.putIfAbsent(username, () => <WebSocketChannel>{});
    set.add(channel);
    return () => unregister(username, channel);
  }

  void unregister(String username, WebSocketChannel channel) {
    final set = _byUser[username];
    if (set == null) return;
    set.remove(channel);
    if (set.isEmpty) _byUser.remove(username);
  }

  bool isOnline(String username) {
    final set = _byUser[username];
    return set != null && set.isNotEmpty;
  }

  Set<String> onlineUsernames(Iterable<String> candidates) {
    return {for (final u in candidates) if (isOnline(u)) u};
  }

  /// Fire-and-forget send to every connection for [username]. Dead
  /// sockets are pruned lazily — we never block delivery to healthy
  /// peers on one misbehaving one.
  void sendToUser(String username, Map<String, dynamic> payload) {
    final set = _byUser[username];
    if (set == null || set.isEmpty) return;
    final encoded = jsonEncode(payload);
    // Snapshot first: a failing send could call unregister and mutate
    // the set mid-iteration.
    for (final ch in set.toList(growable: false)) {
      try {
        ch.sink.add(encoded);
      } catch (e) {
        stderr.writeln('[ws] send failed for $username: $e');
        unregister(username, ch);
      }
    }
  }

  /// Look up the membership of [teamId] and fan [payload] out to every
  /// member that currently has a live socket. [excludeUsername] skips
  /// the sender so they don't receive their own event.
  Future<void> broadcastToTeam(
    String teamId,
    Map<String, dynamic> payload, {
    String? excludeUsername,
  }) async {
    final repo = teams;
    if (repo == null) return;
    final team = await repo.getTeam(teamId);
    if (team == null) return;
    for (final member in team.members) {
      if (member.username == excludeUsername) continue;
      if (!isOnline(member.username)) continue;
      sendToUser(member.username, payload);
    }
  }

  /// Close every tracked connection. Called during graceful shutdown so
  /// clients can reconnect instead of seeing an abrupt TCP reset.
  Future<void> closeAll() async {
    final futures = <Future<void>>[];
    for (final entry in _byUser.entries.toList(growable: false)) {
      for (final ch in entry.value.toList(growable: false)) {
        futures.add(_safeClose(ch));
      }
    }
    _byUser.clear();
    await Future.wait(futures);
  }

  Future<void> _safeClose(WebSocketChannel ch) async {
    try {
      await ch.sink.close(1001, 'server shutting down');
    } catch (_) {
      // already closed, nothing to do
    }
  }
}
