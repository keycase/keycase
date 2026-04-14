import 'package:shelf/shelf.dart';

import 'responses.dart';

/// Simple in-memory token bucket keyed by client IP. Two buckets: one
/// for reads (GET/HEAD/OPTIONS) and one for writes (everything else),
/// because writes are cheap to rate-limit aggressively without impacting
/// normal browsing.
///
/// Counters are kept per sliding one-minute window. This is not a
/// replacement for edge rate limiting — it's defense-in-depth against a
/// single badly-behaved client saturating the server.
class RateLimiter {
  final int readsPerMinute;
  final int writesPerMinute;
  final Duration window;
  final _Clock _clock;

  final Map<String, _Bucket> _reads = {};
  final Map<String, _Bucket> _writes = {};

  RateLimiter({
    this.readsPerMinute = 60,
    this.writesPerMinute = 20,
    this.window = const Duration(minutes: 1),
    DateTime Function()? now,
  }) : _clock = _Clock(now ?? DateTime.now);

  Middleware middleware() {
    return (Handler inner) {
      return (Request request) async {
        final ip = _clientIp(request);
        final isRead = _isReadMethod(request.method);
        final limit = isRead ? readsPerMinute : writesPerMinute;
        final bucket = (isRead ? _reads : _writes)
            .putIfAbsent(ip, () => _Bucket(_clock.now()));

        final now = _clock.now();
        if (now.difference(bucket.windowStart) >= window) {
          bucket.windowStart = now;
          bucket.count = 0;
        }
        bucket.count += 1;
        final remaining = limit - bucket.count;
        if (remaining < 0) {
          final retryAfter =
              window - now.difference(bucket.windowStart);
          throw HttpError(
            429,
            'rate limit exceeded',
            code: 'RATE_LIMITED',
            details: {
              'retryAfterSeconds': retryAfter.inSeconds.clamp(1, 3600),
              'limit': limit,
              'windowSeconds': window.inSeconds,
            },
          );
        }
        final response = await inner(request);
        return response.change(headers: {
          'X-RateLimit-Limit': '$limit',
          'X-RateLimit-Remaining': '${remaining < 0 ? 0 : remaining}',
        });
      };
    };
  }
}

class _Bucket {
  DateTime windowStart;
  int count = 0;
  _Bucket(this.windowStart);
}

class _Clock {
  final DateTime Function() _now;
  _Clock(this._now);
  DateTime now() => _now();
}

bool _isReadMethod(String method) {
  return method == 'GET' || method == 'HEAD' || method == 'OPTIONS';
}

String _clientIp(Request request) {
  // Honor X-Forwarded-For when running behind a trusted reverse proxy;
  // first entry is the original client per RFC 7239 convention.
  final xff = request.headers['x-forwarded-for'];
  if (xff != null && xff.isNotEmpty) {
    final first = xff.split(',').first.trim();
    if (first.isNotEmpty) return first;
  }
  final real = request.headers['x-real-ip'];
  if (real != null && real.isNotEmpty) return real.trim();
  final ctx = request.context['shelf.io.connection_info'];
  if (ctx != null) {
    // shelf_io attaches HttpConnectionInfo under this key. We only need
    // its remoteAddress.address field; use dynamic to avoid importing
    // dart:io types into this file's surface.
    try {
      final address = (ctx as dynamic).remoteAddress.address as String;
      return address;
    } catch (_) {
      // fall through
    }
  }
  return 'unknown';
}
