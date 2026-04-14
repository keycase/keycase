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

  final server = await startServer(
    database: db,
    fileStore: fileStore,
    host: config.host,
    port: config.port,
  );
  stdout.writeln(
      'KeyCase server listening on http://${config.host}:${server.port}');

  // Graceful shutdown on SIGINT/SIGTERM.
  Future<void> shutdown(ProcessSignal sig) async {
    stdout.writeln('received ${sig.toString()}, shutting down...');
    await server.close(force: false);
    await db.close();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  ProcessSignal.sigterm.watch().listen(shutdown);
}
