import 'package:postgres/postgres.dart';
import 'package:uuid/uuid.dart';

import '../http/responses.dart';
import 'database.dart';

enum TeamRole { owner, admin, member }

TeamRole _parseRole(String raw) {
  for (final r in TeamRole.values) {
    if (r.name == raw) return r;
  }
  throw HttpError(400, 'invalid role: $raw');
}

class TeamMember {
  final String username;
  final TeamRole role;
  final DateTime joinedAt;

  TeamMember({
    required this.username,
    required this.role,
    required this.joinedAt,
  });

  Map<String, Object?> toJson() => {
        'username': username,
        'role': role.name,
        'joinedAt': joinedAt.toIso8601String(),
      };
}

class Team {
  final String id;
  final String name;
  final String displayName;
  final String createdBy;
  final DateTime createdAt;
  final List<TeamMember> members;

  Team({
    required this.id,
    required this.name,
    required this.displayName,
    required this.createdBy,
    required this.createdAt,
    required this.members,
  });

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'displayName': displayName,
        'createdBy': createdBy,
        'createdAt': createdAt.toIso8601String(),
        'members': [for (final m in members) m.toJson()],
      };
}

/// Persistence for teams and team membership. Permission checks live
/// here so routes stay thin and every path goes through the same guards.
class TeamRepo {
  final Database _db;
  final Uuid _uuid;

  TeamRepo(this._db, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  Future<Team> createTeam({
    required String name,
    required String displayName,
    required String creatorUsername,
  }) async {
    final existing = await getTeamByName(name);
    if (existing != null) {
      throw const HttpError(409, 'team name already taken');
    }
    final teamId = _uuid.v4();
    final memberId = _uuid.v4();
    await _db.connection.execute(
      Sql.named(
        'INSERT INTO teams (id, name, display_name, created_by) '
        'VALUES (@id::uuid, @name, @display, @by)',
      ),
      parameters: {
        'id': teamId,
        'name': name,
        'display': displayName,
        'by': creatorUsername,
      },
    );
    await _db.connection.execute(
      Sql.named(
        'INSERT INTO team_members (id, team_id, username, role) '
        'VALUES (@id::uuid, @team::uuid, @user, @role)',
      ),
      parameters: {
        'id': memberId,
        'team': teamId,
        'user': creatorUsername,
        'role': TeamRole.owner.name,
      },
    );
    final team = await getTeam(teamId);
    if (team == null) {
      throw const HttpError(500, 'failed to load team after create');
    }
    return team;
  }

  Future<Team?> getTeam(String teamId) async {
    final result = await _db.connection.execute(
      Sql.named(
        'SELECT id, name, display_name, created_by, created_at '
        'FROM teams WHERE id = @id::uuid',
      ),
      parameters: {'id': teamId},
    );
    if (result.isEmpty) return null;
    return _rowToTeam(result.first, await _membersFor(teamId));
  }

  Future<Team?> getTeamByName(String name) async {
    final result = await _db.connection.execute(
      Sql.named(
        'SELECT id, name, display_name, created_by, created_at '
        'FROM teams WHERE name = @name',
      ),
      parameters: {'name': name},
    );
    if (result.isEmpty) return null;
    final id = (result.first[0]).toString();
    return _rowToTeam(result.first, await _membersFor(id));
  }

  Future<List<Team>> getTeamsForUser(String username) async {
    final result = await _db.connection.execute(
      Sql.named(
        'SELECT t.id, t.name, t.display_name, t.created_by, t.created_at '
        'FROM teams t '
        'JOIN team_members m ON m.team_id = t.id '
        'WHERE m.username = @u '
        'ORDER BY t.created_at DESC',
      ),
      parameters: {'u': username},
    );
    final teams = <Team>[];
    for (final row in result) {
      final id = row[0].toString();
      teams.add(_rowToTeam(row, await _membersFor(id)));
    }
    return teams;
  }

  /// Return the caller's [TeamRole] in [teamId], or throw 403 if not a member.
  Future<TeamRole> requireMembership(String teamId, String username) async {
    final role = await getRole(teamId, username);
    if (role == null) {
      throw const HttpError(403, 'not a member of this team');
    }
    return role;
  }

  Future<TeamRole?> getRole(String teamId, String username) async {
    final result = await _db.connection.execute(
      Sql.named(
        'SELECT role FROM team_members '
        'WHERE team_id = @t::uuid AND username = @u',
      ),
      parameters: {'t': teamId, 'u': username},
    );
    if (result.isEmpty) return null;
    return _parseRole(result.first[0] as String);
  }

  Future<TeamMember> addMember({
    required String teamId,
    required String username,
    required String role,
    required String addedByUsername,
  }) async {
    await _requireTeamExists(teamId);
    final actor = await requireMembership(teamId, addedByUsername);
    if (actor != TeamRole.owner && actor != TeamRole.admin) {
      throw const HttpError(403, 'only owner or admin can add members');
    }
    final parsedRole = _parseRole(role);
    if (parsedRole == TeamRole.owner) {
      throw const HttpError(400, 'cannot add another owner; update role instead');
    }
    final existing = await getRole(teamId, username);
    if (existing != null) {
      throw const HttpError(409, 'user is already a member');
    }
    final id = _uuid.v4();
    final result = await _db.connection.execute(
      Sql.named(
        'INSERT INTO team_members (id, team_id, username, role) '
        'VALUES (@id::uuid, @t::uuid, @u, @r) '
        'RETURNING username, role, joined_at',
      ),
      parameters: {
        'id': id,
        't': teamId,
        'u': username,
        'r': parsedRole.name,
      },
    );
    return _rowToMember(result.first);
  }

  Future<void> removeMember({
    required String teamId,
    required String username,
    required String removedByUsername,
  }) async {
    await _requireTeamExists(teamId);
    final actor = await requireMembership(teamId, removedByUsername);
    if (actor != TeamRole.owner && actor != TeamRole.admin) {
      throw const HttpError(403, 'only owner or admin can remove members');
    }
    final target = await getRole(teamId, username);
    if (target == null) {
      throw const HttpError(404, 'user is not a member');
    }
    if (target == TeamRole.owner) {
      throw const HttpError(400, 'cannot remove the team owner');
    }
    await _db.connection.execute(
      Sql.named(
        'DELETE FROM team_members '
        'WHERE team_id = @t::uuid AND username = @u',
      ),
      parameters: {'t': teamId, 'u': username},
    );
  }

  Future<TeamMember> updateRole({
    required String teamId,
    required String username,
    required String newRole,
    required String updatedByUsername,
  }) async {
    await _requireTeamExists(teamId);
    final actor = await requireMembership(teamId, updatedByUsername);
    if (actor != TeamRole.owner) {
      throw const HttpError(403, 'only the owner can change roles');
    }
    final target = await getRole(teamId, username);
    if (target == null) {
      throw const HttpError(404, 'user is not a member');
    }
    final parsed = _parseRole(newRole);
    if (parsed == TeamRole.owner) {
      throw const HttpError(400,
          'ownership transfer is not supported via role update');
    }
    if (target == TeamRole.owner) {
      throw const HttpError(400, "cannot demote the team's owner");
    }
    final result = await _db.connection.execute(
      Sql.named(
        'UPDATE team_members SET role = @r '
        'WHERE team_id = @t::uuid AND username = @u '
        'RETURNING username, role, joined_at',
      ),
      parameters: {'t': teamId, 'u': username, 'r': parsed.name},
    );
    return _rowToMember(result.first);
  }

  Future<void> deleteTeam({
    required String teamId,
    required String username,
  }) async {
    await _requireTeamExists(teamId);
    final actor = await requireMembership(teamId, username);
    if (actor != TeamRole.owner) {
      throw const HttpError(403, 'only the owner can delete the team');
    }
    await _db.connection.execute(
      Sql.named('DELETE FROM teams WHERE id = @id::uuid'),
      parameters: {'id': teamId},
    );
  }

  Future<void> _requireTeamExists(String teamId) async {
    final result = await _db.connection.execute(
      Sql.named('SELECT 1 FROM teams WHERE id = @id::uuid'),
      parameters: {'id': teamId},
    );
    if (result.isEmpty) {
      throw const HttpError(404, 'team not found');
    }
  }

  Future<List<TeamMember>> _membersFor(String teamId) async {
    final result = await _db.connection.execute(
      Sql.named(
        'SELECT username, role, joined_at FROM team_members '
        'WHERE team_id = @t::uuid ORDER BY joined_at ASC',
      ),
      parameters: {'t': teamId},
    );
    return [for (final r in result) _rowToMember(r)];
  }

  TeamMember _rowToMember(ResultRow row) => TeamMember(
        username: row[0] as String,
        role: _parseRole(row[1] as String),
        joinedAt: (row[2] as DateTime).toUtc(),
      );

  Team _rowToTeam(ResultRow row, List<TeamMember> members) => Team(
        id: row[0].toString(),
        name: row[1] as String,
        displayName: row[2] as String,
        createdBy: row[3] as String,
        createdAt: (row[4] as DateTime).toUtc(),
        members: members,
      );
}
