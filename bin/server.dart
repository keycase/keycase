import 'dart:io';
import 'package:args/args.dart';
import 'package:keycase_server/server.dart';

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('port', abbr: 'p', defaultsTo: '8080', help: 'Port to listen on')
    ..addOption('host', abbr: 'h', defaultsTo: 'localhost', help: 'Host to bind to')
    ..addFlag('help', negatable: false, help: 'Show usage information');

  final results = parser.parse(args);

  if (results['help'] as bool) {
    print('KeyCase Server');
    print('');
    print('Usage: keycase [options]');
    print('');
    print(parser.usage);
    exit(0);
  }

  final port = int.parse(results['port'] as String);
  final host = results['host'] as String;

  final server = await startServer(host: host, port: port);
  print('KeyCase server listening on http://$host:$port');
}
