import 'dart:io';

import 'package:args/args.dart';
import 'package:keycase_server/config.dart';
import 'package:keycase_server/db/database.dart';
import 'package:keycase_server/server.dart';
import 'package:keycase_server/storage/file_store.dart';

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('port', abbr: 'p', help: 'Port to listen on (overrides PORT)')
    ..addOption('host', abbr: 'h', help: 'Host to bind to (overrides HOST)')
    ..addFlag('help', negatable: false, help: 'Show usage information');

  final results = parser.parse(args);
  if (results['help'] as bool) {
    stdout.writeln('KeyCase Server\n');
    stdout.writeln('Usage: keycase [options]\n');
    stdout.writeln(parser.usage);
    return;
  }

  final overrides = <String, String>{
    if (results['port'] != null) 'PORT': results['port'] as String,
    if (results['host'] != null) 'HOST': results['host'] as String,
  };

  final ServerConfig config;
  try {
    config = ServerConfig.load(overrides: overrides);
  } on StateError catch (e) {
    stderr.writeln('config error: ${e.message}');
    exit(2);
  }

  stdout.writeln('connecting to database...');
  final db = await Database.open(config.databaseUrl);
  stdout.writeln('running migrations from ${config.migrationsDir}...');
  await db.runMigrations(config.migrationsDir);

  await Directory(config.fileStoragePath).create(recursive: true);
  final fileStore = LocalFileStore(config.fileStoragePath);
  stdout.writeln('file storage at ${config.fileStoragePath}');

  final startTime = DateTime.now();
  final server = await startServer(
    database: db,
    fileStore: fileStore,
    host: config.host,
    port: config.port,
    startTime: startTime,
  );
  stdout.writeln(
      'KeyCase server listening on http://${config.host}:${server.port}');

  // Graceful shutdown: stop accepting new connections, wait for
  // in-flight requests (bounded by [_shutdownTimeout] so a hung
  // handler can't block forever), then close the database.
  var shuttingDown = false;
  Future<void> shutdown(ProcessSignal sig) async {
    if (shuttingDown) return;
    shuttingDown = true;
    stdout.writeln('received $sig, shutting down...');
    try {
      await server
          .close(force: false)
          .timeout(_shutdownTimeout, onTimeout: () => server.close(force: true));
    } catch (e) {
      stderr.writeln('error closing http server: $e');
    }
    try {
      await db.close();
    } catch (e) {
      stderr.writeln('error closing database: $e');
    }
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  ProcessSignal.sigterm.watch().listen(shutdown);
}

const _shutdownTimeout = Duration(seconds: 30);
