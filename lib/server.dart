import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'routes/identity_routes.dart';
import 'routes/proof_routes.dart';
import 'routes/health_routes.dart';

/// Start the KeyCase server.
Future<HttpServer> startServer({String host = 'localhost', int port = 8080}) async {
  final app = Router();

  // Health check
  mountHealthRoutes(app);

  // Identity endpoints
  mountIdentityRoutes(app);

  // Proof endpoints
  mountProofRoutes(app);

  final handler = const Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(_corsMiddleware())
      .addHandler(app.call);

  return shelf_io.serve(handler, host, port);
}

/// CORS middleware for cross-origin requests.
Middleware _corsMiddleware() {
  return (Handler handler) {
    return (Request request) async {
      if (request.method == 'OPTIONS') {
        return Response.ok('', headers: _corsHeaders);
      }
      final response = await handler(request);
      return response.change(headers: _corsHeaders);
    };
  };
}

const _corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
  'Access-Control-Allow-Headers': 'Origin, Content-Type, Authorization',
};
