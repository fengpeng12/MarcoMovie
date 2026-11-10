import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/script_proxy_server.dart';

ScriptProxyResponse bytes(
  List<int> body, {
  int status = 200,
  String type = 'application/octet-stream',
  Map<String, String> headers = const {},
}) => ScriptProxyResponse(
  statusCode: status,
  contentType: type,
  body: Uint8List.fromList(body),
  headers: headers,
);

Future<({int status, Map<String, String> headers, List<int> body})> fetch(
  Uri url, {
  String method = 'GET',
  Map<String, String> headers = const {},
  List<int>? body,
}) async {
  final client = HttpClient()..autoUncompress = false;
  try {
    final request = await client.openUrl(method, url);
    request.followRedirects = false;
    headers.forEach(request.headers.set);
    if (body != null) {
      request.contentLength = body.length;
      request.add(body);
    }
    final response = await request.close();
    final output = <int>[];
    await for (final chunk in response) {
      output.addAll(chunk);
    }
    final fields = <String, String>{};
    response.headers.forEach(
      (name, values) => fields[name] = values.join(', '),
    );
    return (status: response.statusCode, headers: fields, body: output);
  } finally {
    client.close(force: true);
  }
}

void main() {
  test(
    'HEAD preserves upstream representation length without a body',
    () async {
      final server = ScriptProxyServer();
      addTearDown(server.close);
      final full = await server.register(
        (request) async => bytes([], headers: {'Content-Length': '1000'}),
      );
      final head = await fetch(full.url, method: 'HEAD');
      expect(head.status, 200);
      expect(head.headers['content-length'], '1000');
      expect(head.body, isEmpty);
      final range = await fetch(
        full.url,
        method: 'HEAD',
        headers: {'Range': 'bytes=100-199'},
      );
      expect(range.status, 206);
      expect(range.headers['content-length'], '100');
      expect(range.headers['content-range'], 'bytes 100-199/1000');
      final partial = await server.register(
        (request) async => bytes(
          [],
          status: 206,
          headers: {
            'Content-Range': 'bytes 100-199/1000',
            'Content-Length': '100',
          },
        ),
      );
      expect(
        (await fetch(partial.url, method: 'HEAD')).headers['content-length'],
        '100',
      );
    },
  );

  test(
    'If-Range requires a matching strong validator before local slicing',
    () async {
      final server = ScriptProxyServer();
      addTearDown(server.close);
      final source = await server.register(
        (request) async => bytes([1, 2, 3], headers: {'ETag': '"fixture"'}),
      );
      final stale = await fetch(
        source.url,
        headers: {'Range': 'bytes=0-0', 'If-Range': '"old"'},
      );
      expect(stale.status, 200);
      expect(stale.body, [1, 2, 3]);
      expect(
        (await fetch(
          source.url,
          headers: {'Range': 'bytes=0-0', 'If-Range': '"fixture"'},
        )).status,
        206,
      );
    },
  );

  test('oversized request headers and URI never invoke the source', () async {
    final server = ScriptProxyServer();
    addTearDown(server.close);
    var calls = 0;
    final source = await server.register((request) async {
      calls++;
      return bytes([]);
    });
    final headers = {for (var i = 0; i < 65; i++) 'X-Fixture-$i': 'v'};
    expect((await fetch(source.url, headers: headers)).status, 431);
    expect(
      (await fetch(source.url.replace(query: 'value=${'x' * 8192}'))).status,
      400,
    );
    expect(calls, 0);
  });

  test(
    'one loopback listener isolates tokens, paths, query values and callbacks',
    () async {
      final server = ScriptProxyServer();
      addTearDown(server.close);
      final requests = <ScriptProxyRequest>[];
      final first = await server.register((request) async {
        requests.add(request);
        return bytes([1]);
      });
      final second = await server.register((_) async => bytes([2]));
      expect(first.url.host, '127.0.0.1');
      expect(first.url.port, second.url.port);
      expect(first.url.path, isNot(second.url.path));
      expect(first.url.pathSegments[1].length, 43);
      final nested = first.url.resolve('nested/part.ts?url=a&url=b&blank=');
      expect(
        (await fetch(
          nested,
          headers: {'Range': 'bytes=0-', 'X-Player': 'fixture'},
        )).body,
        [1],
      );
      expect(requests.single.path, '/nested/part.ts');
      expect(requests.single.queryParametersAll, {
        'url': ['a', 'b'],
        'blank': [''],
      });
      expect(requests.single.headers['range'], 'bytes=0-');
      expect(requests.single.headers['x-player'], 'fixture');
      expect(requests.single.headers.containsKey('host'), isFalse);
      expect((await fetch(second.url)).body, [2]);
      expect(
        (await fetch(first.url.replace(path: '/_spider/unknown/proxy'))).status,
        404,
      );
    },
  );

  test(
    'binary, single ranges, suffix ranges, HEAD and unsatisfiable ranges',
    () async {
      final server = ScriptProxyServer();
      addTearDown(server.close);
      final source = await server.register(
        (_) async => bytes([0, 127, 128, 255]),
      );
      expect((await fetch(source.url)).body, [0, 127, 128, 255]);
      final part = await fetch(source.url, headers: {'Range': 'bytes=1-2'});
      expect(part.status, 206);
      expect(part.body, [127, 128]);
      expect(part.headers['content-range'], 'bytes 1-2/4');
      expect(part.headers['content-length'], '2');
      expect((await fetch(source.url, headers: {'Range': 'bytes=-2'})).body, [
        128,
        255,
      ]);
      expect((await fetch(source.url, headers: {'Range': 'bytes=2-99'})).body, [
        128,
        255,
      ]);
      for (final range in [
        'bytes=4-',
        'bytes=-0',
        'bytes=2-1',
        'bytes=0-1,2-3',
        'bytes=-',
      ]) {
        final invalid = await fetch(source.url, headers: {'Range': range});
        expect(invalid.status, 416, reason: range);
        expect(invalid.headers['content-range'], 'bytes */4');
        expect(invalid.body, isEmpty);
      }
      final head = await fetch(
        source.url,
        method: 'HEAD',
        headers: {'Range': 'bytes=1-2'},
      );
      expect(head.status, 206);
      expect(head.body, isEmpty);
      expect(head.headers['content-length'], '2');
    },
  );

  test('explicit source partial responses are not sliced again', () async {
    final server = ScriptProxyServer();
    addTearDown(server.close);
    final source = await server.register((request) async {
      expect(request.headers['range'], 'bytes=100-102');
      return bytes(
        [128, 0, 255],
        status: 206,
        headers: {
          'Content-Range': 'bytes 100-102/1000',
          'X-Upstream': 'fixture',
        },
      );
    });
    final result = await fetch(source.url, headers: {'Range': 'bytes=100-102'});
    expect(result.status, 206);
    expect(result.body, [128, 0, 255]);
    expect(result.headers['content-range'], 'bytes 100-102/1000');
    expect(result.headers['x-upstream'], 'fixture');
  });

  test(
    'HLS stays unchanged and nested relative URLs retain the source token',
    () async {
      final server = ScriptProxyServer();
      addTearDown(server.close);
      const playlist =
          '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="keys/key.bin"\nsegments/one.ts\n';
      final paths = <String>[];
      final source = await server.register((request) async {
        paths.add(request.path);
        return request.path.endsWith('one.ts')
            ? bytes([4, 5])
            : bytes(
                utf8.encode(playlist),
                type: 'application/vnd.apple.mpegurl',
              );
      });
      final response = await fetch(source.url, headers: {'Range': 'bytes=0-2'});
      expect(response.status, 200);
      expect(utf8.decode(response.body), playlist);
      expect(response.headers['accept-ranges'], 'none');
      expect((await fetch(source.url.resolve('segments/one.ts'))).body, [4, 5]);
      expect(paths, ['/proxy', '/segments/one.ts']);
      expect((await fetch(source.url.resolve('../escape.ts'))).status, 404);
      expect((await fetch(source.url.resolve('/root.ts'))).status, 404);
    },
  );

  test(
    'rejects non-GET/HEAD, browser origins, foreign Host, body and path escape',
    () async {
      final server = ScriptProxyServer();
      addTearDown(server.close);
      var calls = 0;
      final source = await server.register((_) async {
        calls++;
        return bytes([1]);
      });
      expect((await fetch(source.url, method: 'POST')).status, 405);
      expect(
        (await fetch(
          source.url,
          headers: {'Origin': 'https://example.test'},
        )).status,
        403,
      );
      expect(
        (await fetch(source.url, headers: {'Host': 'example.test'})).status,
        403,
      );
      expect((await fetch(source.url, body: [1])).status, 413);
      for (final suffix in [
        '%2e%2e/escape',
        'folder%2fescape',
        'folder%5cescape',
        '%252e%252e/escape',
      ]) {
        final target = Uri.parse(
          '${source.url.resolve('.').toString()}$suffix',
        );
        expect((await fetch(target)).status, 404, reason: suffix);
      }
      expect(calls, 0);
    },
  );

  test(
    'unregister cancels in-flight work and cannot resurrect a stale response',
    () async {
      final server = ScriptProxyServer();
      addTearDown(server.close);
      final started = Completer<ScriptProxyRequest>();
      final finish = Completer<ScriptProxyResponse>();
      final source = await server.register((request) {
        started.complete(request);
        return finish.future;
      });
      final pending = fetch(source.url);
      final request = await started.future;
      final closed = source.unregister();
      expect(source.isActive, isFalse);
      expect(request.cancellation.isCompleted, isTrue);
      expect((await pending).status, 410);
      await closed;
      await source.closed;
      finish.complete(bytes([9]));
      expect((await fetch(source.url)).status, 404);
      await source.close();
    },
  );

  test('bounded timeout cancels callback and returns 504', () async {
    final server = ScriptProxyServer(
      requestTimeout: const Duration(milliseconds: 80),
    );
    addTearDown(server.close);
    final started = Completer<ScriptProxyRequest>();
    final source = await server.register((request) {
      started.complete(request);
      return Completer<ScriptProxyResponse>().future;
    });
    expect((await fetch(source.url)).status, 504);
    expect((await started.future).cancellation.isCompleted, isTrue);
    await source.close();
  });

  test(
    'per-source admission is bounded and a different source remains usable',
    () async {
      final server = ScriptProxyServer();
      addTearDown(server.close);
      final started = Completer<void>();
      var calls = 0;
      final source = await server.register((request) {
        if (++calls == 4) started.complete();
        return Completer<ScriptProxyResponse>().future;
      });
      final pending = List.generate(4, (_) => fetch(source.url));
      await started.future;
      expect((await fetch(source.url)).status, 429);
      final other = await server.register((_) async => bytes([7]));
      expect((await fetch(other.url)).body, [7]);
      await source.close();
      expect(
        (await Future.wait(pending)).every((value) => value.status == 410),
        isTrue,
      );
    },
  );

  test('strips hop headers, source cookies and stale Content-Length', () async {
    final server = ScriptProxyServer();
    addTearDown(server.close);
    final source = await server.register(
      (_) async => bytes(
        [1, 2],
        headers: {
          'Content-Length': '9999',
          'Transfer-Encoding': 'chunked',
          'Connection': 'X-Hop',
          'X-Hop': 'secret',
          'Set-Cookie': 'shared=bad',
          'X-Media': 'kept',
        },
      ),
    );
    final result = await fetch(source.url);
    expect(result.status, 200);
    expect(result.headers['content-length'], '2');
    expect(result.headers['x-media'], 'kept');
    for (final name in ['transfer-encoding', 'x-hop', 'set-cookie']) {
      expect(result.headers.containsKey(name), isFalse);
    }
  });

  test(
    'invalid responses and excessive response bytes fail before being sent',
    () async {
      final server = ScriptProxyServer();
      addTearDown(server.close);
      for (final response in [
        bytes([1], headers: {'X-Injected': 'ok\r\nBad: value'}),
        bytes([1], type: 'text/plain\r\nBad: value'),
        bytes([1], status: 206, headers: {'Content-Range': 'bytes 0-9/10'}),
        bytes(Uint8List(ScriptProxyServer.maxResponseBytes + 1)),
      ]) {
        final source = await server.register((_) async => response);
        final result = await fetch(source.url);
        expect(result.status, 502);
        expect(result.body, isEmpty);
        await source.close();
      }
    },
  );

  test('player socket disconnect cancels its source operation', () async {
    final server = ScriptProxyServer(
      requestTimeout: const Duration(seconds: 3),
    );
    addTearDown(server.close);
    final started = Completer<ScriptProxyRequest>();
    final source = await server.register((request) {
      started.complete(request);
      return Completer<ScriptProxyResponse>().future;
    });
    final socket = await Socket.connect('127.0.0.1', source.url.port);
    socket.write(
      'GET ${source.url.path} HTTP/1.1\r\nHost: 127.0.0.1:${source.url.port}\r\nConnection: close\r\n\r\n',
    );
    await socket.flush();
    final request = await started.future;
    socket.destroy();
    await request.cancellation.future.timeout(const Duration(seconds: 1));
  });

  test(
    'server close revokes every source and prevents new registration',
    () async {
      final server = ScriptProxyServer();
      final first = await server.register((_) async => bytes([]));
      final second = await server.register((_) async => bytes([]));
      await server.close();
      expect(first.isActive, isFalse);
      expect(second.isActive, isFalse);
      await first.closed;
      await second.closed;
      await expectLater(
        server.register((_) async => bytes([])),
        throwsStateError,
      );
      await server.close();
    },
  );
}
