import 'dart:io';

import 'package:postgres/postgres.dart';

/// Thin wrapper around a [Connection] so repos, routes, and tests share
/// one database handle. For production workloads we'd swap this for a
/// connection pool, but the Shelf server serializes naturally onto one
/// long-lived connection and this keeps tests trivial to set up.
class Database {
  final Connection connection;

  Database(this.connection);

  /// Open a database from a `postgresql://` or `postgres://` URL.
  static Future<Database> open(String url) async {
    final conn = await Connection.openFromUrl(url);
    return Database(conn);
  }

  /// Run every `*.sql` file under [migrationsDir] in lexical order.
  /// Migrations are expected to be idempotent (IF NOT EXISTS).
  Future<void> runMigrations(String migrationsDir) async {
    final dir = Directory(migrationsDir);
    if (!await dir.exists()) return;
    final files = await dir
        .list()
        .where((e) => e is File && e.path.endsWith('.sql'))
        .cast<File>()
        .toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      final sql = await f.readAsString();
      await connection.execute(sql, queryMode: QueryMode.simple);
    }
  }

  Future<void> close() => connection.close();
}
