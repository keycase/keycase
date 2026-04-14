import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../db/team_message_repo.dart';
import '../db/team_repo.dart';
import '../http/middleware.dart';
import '../http/responses.dart';
import '../ws/connection_manager.dart';

final RegExp _teamNameRegExp = RegExp(r'^[a-z0-9](?:[a-z0-9-]{1,62}[a-z0-9])$');
final RegExp _usernameRegExp = RegExp(r'^[a-z0-9]{3,32}$');

void mountTeamRoutes(
  Router app, {
  required TeamRepo teams,
  required TeamMessageRepo teamMessages,
  ConnectionManager? connections,
}) {
  // Create a team.
  app.post('/api/v1/teams', (Request request) async {
    final user = _requireAuth(request);
    final body = await readJsonBody(request);
    final name = requireString(body, 'name', maxLength: 64);
    final displayName = requireString(body, 'displayName', maxLength: 128);
    if (!_teamNameRegExp.hasMatch(name)) {
      throw const HttpError(400,
          'name must be 3-64 chars, lowercase alphanumeric and hyphens');
    }
    final team = await teams.createTeam(
      name: name,
      displayName: displayName,
      creatorUsername: user,
    );
    return jsonCreated(team.toJson());
  });

  // List teams the caller belongs to.
  app.get('/api/v1/teams', (Request request) async {
    final user = _requireAuth(request);
    final list = await teams.getTeamsForUser(user);
    return jsonOk({
      'teams': [for (final t in list) t.toJson()],
    });
  });

  // Team details (members-only).
  app.get('/api/v1/teams/<id>', (Request request, String id) async {
    final user = _requireAuth(request);
    final teamId = requireUuid(id, field: 'id');
    final team = await teams.getTeam(teamId);
    if (team == null) {
      throw const HttpError(404, 'team not found');
    }
    await teams.requireMembership(teamId, user);
    return jsonOk(team.toJson());
  });

  // Add member.
  app.post('/api/v1/teams/<id>/members',
      (Request request, String id) async {
    final user = _requireAuth(request);
    final teamId = requireUuid(id, field: 'id');
    final body = await readJsonBody(request);
    final username = _requireUsername(requireString(body, 'username'));
    final role = requireString(body, 'role', maxLength: 16);
    final member = await teams.addMember(
      teamId: teamId,
      username: username,
      role: role,
      addedByUsername: user,
    );
    if (connections != null) {
      final team = await teams.getTeam(teamId);
      if (team != null) {
        connections.sendToUser(username, {
          'type': 'team_invite',
          'team': team.toJson(),
        });
      }
    }
    return jsonCreated(member.toJson());
  });

  // Remove member.
  app.delete('/api/v1/teams/<id>/members/<username>',
      (Request request, String id, String username) async {
    final user = _requireAuth(request);
    final teamId = requireUuid(id, field: 'id');
    await teams.removeMember(
      teamId: teamId,
      username: _requireUsername(username),
      removedByUsername: user,
    );
    return jsonOk({'ok': true});
  });

  // Update role.
  app.put('/api/v1/teams/<id>/members/<username>/role',
      (Request request, String id, String username) async {
    final user = _requireAuth(request);
    final teamId = requireUuid(id, field: 'id');
    final body = await readJsonBody(request);
    final role = requireString(body, 'role', maxLength: 16);
    final member = await teams.updateRole(
      teamId: teamId,
      username: _requireUsername(username),
      newRole: role,
      updatedByUsername: user,
    );
    return jsonOk(member.toJson());
  });

  // Delete team.
  app.delete('/api/v1/teams/<id>', (Request request, String id) async {
    final user = _requireAuth(request);
    final teamId = requireUuid(id, field: 'id');
    await teams.deleteTeam(teamId: teamId, username: user);
    return jsonOk({'ok': true});
  });

  // Send a team message (fan-out: one ciphertext per recipient).
  app.post('/api/v1/teams/<id>/messages',
      (Request request, String id) async {
    final user = _requireAuth(request);
    final teamId = requireUuid(id, field: 'id');
    final body = await readJsonBody(request);
    final rawRecipients = body['recipients'];
    if (rawRecipients is! List) {
      throw const HttpError(400, 'recipients must be a list');
    }
    if (rawRecipients.isEmpty) {
      throw const HttpError(400, 'recipients must not be empty');
    }
    if (rawRecipients.length > 500) {
      throw const HttpError(400, 'recipients must be at most 500 entries');
    }
    final entries = <TeamMessageRecipient>[];
    for (final raw in rawRecipients) {
      if (raw is! Map) {
        throw const HttpError(400, 'each recipient must be an object');
      }
      final map = Map<String, dynamic>.from(raw);
      final username = _requireUsername(requireString(map, 'username'));
      final encryptedBody = requireString(map, 'encryptedBody');
      final nonce = requireString(map, 'nonce');
      entries.add(TeamMessageRecipient(
        recipientUsername: username,
        encryptedBody: encryptedBody,
        nonce: nonce,
      ));
    }
    final messages = await teamMessages.sendTeamMessage(
      teamId: teamId,
      senderUsername: user,
      recipientEntries: entries,
    );
    // Deliver each recipient's own ciphertext row. Sending one shared
    // envelope would leak the others' wrapped keys, so we fan out
    // per-recipient rather than calling broadcastToTeam.
    if (connections != null) {
      for (final m in messages) {
        connections.sendToUser(m.recipientUsername, {
          'type': 'team_message',
          'teamId': teamId,
          'message': m.toJson(),
        });
      }
    }
    return jsonCreated({
      'messages': [for (final m in messages) m.toJson()],
    });
  });

  // Fetch team messages addressed to the caller.
  app.get('/api/v1/teams/<id>/messages',
      (Request request, String id) async {
    final user = _requireAuth(request);
    final teamId = requireUuid(id, field: 'id');
    final limit = parseNonNegativeIntQuery(request.url, 'limit',
        defaultValue: 50, max: 200);
    final offset =
        parseNonNegativeIntQuery(request.url, 'offset', defaultValue: 0);
    final list = await teamMessages.getTeamMessages(
      teamId: teamId,
      username: user,
      limit: limit,
      offset: offset,
    );
    return jsonOk({
      'messages': [for (final m in list) m.toJson()],
    });
  });
}

String _requireAuth(Request request) {
  final username = request.context[authContextKey];
  if (username is! String) {
    throw const HttpError(401, 'authentication required');
  }
  return username;
}

String _requireUsername(String value) {
  if (!_usernameRegExp.hasMatch(value)) {
    throw const HttpError(400,
        'username must be 3-32 lowercase alphanumeric characters');
  }
  return value;
}
