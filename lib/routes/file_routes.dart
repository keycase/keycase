import 'dart:convert';
import 'dart:typed_data';

import 'package:http_parser/http_parser.dart';
import 'package:keycase_core/keycase_core.dart' as core;
import 'package:mime/mime.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../db/file_repo.dart';
import '../db/identity_repo.dart';
import '../http/middleware.dart';
import '../http/responses.dart';
import '../storage/file_store.dart';

/// Hard cap on a single uploaded blob. Enforced while streaming so we
/// fail fast instead of buffering hostile payloads.
const int _maxUploadBytes = 50 * 1024 * 1024;

/// Explicit allow-list of mime types the server will store. Anything
/// else must come in as `application/octet-stream` (opaque ciphertext).
/// The filter is a safety net — even though the server only ever sees
/// ciphertext, a bad mime type on download could be weaponized against
/// older browsers, so we canonicalize here.
const Set<String> _allowedMimeTypes = {
  'application/octet-stream',
  'application/pdf',
  'application/json',
  'application/zip',
  'application/x-tar',
  'application/gzip',
  'text/plain',
  'text/markdown',
  'text/csv',
  'image/png',
  'image/jpeg',
  'image/gif',
  'image/webp',
  'image/svg+xml',
  'audio/mpeg',
  'audio/ogg',
  'audio/wav',
  'video/mp4',
  'video/webm',
};

void mountFileRoutes(
  Router app, {
  required IdentityRepo identities,
  required FileRepo files,
  required FileStore store,
}) {
  // Upload — auth is handled inline because the body is binary and
  // cannot pass through the UTF-8 body-signing middleware.
  app.post('/api/v1/files', (Request request) async {
    final contentType = request.headers['content-type'];
    if (contentType == null) {
      throw const HttpError(400, 'missing content-type');
    }
    final media = MediaType.parse(contentType);
    if (media.type != 'multipart' || media.subtype != 'form-data') {
      throw const HttpError(
        415,
        'content-type must be multipart/form-data',
        code: 'UNSUPPORTED_MEDIA_TYPE',
      );
    }
    final boundary = media.parameters['boundary'];
    if (boundary == null) {
      throw const HttpError(400, 'multipart boundary missing');
    }

    // Fail fast on oversized uploads before we start buffering. The
    // per-part streaming cap inside _readMultipartParts is the real
    // enforcement — this just avoids accepting the body at all when
    // the client has already declared an oversized length.
    final declaredLength =
        int.tryParse(request.headers['content-length'] ?? '');
    if (declaredLength != null && declaredLength > _maxUploadBytes) {
      throw const HttpError(
        413,
        'upload exceeds 50MB limit',
        code: 'PAYLOAD_TOO_LARGE',
      );
    }

    final (username, signature) = _parseAuthHeader(request);

    final parts = await _readMultipartParts(request, boundary);
    final metadataPart = parts['metadata'];
    final filePart = parts['file'];
    if (metadataPart == null) {
      throw const HttpError(400, 'missing "metadata" field');
    }
    if (filePart == null) {
      throw const HttpError(400, 'missing "file" field');
    }

    final metadataJson = utf8.decode(metadataPart.bytes);
    final identity = await identities.findByUsername(username);
    if (identity == null) {
      throw const HttpError(401, 'unknown identity');
    }
    final ok = await core.verify(metadataJson, signature, identity.publicKey);
    if (!ok) {
      throw const HttpError(401, 'invalid signature');
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(metadataJson);
    } on FormatException catch (e) {
      throw HttpError(400, 'invalid metadata JSON: ${e.message}');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const HttpError(400, 'metadata must be a JSON object');
    }
    final filename = decoded['filename'];
    final encryptedKey = decoded['encryptedKey'];
    final nonce = decoded['nonce'];
    final folderId = decoded['folderId'];
    if (filename is! String ||
        encryptedKey is! String ||
        nonce is! String) {
      throw const HttpError(400,
          'metadata.filename, encryptedKey, and nonce are required strings');
    }
    if (folderId != null && folderId is! String) {
      throw const HttpError(400, 'metadata.folderId must be a string');
    }

    final rawMime = filePart.contentType ?? 'application/octet-stream';
    final mimeType = _normalizeMime(rawMime);
    final safeFilename = _sanitizeFilename(filename);
    if (safeFilename.isEmpty) {
      throw const HttpError(400, 'filename must contain safe characters');
    }

    final folderIdValue =
        folderId == null ? null : requireUuid(folderId, field: 'folderId');

    final record = await files.uploadFile(
      ownerUsername: username,
      filename: safeFilename,
      mimeType: mimeType,
      sizeBytes: filePart.bytes.length,
      encryptedKey: encryptedKey,
      nonce: nonce,
      folderId: folderIdValue,
    );
    await store.store(record.id, filePart.bytes);
    return jsonCreated(record.toJson());
  });

  // List files visible to caller.
  app.get('/api/v1/files', (Request request) async {
    final user = _requireAuth(request);
    final raw = request.url.queryParameters['folder'];
    final folderId = raw == null || raw.isEmpty
        ? null
        : requireUuid(raw, field: 'folder');
    final list = await files.listFiles(user, folderId: folderId);
    return jsonOk({
      'files': [for (final f in list) f.toJson()],
    });
  });

  // File metadata.
  app.get('/api/v1/files/<id>', (Request request, String id) async {
    final user = _requireAuth(request);
    final fileId = requireUuid(id, field: 'id');
    final view = await files.getFile(fileId, user);
    return jsonOk(view.toJson());
  });

  // Download ciphertext blob.
  app.get('/api/v1/files/<id>/download',
      (Request request, String id) async {
    final user = _requireAuth(request);
    final fileId = requireUuid(id, field: 'id');
    final view = await files.getFile(fileId, user);
    final bytes = await store.retrieve(fileId);
    return Response.ok(
      bytes,
      headers: {
        'Content-Type': 'application/octet-stream',
        'Content-Length': bytes.length.toString(),
        'Content-Disposition':
            'attachment; filename="${_sanitizeFilename(view.file.filename)}"',
      },
    );
  });

  // Delete file.
  app.delete('/api/v1/files/<id>', (Request request, String id) async {
    final user = _requireAuth(request);
    final fileId = requireUuid(id, field: 'id');
    final record = await files.deleteFile(fileId, user);
    await store.delete(record.id);
    return jsonOk({'ok': true});
  });

  // Share file with another user.
  app.post('/api/v1/files/<id>/share',
      (Request request, String id) async {
    final user = _requireAuth(request);
    final fileId = requireUuid(id, field: 'id');
    final body = await readJsonBody(request);
    final shareWith = requireString(body, 'username', maxLength: 64);
    final encryptedKey = requireString(body, 'encryptedKey');
    final nonce = requireString(body, 'nonce');
    await files.shareFile(
      fileId: fileId,
      ownerUsername: user,
      sharedWithUsername: shareWith,
      encryptedKey: encryptedKey,
      nonce: nonce,
    );
    return jsonCreated({'ok': true});
  });

  // Unshare.
  app.delete('/api/v1/files/<id>/share/<username>',
      (Request request, String id, String username) async {
    final user = _requireAuth(request);
    final fileId = requireUuid(id, field: 'id');
    await files.unshareFile(
      fileId: fileId,
      ownerUsername: user,
      sharedWithUsername: username,
    );
    return jsonOk({'ok': true});
  });

  // Folders.
  app.post('/api/v1/folders', (Request request) async {
    final user = _requireAuth(request);
    final body = await readJsonBody(request);
    final name = requireString(body, 'name', maxLength: 128);
    final parentFolderId =
        optionalUuid(body['parentFolderId'], field: 'parentFolderId');
    final folder = await files.createFolder(
      ownerUsername: user,
      name: name,
      parentFolderId: parentFolderId,
    );
    return jsonCreated(folder.toJson());
  });

  app.get('/api/v1/folders', (Request request) async {
    final user = _requireAuth(request);
    final parentRaw = request.url.queryParameters['parent'];
    final parent = parentRaw == null || parentRaw.isEmpty
        ? null
        : requireUuid(parentRaw, field: 'parent');
    final list = await files.listFolders(user, parentFolderId: parent);
    return jsonOk({
      'folders': [for (final f in list) f.toJson()],
    });
  });

  app.delete('/api/v1/folders/<id>',
      (Request request, String id) async {
    final user = _requireAuth(request);
    final folderId = requireUuid(id, field: 'id');
    await files.deleteFolder(folderId, user);
    return jsonOk({'ok': true});
  });
}

String _normalizeMime(String raw) {
  // Strip any parameter suffix like "; charset=utf-8" before checking.
  final semi = raw.indexOf(';');
  final base = (semi == -1 ? raw : raw.substring(0, semi)).trim().toLowerCase();
  if (base.isEmpty) return 'application/octet-stream';
  if (_allowedMimeTypes.contains(base)) return base;
  return 'application/octet-stream';
}

String _requireAuth(Request request) {
  final username = request.context[authContextKey];
  if (username is! String) {
    throw const HttpError(401, 'authentication required');
  }
  return username;
}

/// Pull `Authorization: KeyCase <user>:<sig>` off an unauthenticated
/// request (used by the upload path, which bypasses the body-signing
/// middleware).
(String, String) _parseAuthHeader(Request request) {
  final header = request.headers['authorization'];
  if (header == null || !header.startsWith('KeyCase ')) {
    throw const HttpError(401, 'missing KeyCase authorization header');
  }
  final creds = header.substring('KeyCase '.length);
  final colon = creds.indexOf(':');
  if (colon <= 0 || colon == creds.length - 1) {
    throw const HttpError(401, 'malformed authorization header');
  }
  return (creds.substring(0, colon), creds.substring(colon + 1));
}

class _MultipartPart {
  final Uint8List bytes;
  final String? contentType;
  _MultipartPart(this.bytes, this.contentType);
}

/// Read all parts of a multipart form into memory, keyed by the
/// `name=` attribute from each part's Content-Disposition header.
/// Throws 413 if the combined payload exceeds [_maxUploadBytes].
Future<Map<String, _MultipartPart>> _readMultipartParts(
  Request request,
  String boundary,
) async {
  final parts = <String, _MultipartPart>{};
  var total = 0;
  await for (final part
      in MimeMultipartTransformer(boundary).bind(request.read())) {
    final disposition = part.headers['content-disposition'];
    if (disposition == null) {
      // Drain and skip anonymous parts.
      await for (final _ in part) {}
      continue;
    }
    final name = _extractDispositionName(disposition);
    if (name == null) {
      await for (final _ in part) {}
      continue;
    }
    final chunks = BytesBuilder(copy: false);
    await for (final chunk in part) {
      total += chunk.length;
      if (total > _maxUploadBytes) {
        throw const HttpError(
            413, 'upload exceeds 50MB limit');
      }
      chunks.add(chunk);
    }
    parts[name] = _MultipartPart(
      chunks.takeBytes(),
      part.headers['content-type'],
    );
  }
  return parts;
}

final _dispositionNameRegExp =
    RegExp(r'name="([^"]*)"', caseSensitive: false);

String? _extractDispositionName(String disposition) {
  final m = _dispositionNameRegExp.firstMatch(disposition);
  return m?.group(1);
}

final _unsafeFilenameChars = RegExp(r'[^A-Za-z0-9._\- ]');

String _sanitizeFilename(String name) =>
    name.replaceAll(_unsafeFilenameChars, '_');
