import 'package:postgres/postgres.dart';
import 'package:uuid/uuid.dart';

import '../http/responses.dart';
import 'database.dart';

class FileRecord {
  final String id;
  final String ownerUsername;
  final String filename;
  final String mimeType;
  final int sizeBytes;
  final String encryptedKey;
  final String nonce;
  final DateTime createdAt;
  final DateTime updatedAt;

  FileRecord({
    required this.id,
    required this.ownerUsername,
    required this.filename,
    required this.mimeType,
    required this.sizeBytes,
    required this.encryptedKey,
    required this.nonce,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, Object?> toJson() => {
        'id': id,
        'ownerUsername': ownerUsername,
        'filename': filename,
        'mimeType': mimeType,
        'sizeBytes': sizeBytes,
        'encryptedKey': encryptedKey,
        'nonce': nonce,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };
}

/// A file as it appears to some [viewer]. Owners see the raw metadata;
/// recipients see their re-wrapped [encryptedKey] and [nonce] instead
/// of the owner's.
class FileView {
  final FileRecord file;
  final String viewerEncryptedKey;
  final String viewerNonce;
  final bool isOwner;
  final String? sharedByUsername;

  FileView({
    required this.file,
    required this.viewerEncryptedKey,
    required this.viewerNonce,
    required this.isOwner,
    required this.sharedByUsername,
  });

  Map<String, Object?> toJson() => {
        ...file.toJson(),
        'encryptedKey': viewerEncryptedKey,
        'nonce': viewerNonce,
        'isOwner': isOwner,
        if (sharedByUsername != null) 'sharedByUsername': sharedByUsername,
      };
}

class SharedUser {
  final String username;
  final DateTime sharedAt;

  SharedUser({required this.username, required this.sharedAt});

  Map<String, Object?> toJson() => {
        'username': username,
        'sharedAt': sharedAt.toIso8601String(),
      };
}

class Folder {
  final String id;
  final String ownerUsername;
  final String name;
  final String? parentFolderId;
  final DateTime createdAt;

  Folder({
    required this.id,
    required this.ownerUsername,
    required this.name,
    required this.parentFolderId,
    required this.createdAt,
  });

  Map<String, Object?> toJson() => {
        'id': id,
        'ownerUsername': ownerUsername,
        'name': name,
        'parentFolderId': parentFolderId,
        'createdAt': createdAt.toIso8601String(),
      };
}

/// Persistence for files, shares, and folders. Ownership and share
/// checks live here so every route path goes through the same gate.
class FileRepo {
  final Database _db;
  final Uuid _uuid;

  FileRepo(this._db, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  static const _fileColumns =
      'id, owner_username, filename, mime_type, size_bytes, encrypted_key, '
      'nonce, created_at, updated_at';

  Future<FileRecord> uploadFile({
    required String ownerUsername,
    required String filename,
    required String mimeType,
    required int sizeBytes,
    required String encryptedKey,
    required String nonce,
    String? folderId,
  }) async {
    final id = _uuid.v4();
    final result = await _db.connection.execute(
      Sql.named(
        'INSERT INTO files '
        '(id, owner_username, filename, mime_type, size_bytes, '
        'encrypted_key, nonce) '
        'VALUES (@id::uuid, @owner, @name, @mime, @size, @key, @nonce) '
        'RETURNING $_fileColumns',
      ),
      parameters: {
        'id': id,
        'owner': ownerUsername,
        'name': filename,
        'mime': mimeType,
        'size': sizeBytes,
        'key': encryptedKey,
        'nonce': nonce,
      },
    );
    final record = _rowToFile(result.first);
    if (folderId != null) {
      await _assertFolderOwnedBy(folderId, ownerUsername);
      await _db.connection.execute(
        Sql.named(
          'INSERT INTO file_folders (file_id, folder_id) '
          'VALUES (@f::uuid, @fo::uuid)',
        ),
        parameters: {'f': record.id, 'fo': folderId},
      );
    }
    return record;
  }

  /// Return metadata for [fileId] as visible to [username]. The caller
  /// must be the owner or have the file shared with them.
  Future<FileView> getFile(String fileId, String username) async {
    final record = await _findFileById(fileId);
    if (record == null) {
      throw const HttpError(404, 'file not found');
    }
    if (record.ownerUsername == username) {
      return FileView(
        file: record,
        viewerEncryptedKey: record.encryptedKey,
        viewerNonce: record.nonce,
        isOwner: true,
        sharedByUsername: null,
      );
    }
    final share = await _findShare(fileId, username);
    if (share == null) {
      throw const HttpError(403, 'access denied');
    }
    return FileView(
      file: record,
      viewerEncryptedKey: share['encrypted_key'] as String,
      viewerNonce: share['nonce'] as String,
      isOwner: false,
      sharedByUsername: share['shared_by_username'] as String,
    );
  }

  Future<List<FileView>> listFiles(
    String username, {
    String? folderId,
  }) async {
    final owned = await _listOwnedFiles(username, folderId: folderId);
    // Only scope "shared with me" to root (no folder filter) — shares
    // don't live inside the recipient's folders.
    final shared = folderId == null ? await _listSharedFiles(username) : <FileView>[];
    final out = [...owned, ...shared];
    out.sort((a, b) => b.file.createdAt.compareTo(a.file.createdAt));
    return out;
  }

  /// Delete a file. Only the owner can delete. Returns the record so
  /// the route can remove the blob from disk as well.
  Future<FileRecord> deleteFile(String fileId, String username) async {
    final record = await _findFileById(fileId);
    if (record == null) {
      throw const HttpError(404, 'file not found');
    }
    if (record.ownerUsername != username) {
      throw const HttpError(403, 'only the owner can delete this file');
    }
    await _db.connection.execute(
      Sql.named('DELETE FROM files WHERE id = @id::uuid'),
      parameters: {'id': fileId},
    );
    return record;
  }

  Future<void> shareFile({
    required String fileId,
    required String ownerUsername,
    required String sharedWithUsername,
    required String encryptedKey,
    required String nonce,
  }) async {
    final record = await _findFileById(fileId);
    if (record == null) {
      throw const HttpError(404, 'file not found');
    }
    if (record.ownerUsername != ownerUsername) {
      throw const HttpError(403, 'only the owner can share this file');
    }
    if (sharedWithUsername == ownerUsername) {
      throw const HttpError(400, 'cannot share a file with yourself');
    }
    final recipient = await _db.connection.execute(
      Sql.named('SELECT 1 FROM identities WHERE username = @u'),
      parameters: {'u': sharedWithUsername},
    );
    if (recipient.isEmpty) {
      throw const HttpError(404, 'recipient not found');
    }
    final id = _uuid.v4();
    await _db.connection.execute(
      Sql.named(
        'INSERT INTO shared_files '
        '(id, file_id, shared_with_username, encrypted_key, nonce, '
        'shared_by_username) '
        'VALUES (@id::uuid, @f::uuid, @u, @k, @n, @by) '
        'ON CONFLICT (file_id, shared_with_username) DO UPDATE SET '
        'encrypted_key = EXCLUDED.encrypted_key, '
        'nonce = EXCLUDED.nonce, '
        'shared_by_username = EXCLUDED.shared_by_username, '
        'shared_at = NOW()',
      ),
      parameters: {
        'id': id,
        'f': fileId,
        'u': sharedWithUsername,
        'k': encryptedKey,
        'n': nonce,
        'by': ownerUsername,
      },
    );
  }

  Future<void> unshareFile({
    required String fileId,
    required String ownerUsername,
    required String sharedWithUsername,
  }) async {
    final record = await _findFileById(fileId);
    if (record == null) {
      throw const HttpError(404, 'file not found');
    }
    if (record.ownerUsername != ownerUsername) {
      throw const HttpError(403, 'only the owner can unshare this file');
    }
    await _db.connection.execute(
      Sql.named(
        'DELETE FROM shared_files '
        'WHERE file_id = @f::uuid AND shared_with_username = @u',
      ),
      parameters: {'f': fileId, 'u': sharedWithUsername},
    );
  }

  Future<List<SharedUser>> getSharedUsers(
    String fileId,
    String ownerUsername,
  ) async {
    final record = await _findFileById(fileId);
    if (record == null) {
      throw const HttpError(404, 'file not found');
    }
    if (record.ownerUsername != ownerUsername) {
      throw const HttpError(403, 'only the owner can list shares');
    }
    final result = await _db.connection.execute(
      Sql.named(
        'SELECT shared_with_username, shared_at FROM shared_files '
        'WHERE file_id = @f::uuid ORDER BY shared_at ASC',
      ),
      parameters: {'f': fileId},
    );
    return [
      for (final row in result)
        SharedUser(
          username: row[0] as String,
          sharedAt: (row[1] as DateTime).toUtc(),
        ),
    ];
  }

  Future<Folder> createFolder({
    required String ownerUsername,
    required String name,
    String? parentFolderId,
  }) async {
    if (parentFolderId != null) {
      await _assertFolderOwnedBy(parentFolderId, ownerUsername);
    }
    final id = _uuid.v4();
    final result = await _db.connection.execute(
      Sql.named(
        'INSERT INTO folders (id, owner_username, name, parent_folder_id) '
        'VALUES (@id::uuid, @owner, @name, @parent) '
        'RETURNING id, owner_username, name, parent_folder_id, created_at',
      ),
      parameters: {
        'id': id,
        'owner': ownerUsername,
        'name': name,
        'parent': parentFolderId,
      },
    );
    return _rowToFolder(result.first);
  }

  Future<List<Folder>> listFolders(
    String ownerUsername, {
    String? parentFolderId,
  }) async {
    final parentClause = parentFolderId == null
        ? 'parent_folder_id IS NULL'
        : 'parent_folder_id = @parent::uuid';
    final result = await _db.connection.execute(
      Sql.named(
        'SELECT id, owner_username, name, parent_folder_id, created_at '
        'FROM folders '
        'WHERE owner_username = @owner AND $parentClause '
        'ORDER BY name ASC',
      ),
      parameters: {
        'owner': ownerUsername,
        if (parentFolderId != null) 'parent': parentFolderId,
      },
    );
    return [for (final row in result) _rowToFolder(row)];
  }

  Future<void> deleteFolder(String folderId, String ownerUsername) async {
    await _assertFolderOwnedBy(folderId, ownerUsername);
    final childFiles = await _db.connection.execute(
      Sql.named(
        'SELECT 1 FROM file_folders WHERE folder_id = @id::uuid LIMIT 1',
      ),
      parameters: {'id': folderId},
    );
    if (childFiles.isNotEmpty) {
      throw const HttpError(400, 'folder is not empty');
    }
    final childFolders = await _db.connection.execute(
      Sql.named(
        'SELECT 1 FROM folders WHERE parent_folder_id = @id::uuid LIMIT 1',
      ),
      parameters: {'id': folderId},
    );
    if (childFolders.isNotEmpty) {
      throw const HttpError(400, 'folder is not empty');
    }
    await _db.connection.execute(
      Sql.named('DELETE FROM folders WHERE id = @id::uuid'),
      parameters: {'id': folderId},
    );
  }

  Future<FileRecord?> _findFileById(String fileId) async {
    final result = await _db.connection.execute(
      Sql.named('SELECT $_fileColumns FROM files WHERE id = @id::uuid'),
      parameters: {'id': fileId},
    );
    if (result.isEmpty) return null;
    return _rowToFile(result.first);
  }

  Future<Map<String, Object?>?> _findShare(
      String fileId, String username) async {
    final result = await _db.connection.execute(
      Sql.named(
        'SELECT encrypted_key, nonce, shared_by_username FROM shared_files '
        'WHERE file_id = @f::uuid AND shared_with_username = @u',
      ),
      parameters: {'f': fileId, 'u': username},
    );
    if (result.isEmpty) return null;
    final row = result.first;
    return {
      'encrypted_key': row[0] as String,
      'nonce': row[1] as String,
      'shared_by_username': row[2] as String,
    };
  }

  Future<List<FileView>> _listOwnedFiles(
    String username, {
    String? folderId,
  }) async {
    final Result result;
    if (folderId == null) {
      result = await _db.connection.execute(
        Sql.named(
          'SELECT $_fileColumns FROM files '
          'WHERE owner_username = @u '
          'ORDER BY created_at DESC',
        ),
        parameters: {'u': username},
      );
    } else {
      await _assertFolderOwnedBy(folderId, username);
      result = await _db.connection.execute(
        Sql.named(
          'SELECT f.id, f.owner_username, f.filename, f.mime_type, '
          'f.size_bytes, f.encrypted_key, f.nonce, f.created_at, f.updated_at '
          'FROM files f '
          'JOIN file_folders ff ON ff.file_id = f.id '
          'WHERE f.owner_username = @u AND ff.folder_id = @fo::uuid '
          'ORDER BY f.created_at DESC',
        ),
        parameters: {'u': username, 'fo': folderId},
      );
    }
    return [
      for (final row in result)
        FileView(
          file: _rowToFile(row),
          viewerEncryptedKey: row[5] as String,
          viewerNonce: row[6] as String,
          isOwner: true,
          sharedByUsername: null,
        ),
    ];
  }

  Future<List<FileView>> _listSharedFiles(String username) async {
    final result = await _db.connection.execute(
      Sql.named(
        'SELECT f.id, f.owner_username, f.filename, f.mime_type, '
        'f.size_bytes, f.encrypted_key, f.nonce, f.created_at, f.updated_at, '
        's.encrypted_key, s.nonce, s.shared_by_username '
        'FROM files f '
        'JOIN shared_files s ON s.file_id = f.id '
        'WHERE s.shared_with_username = @u '
        'ORDER BY s.shared_at DESC',
      ),
      parameters: {'u': username},
    );
    return [
      for (final row in result)
        FileView(
          file: _rowToFile(row),
          viewerEncryptedKey: row[9] as String,
          viewerNonce: row[10] as String,
          isOwner: false,
          sharedByUsername: row[11] as String,
        ),
    ];
  }

  Future<void> _assertFolderOwnedBy(
      String folderId, String ownerUsername) async {
    final result = await _db.connection.execute(
      Sql.named(
        'SELECT owner_username FROM folders WHERE id = @id::uuid',
      ),
      parameters: {'id': folderId},
    );
    if (result.isEmpty) {
      throw const HttpError(404, 'folder not found');
    }
    if (result.first[0] != ownerUsername) {
      throw const HttpError(403, 'folder belongs to another user');
    }
  }

  FileRecord _rowToFile(ResultRow row) => FileRecord(
        id: row[0].toString(),
        ownerUsername: row[1] as String,
        filename: row[2] as String,
        mimeType: row[3] as String,
        sizeBytes: (row[4] as num).toInt(),
        encryptedKey: row[5] as String,
        nonce: row[6] as String,
        createdAt: (row[7] as DateTime).toUtc(),
        updatedAt: (row[8] as DateTime).toUtc(),
      );

  Folder _rowToFolder(ResultRow row) => Folder(
        id: row[0].toString(),
        ownerUsername: row[1] as String,
        name: row[2] as String,
        parentFolderId: row[3]?.toString(),
        createdAt: (row[4] as DateTime).toUtc(),
      );
}
