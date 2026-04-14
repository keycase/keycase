import 'dart:io';

import 'package:dotenv/dotenv.dart';

/// Runtime configuration for the KeyCase server.
class ServerConfig {
  final String databaseUrl;
  final String host;
  final int port;
  final String migrationsDir;

  const ServerConfig({
    required this.databaseUrl,
    required this.host,
    required this.port,
    required this.migrationsDir,
  });

  /// Load from a `.env` file in the working directory (if present) plus
  /// the process environment. Process env takes precedence. Throws if
  /// [DATABASE_URL] is missing.
  factory ServerConfig.load({Map<String, String>? overrides}) {
    final env = DotEnv(includePlatformEnvironment: true);
    if (File('.env').existsSync()) {
      env.load(['.env']);
    }
    String? read(String key) => overrides?[key] ?? env[key];

    final url = read('DATABASE_URL');
    if (url == null || url.isEmpty) {
      throw StateError('DATABASE_URL is required (set in .env or environment)');
    }
    return ServerConfig(
      databaseUrl: url,
      host: read('HOST') ?? 'localhost',
      port: int.parse(read('PORT') ?? '8080'),
      migrationsDir: read('MIGRATIONS_DIR') ?? 'db/migrations',
    );
  }
}
