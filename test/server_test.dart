import 'dart:convert';
import 'dart:io';

import 'package:keycase_core/keycase_core.dart';
import 'package:keycase_server/db/database.dart';
import 'package:keycase_server/server.dart';
import 'package:keycase_server/verification.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// Integration tests hit a real Postgres. Point [TEST_DATABASE_URL] at a
/// database you're willing to `DROP TABLE` inside — the whole schema is
/// wiped between runs. The suite is skipped when the env var is unset so
/// `dart test` still works on contributor laptops without a local pg.
const _envKey = 'TEST_DATABASE_URL';

Future<Response> _call(Handler h, Request r) => Future.sync(() => h(r));

Request _req(
  String method,
  String path, {
  Object? body,
  Map<String, String>? headers,
}) {
  final bodyStr = body is String
      ? body
      : body == null
          ? ''
          : jsonEncode(body);
  return Request(
    method,
    Uri.parse('http://test.local$path'),
    body: bodyStr,
    headers: {
      if (bodyStr.isNotEmpty) 'content-type': 'application/json',
      ...?headers,
    },
  );
}

Future<Map<String, dynamic>> _json(Response r) async {
  final body = await r.readAsString();
  return jsonDecode(body) as Map<String, dynamic>;
}

/// Build an `Authorization: KeyCase user:sig` header for [bodyJson].
Future<Map<String, String>> _authHeader(
  String username,
  String privateKey,
  Object? bodyJson,
) async {
  final body = bodyJson == null ? '' : jsonEncode(bodyJson);
  final sig = await sign(body, privateKey);
  return {'Authorization': 'KeyCase $username:$sig'};
}

void main() {
  final testUrl = Platform.environment[_envKey];
  if (testUrl == null || testUrl.isEmpty) {
    test('integration tests skipped ($_envKey not set)', () {}, skip: true);
    return;
  }

  late Database db;
  late Handler handler;

  setUpAll(() async {
    db = await Database.open(testUrl);
    // Fresh schema for each run.
    await db.connection.execute(
      'DROP TABLE IF EXISTS key_signatures, proofs, identities CASCADE',
    );
    await db.runMigrations('db/migrations');
    handler = buildHandler(
      database: db,
      verifiers: ProofVerifiers(),
    );
  });

  tearDownAll(() async {
    await db.close();
  });

  setUp(() async {
    await db.connection.execute('TRUNCATE key_signatures, proofs, identities');
  });

  Future<({KeyPair kp, Map<String, dynamic> body})> register(
      String username) async {
    final kp = await generateKeyPair();
    final sig = await sign(username, kp.privateKey!);
    final resp = await _call(
      handler,
      _req('POST', '/api/v1/identity', body: {
        'username': username,
        'publicKey': kp.publicKey,
        'signature': sig,
      }),
    );
    expect(resp.statusCode, 201);
    return (kp: kp, body: await _json(resp));
  }

  group('identity', () {
    test('registration happy path', () async {
      final r = await register('alice');
      expect(r.body['username'], 'alice');
      expect(r.body['publicKey'], r.kp.publicKey);
    });

    test('registration rejects invalid username', () async {
      final kp = await generateKeyPair();
      final sig = await sign('BadName!', kp.privateKey!);
      final resp = await _call(
        handler,
        _req('POST', '/api/v1/identity', body: {
          'username': 'BadName!',
          'publicKey': kp.publicKey,
          'signature': sig,
        }),
      );
      expect(resp.statusCode, 400);
    });

    test('duplicate registration rejected', () async {
      await register('bob');
      final kp = await generateKeyPair();
      final sig = await sign('bob', kp.privateKey!);
      final resp = await _call(
        handler,
        _req('POST', '/api/v1/identity', body: {
          'username': 'bob',
          'publicKey': kp.publicKey,
          'signature': sig,
        }),
      );
      expect(resp.statusCode, 409);
    });

    test('lookup returns identity', () async {
      await register('carol');
      final resp = await _call(handler, _req('GET', '/api/v1/identity/carol'));
      expect(resp.statusCode, 200);
      final body = await _json(resp);
      expect(body['username'], 'carol');
    });

    test('lookup 404 on missing', () async {
      final resp = await _call(handler, _req('GET', '/api/v1/identity/nope'));
      expect(resp.statusCode, 404);
    });

    test('search by prefix', () async {
      await register('dave');
      await register('daveo');
      await register('eve');
      final resp =
          await _call(handler, _req('GET', '/api/v1/identity?q=dav'));
      expect(resp.statusCode, 200);
      final body = await _json(resp);
      final names = [
        for (final r in body['results'] as List) (r as Map)['username'],
      ];
      expect(names, containsAll(['dave', 'daveo']));
      expect(names, isNot(contains('eve')));
    });
  });

  group('auth', () {
    test('mutation without auth rejected', () async {
      await register('faye');
      final resp = await _call(
        handler,
        _req('POST', '/api/v1/proof', body: {
          'identityUsername': 'faye',
          'type': 'url',
          'target': 'https://example.com',
          'signature': 'x',
        }),
      );
      expect(resp.statusCode, 401);
    });

    test('mutation with bad signature rejected', () async {
      await register('gina');
      final body = {
        'identityUsername': 'gina',
        'type': 'url',
        'target': 'https://example.com',
        'signature': 'x',
      };
      final resp = await _call(
        handler,
        _req('POST', '/api/v1/proof',
            body: body,
            headers: {'Authorization': 'KeyCase gina:not-a-signature'}),
      );
      expect(resp.statusCode, 401);
    });
  });

  group('proof', () {
    test('key-signing proof via direct submit', () async {
      // A signs B's public key; B submits that as a keySigning proof.
      final a = await register('hank');
      final b = await register('iris');
      final sig = await KeySigningVerifier.sign(
        targetPublicKey: b.kp.publicKey,
        signerPrivateKey: a.kp.privateKey!,
      );
      final body = {
        'identityUsername': 'iris',
        'type': 'keySigning',
        'target': 'hank',
        'signature': sig,
      };
      final resp = await _call(
        handler,
        _req('POST', '/api/v1/proof',
            body: body,
            headers: await _authHeader('iris', b.kp.privateKey!, body)),
      );
      expect(resp.statusCode, 201);
      final proof = await _json(resp);
      expect(proof['status'], 'verified');
      expect(proof['type'], 'keySigning');
    });

    test('proof re-verification', () async {
      final a = await register('jack');
      final b = await register('kate');
      final sig = await KeySigningVerifier.sign(
        targetPublicKey: b.kp.publicKey,
        signerPrivateKey: a.kp.privateKey!,
      );
      final submitBody = {
        'identityUsername': 'kate',
        'type': 'keySigning',
        'target': 'jack',
        'signature': sig,
      };
      final submit = await _call(
        handler,
        _req('POST', '/api/v1/proof',
            body: submitBody,
            headers: await _authHeader('kate', b.kp.privateKey!, submitBody)),
      );
      final proof = await _json(submit);
      final id = proof['id'] as String;

      final reVerify = await _call(
        handler,
        _req('POST', '/api/v1/proof/$id/verify',
            headers: await _authHeader('kate', b.kp.privateKey!, null)),
      );
      expect(reVerify.statusCode, 200);
      final rv = await _json(reVerify);
      expect(rv['status'], 'verified');
    });
  });

  group('key signing endpoint', () {
    test('happy path', () async {
      final a = await register('leo');
      final b = await register('mary');
      final sig = await KeySigningVerifier.sign(
        targetPublicKey: b.kp.publicKey,
        signerPrivateKey: a.kp.privateKey!,
      );
      final body = {'signerUsername': 'leo', 'signature': sig};
      final resp = await _call(
        handler,
        _req('POST', '/api/v1/identity/mary/sign',
            body: body,
            headers: await _authHeader('leo', a.kp.privateKey!, body)),
      );
      expect(resp.statusCode, 201);
      final proof = await _json(resp);
      expect(proof['type'], 'keySigning');
      expect(proof['status'], 'verified');

      final proofs =
          await _call(handler, _req('GET', '/api/v1/identity/mary/proofs'));
      final plist =
          (await _json(proofs))['proofs'] as List;
      expect(plist, hasLength(1));
    });

    test('bad signature rejected', () async {
      final a = await register('neo');
      await register('oona');
      final body = {'signerUsername': 'neo', 'signature': 'bogus'};
      final resp = await _call(
        handler,
        _req('POST', '/api/v1/identity/oona/sign',
            body: body,
            headers: await _authHeader('neo', a.kp.privateKey!, body)),
      );
      expect(resp.statusCode, 400);
    });
  });
}
