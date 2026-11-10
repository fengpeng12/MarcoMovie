import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:marco_movie/core/python_http_transport.dart';

void main() {
  late HttpServer server;
  late Uri base;
  final requests = <String>[];
  var sequence = 0;

  String identity() => (++sequence).toRadixString(16).padLeft(32, '0');

  Map<String, Object?> envelope(
    String callId,
    String path, {
    int total = 1000,
    int read = 1000,
    Uint8List? body,
    String method = 'GET',
  }) => {
    'version': 1,
    'callId': callId,
    'requestId': identity(),
    'url': base.resolve(path).toString(),
    'method': method,
    'headers': <List<String>>[],
    'body': body ?? Uint8List(0),
    'connectTimeoutMs': total,
    'readTimeoutMs': read,
    'deadlineRemainingMs': total,
  };

  setUp(() async {
    requests.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}/');
    server.listen((request) async {
      requests.add(request.uri.path);
      try {
        final body = await request.fold<List<int>>(
          [],
          (bytes, chunk) => bytes..addAll(chunk),
        );
        if (request.uri.path == '/slow') {
          await Future<void>.delayed(const Duration(milliseconds: 400));
        } else if (request.uri.path == '/redirect') {
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set('Location', '$base/destination');
        } else if (request.uri.path == '/cookies') {
          request.response.headers.add(
            'Set-Cookie',
            'first=one; Expires=Wed, 09 Jun 2099 10:18:14 GMT; Path=/',
          );
          request.response.headers.add('Set-Cookie', 'second=two; Path=/');
        } else if (request.uri.path == '/gzip') {
          request.response.headers.set('Content-Encoding', 'gzip');
          request.response.add(gzip.encode([0, 255, 128, 65]));
          await request.response.close();
          return;
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'method': request.method,
            'body': base64Encode(body),
            'cookie': request.headers.value('cookie'),
          }),
        );
        await request.response.close();
      } on HttpException {
        // Intentional timeout/cancellation disconnects the slow client.
      } on SocketException {
        // Intentional timeout/cancellation disconnects the slow client.
      }
    });
  });

  tearDown(() async => server.close(force: true));

  test(
    'native Python operation sends original bytes and preserves cookie pairs',
    () async {
      final id = identity();
      final transport = PythonHttpTransport(
        callId: id,
        budget: const Duration(seconds: 3),
      );
      addTearDown(transport.close);
      final binary = Uint8List.fromList([0, 255, 128, 13, 10, 65]);
      final response = await transport.request(
        envelope(id, '/echo', body: binary, method: 'POST'),
      );
      final value = jsonDecode(utf8.decode(response['body'] as Uint8List));
      expect(base64Decode(value['body'] as String), binary);
      expect(value['method'], 'POST');
      final cookies = await transport.request(envelope(id, '/cookies'));
      final pairs = (cookies['headers'] as List)
          .where((pair) => pair[0] == 'set-cookie')
          .toList();
      expect(pairs.length, 2);
      expect(pairs[0][1], contains('Expires=Wed, 09 Jun 2099 10:18:14 GMT'));
      final echo = await transport.request(envelope(id, '/echo'));
      expect(
        jsonDecode(utf8.decode(echo['body'] as Uint8List))['cookie'],
        isNull,
      );
    },
  );

  test(
    'native Python transport leaves redirect and decompression to requests',
    () async {
      final id = identity();
      final transport = PythonHttpTransport(
        callId: id,
        budget: const Duration(seconds: 3),
      );
      addTearDown(transport.close);
      final response = await transport.request(envelope(id, '/redirect'));
      expect(response['status'], 302);
      expect(requests, ['/redirect']);
      final encoded = await transport.request(envelope(id, '/gzip'));
      expect(encoded['body'], gzip.encode([0, 255, 128, 65]));
    },
  );

  test('operation budget begins before the first HTTP request', () async {
    final id = identity();
    final transport = PythonHttpTransport(
      callId: id,
      budget: const Duration(milliseconds: 40),
    );
    addTearDown(transport.close);
    await Future<void>.delayed(const Duration(milliseconds: 70));
    await expectLater(
      transport.request(envelope(id, '/echo')),
      throwsA(
        isA<PythonTransportException>().having(
          (e) => e.kind,
          'kind',
          'timeout',
        ),
      ),
    );
    expect(requests, isEmpty);
  });

  test(
    'cancelled operation does not close a different operation or future work',
    () async {
      final firstId = identity(), secondId = identity();
      final first = PythonHttpTransport(
        callId: firstId,
        budget: const Duration(seconds: 2),
      );
      final second = PythonHttpTransport(
        callId: secondId,
        budget: const Duration(seconds: 2),
      );
      addTearDown(first.close);
      addTearDown(second.close);
      final failed = expectLater(
        first.request(envelope(firstId, '/slow')),
        throwsA(
          isA<PythonTransportException>().having(
            (e) => e.kind,
            'kind',
            'cancelled',
          ),
        ),
      );
      final success = second.request(envelope(secondId, '/echo'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      first.cancel(firstId);
      await failed;
      expect((await success)['status'], 200);
      expect(first.activeRequestCount, 0);
      expect(
        (await second.request(envelope(secondId, '/echo')))['status'],
        200,
      );
    },
  );

  test(
    'wrong operation identity and closed transports cannot issue requests',
    () async {
      final id = identity();
      final transport = PythonHttpTransport(
        callId: id,
        budget: const Duration(seconds: 2),
      );
      await expectLater(
        transport.request(envelope(identity(), '/echo')),
        throwsFormatException,
      );
      expect(() => transport.cancel(identity()), throwsFormatException);
      transport.close();
      await expectLater(
        transport.request(envelope(id, '/echo')),
        throwsA(isA<PythonTransportException>()),
      );
      expect(requests, isEmpty);
    },
  );

  test('optional origin policy rejects before opening a socket', () async {
    final id = identity();
    final transport = PythonHttpTransport(
      callId: id,
      budget: const Duration(seconds: 2),
      allowUrl: (uri) => uri.origin == base.origin && uri.path == '/echo',
    );
    addTearDown(transport.close);
    await expectLater(
      transport.request(envelope(id, '/cookies')),
      throwsFormatException,
    );
    expect(requests, isEmpty);
    expect((await transport.request(envelope(id, '/echo')))['status'], 200);
  });

  test('new operations are independent of earlier lifetime caps', () async {
    // A source may live for far more than the old fixture's 64-call lifetime.
    for (var index = 0; index < 70; index++) {
      final id = identity();
      final transport = PythonHttpTransport(
        callId: id,
        budget: const Duration(seconds: 2),
      );
      try {
        expect((await transport.request(envelope(id, '/echo')))['status'], 200);
      } finally {
        transport.close();
      }
    }
    expect(requests.length, 70);
  });

  test(
    'duplicate request IDs and mutable body aliasing are prevented',
    () async {
      final id = identity();
      final transport = PythonHttpTransport(
        callId: id,
        budget: const Duration(seconds: 2),
      );
      addTearDown(transport.close);
      final body = Uint8List.fromList([1, 2, 3]);
      final request = envelope(id, '/echo', body: body, method: 'POST');
      final first = transport.request(request);
      body[0] = 9;
      final response = await first;
      expect(
        base64Decode(
          jsonDecode(utf8.decode(response['body'] as Uint8List))['body'],
        ),
        [1, 2, 3],
      );
      await expectLater(transport.request(request), throwsFormatException);
      expect(requests.length, 1);
    },
  );
}
