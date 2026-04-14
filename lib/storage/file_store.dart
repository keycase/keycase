import 'dart:io';
import 'dart:typed_data';

/// Storage backend for encrypted file blobs. The server holds only
/// ciphertext; implementations need not know anything about the
/// encryption scheme.
abstract class FileStore {
  Future<void> store(String fileId, List<int> bytes);
  Future<Uint8List> retrieve(String fileId);
  Future<void> delete(String fileId);
}

/// Disk-backed [FileStore]. Files are fanned out into two-character
/// shard directories to avoid giant single directories under heavy load.
class LocalFileStore implements FileStore {
  final String rootPath;

  LocalFileStore(this.rootPath);

  File _fileFor(String fileId) {
    final shard = fileId.length >= 2 ? fileId.substring(0, 2) : '_';
    return File('$rootPath/$shard/$fileId');
  }

  @override
  Future<void> store(String fileId, List<int> bytes) async {
    final file = _fileFor(fileId);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  @override
  Future<Uint8List> retrieve(String fileId) async {
    final file = _fileFor(fileId);
    if (!await file.exists()) {
      throw FileSystemException('blob not found', file.path);
    }
    return file.readAsBytes();
  }

  @override
  Future<void> delete(String fileId) async {
    final file = _fileFor(fileId);
    if (await file.exists()) {
      await file.delete();
    }
  }
}
