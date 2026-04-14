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
      throw const HttpError(400, 'content-type must be multipart/form-data');
    }
    final boundary = media.parameters['boundary'];
    if (boundary == null) {
      throw const HttpError(400, 'multipart boundary missing');
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

    final mimeType = filePart.contentType ?? 'application/octet-stream';

    final record = await files.uploadFile(
      ownerUsername: username,
      filename: filename,
      mimeType: mimeType,
      sizeBytes: filePart.bytes.length,
      encryptedKey: encryptedKey,
      nonce: nonce,
      folderId: folderId as String?,
    );
    await store.store(record.id, filePart.bytes);
    return jsonCreated(record.toJson());
  });

  // List files visible to caller.
  app.get('/api/v1/files', (Request request) async {
    final user = _requireAuth(request);
    final folderId = request.url.queryParameters['folder'];
    final list = await files.listFiles(user, folderId: folderId);
    return jsonOk({
      'files': [for (final f in list) f.toJson()],
    });
  });

  // File metadata.
  app.get('/api/v1/files/<id>', (Request request, String id) async {
    final user = _requireAuth(request);
    final view = await files.getFile(id, user);
    return jsonOk(view.toJson());
  });

  // Download ciphertext blob.
  app.get('/api/v1/files/<id>/download',
      (Request request, String id) async {
    final user = _requireAuth(request);
    final view = await files.getFile(id, user);
    final bytes = await store.retrieve(id);
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
    final record = await files.deleteFile(id, user);
    await store.delete(record.id);
    return jsonOk({'ok': true});
  });

  // Share file with another user.
  app.post('/api/v1/files/<id>/share',
      (Request request, String id) async {
    final user = _requireAuth(request);
    final body = await readJsonBody(request);
    final shareWith = body['username'];
    final encryptedKey = body['encryptedKey'];
    final nonce = body['nonce'];
    if (shareWith is! String ||
        encryptedKey is! String ||
        nonce is! String) {
      throw const HttpError(400,
          'username, encryptedKey, and nonce are required strings');
    }
    await files.shareFile(
      fileId: id,
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
    await files.unshareFile(
      fileId: id,
      ownerUsername: user,
      sharedWithUsername: username,
    );
    return jsonOk({'ok': true});
  });

  // Folders.
  app.post('/api/v1/folders', (Request request) async {
    final user = _requireAuth(request);
    final body = await readJsonBody(request);
    final name = body['name'];
    final parentFolderId = body['parentFolderId'];
    if (name is! String || name.trim().isEmpty) {
      throw const HttpError(400, 'name is a required non-empty string');
    }
    if (parentFolderId != null && parentFolderId is! String) {
      throw const HttpError(400, 'parentFolderId must be a string');
    }
    final folder = await files.createFolder(
      ownerUsername: user,
      name: name,
      parentFolderId: parentFolderId as String?,
    );
    return jsonCreated(folder.toJson());
  });

  app.get('/api/v1/folders', (Request request) async {
    final user = _requireAuth(request);
    final parent = request.url.queryParameters['parent'];
    final list = await files.listFolders(user, parentFolderId: parent);
    return jsonOk({
      'folders': [for (final f in list) f.toJson()],
    });
  });

  app.delete('/api/v1/folders/<id>',
      (Request request, String id) async {
    final user = _requireAuth(request);
    await files.deleteFolder(id, user);
    return jsonOk({'ok': true});
  });
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
