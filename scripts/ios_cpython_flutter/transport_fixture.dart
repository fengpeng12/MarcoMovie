// Owned loopback fixture for the disposable CPython/Flutter app only.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

import 'fixture_http_transport.dart';

class PythonTransportFixture {
  PythonTransportFixture._(this.servers, this.origins)
    : transport = FixtureHttpTransport(allowedOrigins: origins);

  final List<HttpServer> servers;
  final List<Uri> origins;
  final FixtureHttpTransport transport;
  int cancellationRequests = 0;
  int nativeCancellations = 0;
  int requestCount = 0;
  final List<String> failures = [];
  bool _closed = false;

  static Future<PythonTransportFixture> start() async {
    final first = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    HttpServer? second;
    try {
      second = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final random = Random.secure();
      String token() => List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      final servers = [first, second];
      final origins = [
        for (final server in servers)
          Uri.parse('http://127.0.0.1:${server.port}/${token()}'),
      ];
      final fixture = PythonTransportFixture._(servers, origins);
      for (var index = 0; index < servers.length; index++) {
        final originIndex = index;
        servers[index].listen(
          (request) => unawaited(fixture._serve(request, originIndex)),
          onError: (_) => fixture.failures.add('Owned server failed'),
        );
      }
      return fixture;
    } catch (_) {
      await first.close(force: true);
      await second?.close(force: true);
      rethrow;
    }
  }

  Future<void> _serve(HttpRequest request, int index) async {
    final response = request.response;
    try {
      final prefix = '${origins[index].path}/';
      if (!request.uri.path.startsWith(prefix)) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      final route = request.uri.path.substring(prefix.length);
      final body = <int>[];
      await for (final part in request) {
        body.addAll(part);
        if (body.length > 1024 * 1024) {
          throw StateError('Owned fixture body too large');
        }
      }
      final headers = <String, String>{};
      request.headers.forEach((name, values) {
        headers[name.toLowerCase()] = values.join(', ');
      });
      response.headers.contentType = ContentType.json;
      if (route == 'slow') {
        await Future<void>.delayed(const Duration(milliseconds: 800));
      } else if (route == 'binary') {
        if (request.method != 'GET' || headers['range'] != 'bytes=0-5') {
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          await response.close();
          return;
        }
        response.statusCode = HttpStatus.partialContent;
        response.headers.contentType = ContentType.binary;
        response.headers.set('Content-Range', 'bytes 0-5/6');
        response.headers.set('X-Fixture', 'bytes');
        response.add([0, 255, 128, 13, 10, 65]);
        await response.close();
        return;
      } else if (route == 'seed') {
        for (final cookie in [
          'root=one; Path=$prefix',
          'only=path; Path=${prefix}scope',
          'secure_only=secret; Secure; Path=$prefix',
          'expires_cookie=yes; Expires=Wed, 09 Jun 2099 10:18:14 GMT; Path=$prefix',
        ]) {
          response.headers.add(HttpHeaders.setCookieHeader, cookie);
        }
      } else if (route == 'cross') {
        response.statusCode = HttpStatus.found;
        response.headers.set('Location', '${origins[1]}/b-login');
      } else if (route == 'b-login' && index == 1) {
        response.statusCode = HttpStatus.found;
        response.headers.add(
          HttpHeaders.setCookieHeader,
          'own_b=two; Path=$prefix',
        );
        response.headers.set('Location', '${origins[1]}/echo');
      } else if (route != 'echo' && route != 'scope/echo') {
        response.statusCode = HttpStatus.notFound;
      }
      response.write(
        jsonEncode({
          'method': request.method,
          'body': base64Encode(body),
          'headers': headers,
          'path': request.uri.toString(),
        }),
      );
      await response.close();
    } on HttpException {
      // The deliberate slow-request cancellation closes its socket.
    } on SocketException {
      // The deliberate slow-request cancellation closes its socket.
    } catch (error) {
      failures.add('Owned handler: ${error.runtimeType}');
      try {
        await response.close();
      } catch (_) {}
    }
  }

  Future<Object?> handle(MethodCall call, MethodChannel channel) async {
    if (_closed) {
      throw PlatformException(code: 'cancelled');
    }
    if (call.method == 'transport.cancel') {
      final args = Map<String, Object?>.from(call.arguments as Map);
      if (args.length != 2 ||
          args['version'] != 1 ||
          args['callId'] is! String) {
        throw PlatformException(code: 'protocol');
      }
      transport.cancel(args['callId'] as String);
      return <String, Object?>{'cancelled': true};
    }
    if (call.method != 'transport.request') {
      throw MissingPluginException('Unknown owned transport method');
    }
    final envelope = Map<String, Object?>.from(call.arguments as Map);
    requestCount++;
    Timer? cancelTimer;
    if (envelope['callId'] == 'cccccccccccccccccccccccccccccccc' &&
        Uri.parse(envelope['url'] as String).path.endsWith('/slow')) {
      cancelTimer = Timer(const Duration(milliseconds: 30), () async {
        cancellationRequests++;
        try {
          final result = await channel
              .invokeMapMethod<String, dynamic>('cancelTransport', {
                'version': 1,
                'callId': envelope['callId'],
              })
              .timeout(const Duration(seconds: 2));
          nativeCancellations += (result?['cancelled'] as num?)?.toInt() ?? 0;
        } catch (_) {
          failures.add('Native cancellation acknowledgment missing');
        }
      });
    }
    try {
      return await transport.request(envelope);
    } on FixtureTransportException catch (error) {
      throw PlatformException(code: error.kind);
    } on FormatException {
      throw PlatformException(code: 'protocol');
    } finally {
      cancelTimer?.cancel();
    }
  }

  Future<void> close() async {
    _closed = true;
    transport.close();
    for (final server in servers) {
      await server.close(force: true);
    }
  }
}
