import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../db/team_message_repo.dart';
import '../db/team_repo.dart';
import '../http/middleware.dart';
import '../http/responses.dart';

final RegExp _teamNameRegExp = RegExp(r'^[a-z0-9](?:[a-z0-9-]{1,62}[a-z0-9])$');

void mountTeamRoutes(
  Router app, {
  required TeamRepo teams,
  required TeamMessageRepo teamMessages,
}) {
  // Create a team.
  app.post('/api/v1/teams', (Request request) async {
    final user = _requireAuth(request);
    final body = await readJsonBody(request);
    final name = body['name'];
    final displayName = body['displayName'];
    if (name is! String || displayName is! String) {
      throw const HttpError(400,
          'name and displayName are required strings');
    }
    if (!_teamNameRegExp.hasMatch(name)) {
      throw const HttpError(400,
          'name must be 3-64 chars, lowercase alphanumeric and hyphens');
    }
    if (displayName.trim().isEmpty) {
      throw const HttpError(400, 'displayName must not be blank');
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
    final team = await teams.getTeam(id);
    if (team == null) {
      throw const HttpError(404, 'team not found');
    }
    await teams.requireMembership(id, user);
    return jsonOk(team.toJson());
  });

  // Add member.
  app.post('/api/v1/teams/<id>/members',
      (Request request, String id) async {
    final user = _requireAuth(request);
    final body = await readJsonBody(request);
    final username = body['username'];
    final role = body['role'];
    if (username is! String || role is! String) {
      throw const HttpError(400, 'username and role are required strings');
    }
    final member = await teams.addMember(
      teamId: id,
      username: username,
      role: role,
      addedByUsername: user,
    );
    return jsonCreated(member.toJson());
  });

  // Remove member.
  app.delete('/api/v1/teams/<id>/members/<username>',
      (Request request, String id, String username) async {
    final user = _requireAuth(request);
    await teams.removeMember(
      teamId: id,
      username: username,
      removedByUsername: user,
    );
    return jsonOk({'ok': true});
  });

  // Update role.
  app.put('/api/v1/teams/<id>/members/<username>/role',
      (Request request, String id, String username) async {
    final user = _requireAuth(request);
    final body = await readJsonBody(request);
    final role = body['role'];
    if (role is! String) {
      throw const HttpError(400, 'role is a required string');
    }
    final member = await teams.updateRole(
      teamId: id,
      username: username,
      newRole: role,
      updatedByUsername: user,
    );
    return jsonOk(member.toJson());
  });

  // Delete team.
  app.delete('/api/v1/teams/<id>', (Request request, String id) async {
    final user = _requireAuth(request);
    await teams.deleteTeam(teamId: id, username: user);
    return jsonOk({'ok': true});
  });

  // Send a team message (fan-out: one ciphertext per recipient).
  app.post('/api/v1/teams/<id>/messages',
      (Request request, String id) async {
    final user = _requireAuth(request);
    final body = await readJsonBody(request);
    final rawRecipients = body['recipients'];
    if (rawRecipients is! List) {
      throw const HttpError(400, 'recipients must be a list');
    }
    final entries = <TeamMessageRecipient>[];
    for (final raw in rawRecipients) {
      if (raw is! Map) {
        throw const HttpError(400, 'each recipient must be an object');
      }
      final username = raw['username'];
      final encryptedBody = raw['encryptedBody'];
      final nonce = raw['nonce'];
      if (username is! String ||
          encryptedBody is! String ||
          nonce is! String) {
        throw const HttpError(400,
            'each recipient requires username, encryptedBody, nonce strings');
      }
      entries.add(TeamMessageRecipient(
        recipientUsername: username,
        encryptedBody: encryptedBody,
        nonce: nonce,
      ));
    }
    final messages = await teamMessages.sendTeamMessage(
      teamId: id,
      senderUsername: user,
      recipientEntries: entries,
    );
    return jsonCreated({
      'messages': [for (final m in messages) m.toJson()],
    });
  });

  // Fetch team messages addressed to the caller.
  app.get('/api/v1/teams/<id>/messages',
      (Request request, String id) async {
    final user = _requireAuth(request);
    final limit = _parseIntParam(request, 'limit', defaultValue: 50, max: 200);
    final offset = _parseIntParam(request, 'offset', defaultValue: 0);
    final list = await teamMessages.getTeamMessages(
      teamId: id,
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

int _parseIntParam(
  Request request,
  String name, {
  required int defaultValue,
  int? max,
}) {
  final raw = request.url.queryParameters[name];
  if (raw == null || raw.isEmpty) return defaultValue;
  final parsed = int.tryParse(raw);
  if (parsed == null || parsed < 0) {
    throw HttpError(400, '$name must be a non-negative integer');
  }
  if (max != null && parsed > max) return max;
  return parsed;
}
