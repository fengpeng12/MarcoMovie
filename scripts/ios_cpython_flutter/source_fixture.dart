// Exercise the shared source loader and real product HTTP transport on iOS.
// The source itself is a bundled, app-owned package, never user input.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/services.dart';
import 'python_http_transport.dart';

class NativeSourceFixture {
  NativeSourceFixture._(this.channel, this.server, this.origin);
  final MethodChannel channel;
  final HttpServer server;
  final Uri origin;
  final handles = <String>{};
  final failures = <String>[];
  final operations = <String>{};
  PythonHttpTransport? active;
  int sequence = 0;
  int httpRequests = 0;
  int proxyCalls = 0;

  static Future<NativeSourceFixture> start(MethodChannel channel) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final random = Random.secure();
    final token = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final fixture = NativeSourceFixture._(
      channel,
      server,
      Uri.parse('http://127.0.0.1:${server.port}/$token'),
    );
    server.listen(
      (request) => unawaited(fixture.serve(request)),
      onError: (Object error) => fixture.failures.add('$error'),
    );
    return fixture;
  }

  Future<Object?> onMethod(MethodCall call) async {
    final args = Map<String, Object?>.from(call.arguments as Map);
    final transport = active;
    if (call.method == 'transport.cancel') {
      transport?.cancel(args['callId'] as String);
      return null;
    }
    if (call.method != 'transport.request' || transport == null) {
      throw PlatformException(code: 'protocol');
    }
    try {
      operations.add(args['callId'] as String);
      httpRequests++;
      return await transport.request(args);
    } on PythonTransportException catch (error) {
      throw PlatformException(code: error.kind);
    } on FormatException {
      throw PlatformException(code: 'protocol');
    }
  }

  Future<String> open() async {
    final reply = await channel.invokeMapMethod<String, Object?>('openSource', {
      'version': 1,
      'source': 'native-source-v1',
      'origin': '$origin',
    });
    final handle = reply!['handle'] as String;
    if (!handles.add(handle)) throw StateError('Repeated native source handle');
    return handle;
  }

  Future<Object?> call(String handle, String method, List<Object?> args) async {
    if (active != null) throw StateError('Fixture calls must be serialized');
    final id = (++sequence).toRadixString(16).padLeft(32, '0');
    final transport = PythonHttpTransport(
      callId: id,
      budget: const Duration(seconds: 12),
      allowUrl: (url) =>
          url.origin == origin.origin && url.path.startsWith('${origin.path}/'),
    );
    active = transport;
    try {
      return await channel
          .invokeMethod<Object?>('callSource', {
            'version': 1,
            'handle': handle,
            'method': method,
            'args': args,
            'callId': id,
          })
          .timeout(const Duration(seconds: 15));
    } finally {
      if (transport.activeRequestCount != 0)
        failures.add('Native call returned with pending HTTP');
      transport.close();
      active = null;
    }
  }

  Future<bool> release(String handle) async {
    handles.remove(handle);
    final result = await channel.invokeMapMethod<String, Object?>('release', {
      'version': 1,
      'handle': handle,
    });
    return result!['released'] == true;
  }

  Future<void> serve(HttpRequest request) async {
    final response = request.response;
    try {
      await request.drain<void>();
      if (request.uri.path == '${origin.path}/echo') {
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode({'method': request.method}));
      } else if (request.uri.path == '${origin.path}/proxy' &&
          request.uri.queryParameters['do'] == 'py') {
        final handle = request.uri.queryParameters['siteKey'];
        if (handle == null || !handles.contains(handle)) {
          response.statusCode = HttpStatus.notFound;
        } else {
          final value =
              await call(handle, 'proxy', [
                    {
                      ...request.uri.queryParameters,
                      'range':
                          request.headers.value(HttpHeaders.rangeHeader) ?? '',
                      'method': request.method,
                    },
                  ])
                  as List;
          proxyCalls++;
          response.statusCode = value[0] as int;
          response.headers.set(
            HttpHeaders.contentTypeHeader,
            value[1] as String,
          );
          (value[3] as Map).forEach(
            (key, value) => response.headers.set('$key', '$value'),
          );
          final body = value[4] == 1
              ? base64Decode(value[2] as String)
              : utf8.encode(value[2] as String);
          response.contentLength = body.length;
          if (request.method != 'HEAD') response.add(body);
        }
      } else {
        response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    } catch (error) {
      failures.add('$error');
      try {
        response.statusCode = HttpStatus.internalServerError;
        await response.close();
      } catch (_) {}
    }
  }

  Future<void> close() async {
    active?.close();
    for (final handle in handles.toList()) {
      await release(handle);
    }
    await server.close(force: true);
  }
}

Future<void> runNativeSourceFixture(
  MethodChannel channel,
  void Function(String, bool) check,
  int Function() heartbeat,
) async {
  final fixture = await NativeSourceFixture.start(channel);
  final http = HttpClient();
  channel.setMethodCallHandler(fixture.onMethod);
  final before = heartbeat();
  try {
    final a = await fixture.open();
    final b = await fixture.open();
    Future<Map> call(String handle, String method, List<Object?> args) async =>
        await fixture.call(handle, method, args) as Map;
    final home = await call(a, 'home', [true]);
    check(
      'source_shared_host_home',
      (home['class'] as List).first['type_name'] == '电影',
    );
    check('source_raw_extension', home['raw_extension'] == true);
    check('source_relative_module', home['relative_module'] == '内存包相对模块');
    check('source_package_resource', home['resource'] == '内存包资源');
    check(
      'source_http_transport',
      home['request_method'] == 'GET' &&
          fixture.httpRequests == 1 &&
          fixture.operations.length == 1,
    );
    final again = await call(a, 'home', [false]);
    check(
      'source_init_once',
      again['initializations'] == 1 && again['module_instances'] == 1,
    );
    check('source_same_instance', home['calls'] == 1 && again['calls'] == 2);
    final other = await call(b, 'home', [false]);
    check(
      'source_same_name_isolation',
      other['calls'] == 1 && other['module_instances'] == 1,
    );
    check(
      'source_recommendations',
      ((await call(a, 'homeVod', []))['list'] as List).first['vod_name'] ==
          '内存包推荐',
    );
    final category = await call(a, 'category', [
      'film',
      7,
      true,
      {'year': '2026'},
    ]);
    check(
      'source_category_filters',
      category['page'] == '7' &&
          category['extend']['year'] == '2026' &&
          category['filtered'] == true,
    );
    final search = await call(a, 'search', ['真实中文词', false, 3]);
    check(
      'source_search_unicode',
      search['page'] == '3' &&
          (search['list'] as List).first['vod_name'] == '真实中文词',
    );
    final detail = await call(a, 'detail', [
      [r'opaque/$#?中文'],
    ]);
    check(
      'source_detail_opaque',
      (detail['list'] as List).first['vod_id'] == r'opaque/$#?中文',
    );
    final play = await call(a, 'play', ['owned', 'episode-1', []]);
    final proxy = Uri.parse(play['url'] as String);
    check(
      'source_play_proxy_url',
      proxy.origin == fixture.origin.origin &&
          proxy.queryParameters['siteKey'] == a &&
          proxy.queryParameters['item'] == 'episode-1',
    );
    final get = await http.getUrl(proxy);
    get.headers.set(HttpHeaders.rangeHeader, 'bytes=0-5');
    final getResponse = await get.close();
    final bytes = await getResponse.fold<List<int>>(
      [],
      (all, part) => all..addAll(part),
    );
    check('source_proxy_get_bytes', base64Encode(bytes) == 'AP+ADQpB');
    check(
      'source_proxy_headers',
      getResponse.statusCode == 206 &&
          getResponse.headers.value('content-range') == 'bytes 0-5/6',
    );
    final head = await http.openUrl('HEAD', proxy);
    head.headers.set(HttpHeaders.rangeHeader, 'bytes=0-5');
    final headResponse = await head.close();
    final headBytes = await headResponse.fold<List<int>>(
      [],
      (all, part) => all..addAll(part),
    );
    check(
      'source_proxy_head',
      headResponse.statusCode == 206 &&
          headBytes.isEmpty &&
          headResponse.contentLength == 6,
    );
    check(
      'source_proxy_retains_instance',
      getResponse.headers.value('x-instance-calls') == '8' &&
          headResponse.headers.value('x-instance-calls') == '9' &&
          fixture.proxyCalls == 2,
    );
    final live = await call(a, 'liveContent', ['owned/catalog']);
    check(
      'source_live_json',
      live['url'] == 'owned/catalog' && (live['list'] as List).isEmpty,
    );
    check(
      'source_live_text',
      await fixture.call(a, 'liveContent', ['text']) ==
          '#EXTM3U\n#EXTINF:-1,Owned\nrelative/stream.m3u8\n',
    );
    check('source_release', await fixture.release(a));
    final fresh = await fixture.open();
    final stale = await http.getUrl(proxy);
    final staleResponse = await stale.close();
    await staleResponse.drain<void>();
    check(
      'source_released_proxy_not_rebound',
      staleResponse.statusCode == 404 && fresh != a && fixture.proxyCalls == 2,
    );
    try {
      await call(a, 'home', [false]);
      check('source_stale_handle', false);
    } on PlatformException catch (error) {
      check('source_stale_handle', error.code == 'invalid_handle');
    }
    check(
      'source_other_session_survives',
      (await call(b, 'home', [false]))['calls'] == 2,
    );
    final reset = await call(fresh, 'home', [false]);
    check(
      'source_recreate_state',
      reset['calls'] == 1 &&
          reset['initializations'] == 1 &&
          reset['module_instances'] == 1,
    );
    check('source_transport_drained', fixture.active == null);
    check('source_server_clean', fixture.failures.isEmpty);
    check('source_ui_responsive', heartbeat() - before >= 2);
  } finally {
    await fixture.close();
    channel.setMethodCallHandler(null);
    http.close(force: true);
  }
}
