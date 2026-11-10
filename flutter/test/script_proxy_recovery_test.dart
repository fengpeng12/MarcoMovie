import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/js_source_host.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  tearDown(JsSourceHost.closeAll);

  Future<Uri> load(String source, {String key = 'proxy-recovery'}) async {
    const entry = 'pkg://proxy-recovery/main.js';
    Future<String> call(String method) => JsSourceHost.invoke(
      entry: entry,
      modules: {entry: source},
      method: method,
      arguments: [],
      sessionKey: key,
    );
    await call('home');
    return Uri.parse((jsonDecode(await call('play')) as Map)['url'] as String);
  }

  Future<(int, List<int>)> get(
    Uri url, {
    Map<String, String> headers = const {},
  }) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(url);
      headers.forEach(request.headers.set);
      final response = await request.close();
      return (
        response.statusCode,
        await response.fold<List<int>>([], (a, b) => a..addAll(b)),
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<void> abortAfterUpstreamStarts(Uri url, Future<void> started) async {
    final client = HttpClient();
    final request = await client.getUrl(url);
    final completed = request
        .close()
        .then((r) => r.drain<void>())
        .catchError((Object _) {});
    try {
      await started.timeout(const Duration(seconds: 3));
    } finally {
      client.close(force: true);
    }
    await completed;
  }

  for (final settles in [true, false]) {
    test(
      'aborted segment ${settles ? 'retains settled source state' : 'revokes an unsettled source route'}',
      () async {
        final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => upstream.close(force: true));
        final started = Completer<void>();
        upstream.listen((request) {
          if (!started.isCompleted) started.complete();
        });
        final endpoint = 'http://127.0.0.1:${upstream.port}/slow';
        final url = await load('''
let ticket = 'empty';
export function home() { ticket='retained'; return {}; }
export function play() { return {url:proxyUrl({kind:'slow'})}; }
export async function proxy(params) {
  if (params.kind === 'slow') {
    try { await req('$endpoint'); }
    catch (_) { ${settles ? '' : 'await new Promise(() => {});'} }
  }
  if (ticket !== 'retained') throw Error('playback state was discarded');
  return [200,'text/plain',ticket];
}
''');
        await abortAfterUpstreamStarts(url, started.future);
        final next = url.replace(
          queryParameters: {...url.queryParameters, 'kind': 'fast'},
        );
        if (settles) {
          final response = await get(next);
          expect(response.$1, 200);
          expect(utf8.decode(response.$2), 'retained');
          expect(JsSourceHost.ownsProxyUrl('proxy-recovery', url), isTrue);
        } else {
          final deadline = Stopwatch()..start();
          while (JsSourceHost.ownsProxyUrl('proxy-recovery', url) &&
              deadline.elapsed < const Duration(seconds: 3)) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          expect(JsSourceHost.ownsProxyUrl('proxy-recovery', url), isFalse);
          expect((await get(next)).$1, 404);
          // Opening the source again creates a different capability. The old
          // player address cannot quietly bind to a new init-only runtime.
          final replacement = await load('''
export function home(){return {}}
export function play(){return {url:proxyUrl()}}
export function proxy(){return [200,'text/plain','new source']}
''');
          expect(replacement.path, isNot(url.path));
          expect((await get(next)).$1, 404);
        }
      },
    );
  }

  test(
    'owned route checks exact source, authority, token and active lifetime',
    () async {
      final url = await load('''
export function home(){return {}}
export function play(){return {url:proxyUrl()}}
export function proxy(params){return [200,'application/json',JSON.stringify(params)]}
''');
      expect(JsSourceHost.ownsProxyUrl('proxy-recovery', url), isTrue);
      expect(JsSourceHost.ownsProxyUrl('another-source', url), isFalse);
      for (final invalid in [
        url.replace(scheme: 'https'),
        url.replace(host: 'localhost'),
        url.replace(port: url.port == 65535 ? 1 : url.port + 1),
        url.replace(userInfo: 'fixture'),
        url.replace(fragment: 'fragment'),
        url.replace(
          path:
              '${url.pathSegments.take(2).map((s) => '/$s').join()}extra/proxy',
        ),
        url.replace(path: '${url.path}/%252e%252e/segment.ts'),
      ]) {
        expect(
          JsSourceHost.ownsProxyUrl('proxy-recovery', invalid),
          isFalse,
          reason: invalid.toString(),
        );
      }
      final relative = url.resolve('nested/segment.ts');
      expect(JsSourceHost.ownsProxyUrl('proxy-recovery', relative), isTrue);
      final response = await get(
        relative.replace(query: 'item=one&item=two'),
        headers: {
          'Range': 'bytes=0-9999',
          'X-MarcoMovie-Proxy-Origin': 'https://upstream.example',
        },
      );
      expect(
        response.$1,
        200,
      ); // JSON remains whole; Range still reaches Spider.
      final params = jsonDecode(utf8.decode(response.$2)) as Map;
      expect(params['item'], 'two');
      expect(params['range'], 'bytes=0-9999');
      expect(params['path'], '/nested/segment.ts');
      expect(params['origin'], 'https://upstream.example');
      expect(params.containsKey('x-marcomovie-proxy-origin'), isFalse);
      expect(
        (await get(url, headers: {'Origin': 'https://upstream.example'})).$1,
        403,
      );
      await JsSourceHost.retainSessions({});
      expect(JsSourceHost.ownsProxyUrl('proxy-recovery', url), isFalse);
      expect((await get(url)).$1, 404);
    },
  );

  for (final metadata in ['{}, 2', 'false', '0']) {
    test(
      'typed binary response cannot hide invalid metadata $metadata',
      () async {
        final url = await load('''
export function home(){return {}}
export function play(){return {url:proxyUrl()}}
export function proxy(){return [200,'application/octet-stream',new Uint8Array([0,255,128]),$metadata]}
''');
        expect((await get(url)).$1, 502);
      },
    );
  }

  test('integer arrays and typed bytes keep exact binary data', () async {
    final url = await load('''
export function home(){return {}}
export function play(){return {url:proxyUrl({kind:'array'})}}
export function proxy(params){
 const values=[0,255,128,65];
 return [200,'application/octet-stream',params.kind==='array'?values:new Uint8Array(values),null,0];
}
''');
    for (final kind in ['array', 'typed']) {
      final response = await get(
        url.replace(queryParameters: {...url.queryParameters, 'kind': kind}),
      );
      expect(response.$1, 200);
      expect(response.$2, [0, 255, 128, 65]);
    }
  });

  test('invalid integer byte arrays are rejected without truncation', () async {
    final url = await load('''
export function home(){return {}}
export function play(){return {url:proxyUrl()}}
export function proxy(){return [200,'application/octet-stream',[0,256,-1,1.5]]}
''');
    expect((await get(url)).$1, 502);
  });

  for (final failingMethod in ['home', 'detail']) {
    test(
      'ordinary $failingMethod failure revokes old playback state immediately',
      () async {
        const source = '''
let count=0;
export function home(){if(++count>1)throw Error('fixture catalogue failure');return {}}
export function detail(){throw Error('fixture detail failure')}
export function play(){return {url:proxyUrl()}}
export function proxy(){return [200,'text/plain','retained-'+count]}
''';
        final oldUrl = await load(source);
        expect(utf8.decode((await get(oldUrl)).$2), 'retained-1');
        await expectLater(
          JsSourceHost.callCached(
            sessionKey: 'proxy-recovery',
            method: failingMethod,
            arguments: [],
          ),
          throwsA(isA<StateError>()),
        );
        // No polling or sleep: the fatal reply itself must close the worker,
        // not merely a later isolate-exit event.
        expect(JsSourceHost.ownsProxyUrl('proxy-recovery', oldUrl), isFalse);
        expect(
          await JsSourceHost.callCached(
            sessionKey: 'proxy-recovery',
            method: 'play',
            arguments: [],
          ),
          isNull,
        );
        final replacement = await load(
          source,
        ).timeout(const Duration(seconds: 3));
        expect(replacement.path, isNot(oldUrl.path));
        expect((await get(oldUrl)).$1, 404);
        expect(utf8.decode((await get(replacement)).$2), 'retained-1');
      },
    );
  }

  for (final body in ['while(true){}', 'return new Promise(() => {})']) {
    test('proxy execution deadline revokes its route: $body', () async {
      final url = await load('''
export function home(){return {}}
export function play(){return {url:proxyUrl()}}
export function proxy(){$body}
''');
      await expectLater(
        JsSourceHost.callCached(
          sessionKey: 'proxy-recovery',
          method: 'proxy',
          arguments: [<String, String>{}],
          budget: const Duration(milliseconds: 100),
        ).timeout(const Duration(seconds: 3)),
        throwsA(isA<StateError>()),
      );
      final deadline = Stopwatch()..start();
      while (JsSourceHost.ownsProxyUrl('proxy-recovery', url) &&
          deadline.elapsed < const Duration(seconds: 3)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(JsSourceHost.ownsProxyUrl('proxy-recovery', url), isFalse);
      expect((await get(url)).$1, 404);
    });
  }

  test(
    'maximum decoded binary body survives Base64 wire expansion',
    () async {
      final url = await load('''
export function home(){return {}}
export function play(){return {url:proxyUrl()}}
export function proxy(){
 const bytes=new Uint8Array(6*1024*1024); bytes[0]=255; bytes[bytes.length-1]=128;
 return [200,'application/octet-stream',bytes];
}
''');
      final response = await get(url);
      expect(response.$1, 200);
      expect(response.$2.length, 6 * 1024 * 1024);
      expect(response.$2.first, 255);
      expect(response.$2.last, 128);
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
