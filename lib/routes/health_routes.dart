import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

void mountHealthRoutes(Router app) {
  app.get('/health', (Request request) {
    return Response.ok(
      jsonEncode({'status': 'ok', 'service': 'keycase', 'version': '0.1.0'}),
      headers: {'Content-Type': 'application/json'},
    );
  });
}
