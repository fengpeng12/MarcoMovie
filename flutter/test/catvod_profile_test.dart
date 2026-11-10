import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/js_source_host.dart';

const _script = r'''
import {Spider, net, md5X, sha256X, page} from 'catvod';
import {name} from './helper.js';
export default class extends Spider {
  init(ext){this.base=ext;this.count=0;}
  bound(){return this.base;}
  async homeContent(input){
    if(!input) return {ext:this.base,key:this.siteKey,bound:[0].map(this.bound),name,
      md5:md5X('中文'),sha:sha256X(''),page:page([1,2,3],2,2),count:++this.count};
    const result=await net.req(this.base+input.path,input.options);
    if(input.options?.buffer===3 && !result.error)
      return {...result,isBuffer:result.content instanceof ArrayBuffer,content:Array.from(new Uint8Array(result.content))};
    return result;
  }
  async detailContent(ids){return net.json(this.base+ids[0]);}
  playerContent(flag,id){return {parse:0,url:this.proxyUrl({id})};}
  proxy(params){if(params.siteKey!==this.siteKey)throw Error('identity');return [200,'application/octet-stream',new Uint8Array([0,255,128,65])];}
}
''';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  tearDown(CmsClient.closeScriptSessions);
  late HttpServer server;
  late HttpServer second;
  late String origin;
  final requests = <Map<String, Object?>>[];

  setUp(() async {
    requests.clear();
    second = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    second.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'auth': request.headers.value('authorization'),
          'cookie': request.headers.value('cookie'),
          'referer': request.headers.value('referer'),
        }),
      );
      await request.response.close();
    });
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      final body = await request.fold<List<int>>([], (a, b) => a..addAll(b));
      final record = <String, Object?>{
        'method': request.method,
        'url': request.uri.toString(),
        'body': body,
        'contentType': request.headers.value('content-type'),
        'cookie': request.headers.value('cookie'),
      };
      requests.add(record);
      final response = request.response;
      switch (request.uri.path) {
        case '/bytes':
          response.statusCode = 206;
          response.headers.contentType = ContentType.binary;
          response.add([0, 255, 128, 65]);
        case '/bad-json':
          response.write('not-json');
        case '/failed':
          response.statusCode = 503;
          response.write('owned failure');
        case '/slow':
          await Future<void>.delayed(const Duration(milliseconds: 300));
          response.write('late');
        case '/medium':
          await Future<void>.delayed(const Duration(milliseconds: 100));
          response.write('independent');
        case '/redirect':
          response.statusCode = 302;
          response.headers.set(
            'location',
            'http://127.0.0.1:${second.port}/echo',
          );
        case '/cookie':
          response.headers.add('set-cookie', 'owned=secret; Path=/');
          response.write('set');
        case '/charset':
          response.headers.set('content-type', 'text/plain; charset=gbk');
          response.add([0xc4, 0xe3]);
        default:
          response.headers.contentType = ContentType.json;
          response.write(jsonEncode(record));
      }
      await response.close();
    });
    addTearDown(() async {
      await server.close(force: true);
      await second.close(force: true);
    });
  });

  Future<dynamic> call(
    String method,
    List<Object?> arguments, {
    Completer<void>? cancellation,
    String? source,
    String key = 'catvod-fixture',
  }) async {
    return jsonDecode(
      await JsSourceHost.invoke(
        entry: 'pkg://catvod-fixture/main.js',
        modules: {
          'pkg://catvod-fixture/main.js': source ?? _script,
          'pkg://catvod-fixture/helper.js':
              "import {page} from 'catvod'; export const name=page(['nested'],1,1).list[0];",
        },
        method: method,
        arguments: arguments,
        extension: origin,
        rawExtension: origin,
        sessionKey: key,
        cancellation: cancellation,
      ),
    );
  }

  Future<dynamic> req(String path, [Map<String, Object?> options = const {}]) =>
      call('home', [
        {'path': path, 'options': options},
      ]);

  test(
    'real QuickJS imports base and nested module, binds this and hashes',
    () async {
      final value = await call('home', [false]);
      expect(value['ext'], origin);
      expect(value['bound'], [origin]);
      expect(value['name'], 'nested');
      expect(value['key'], isNotEmpty);
      expect(value['md5'], 'a7bac2239fcdcb3a067903d8077c4a07');
      expect(
        value['sha'],
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      expect(value['page'], {
        'list': [3],
        'page': 2,
        'pagecount': 2,
        'limit': 2,
        'total': 3,
      });
      expect((await call('home', [false]))['count'], 2);
    },
  );

  test(
    'actual transport encodes repeated query, JSON, form and raw bytes',
    () async {
      final query = await req('/echo?old=1#discard', {
        'params': {
          'q': ['中文', 'a b'],
          'skip': null,
        },
      });
      expect(
        jsonDecode(query['content'])['url'],
        '/echo?old=1&q=%E4%B8%AD%E6%96%87&q=a%20b',
      );
      for (final options in [
        {
          'method': 'POST',
          'data': {'word': '中文'},
        },
        {
          'method': 'POST',
          'postType': 'form',
          'data': {'word': '中 文', 'n': 2},
        },
        {
          'method': 'POST',
          'headers': {'Content-Type': 'application/octet-stream'},
          'body': [0, 255, 128, 65],
        },
        {'method': 'PUT'},
      ]) {
        expect((await req('/echo', options))['code'], 200);
      }
      expect(requests[1]['body'], utf8.encode('{"word":"中文"}'));
      expect(
        requests[2]['body'],
        utf8.encode('word=%E4%B8%AD%20%E6%96%87&n=2'),
      );
      expect(requests[3]['body'], [0, 255, 128, 65]);
      expect(requests[4]['body'], isEmpty);
      expect((await req('/echo', {'method': 'OPTIONS'}))['code'], 200);
      expect((await req('/echo', {'method': 'HEADER'}))['content'], '');
    },
  );

  test(
    'binary response types are real bytes and transport errors are distinguished',
    () async {
      final bytes = await req('/bytes', {'buffer': 3});
      expect(bytes['isBuffer'], true);
      expect(bytes['content'], [0, 255, 128, 65]);
      expect((await req('/bytes', {'buffer': 1}))['content'], [
        0,
        255,
        128,
        65,
      ]);
      expect((await req('/bytes', {'buffer': 2}))['content'], 'AP+AQQ==');
      expect((await req('/failed'))['content'], 'owned failure');
      expect((await req('/charset'))['error'], contains('charset'));
      expect((await req('/slow', {'timeout': 40}))['error'], isNotEmpty);
      // A caught request failure does not reset this source's state.
      expect((await call('home', [false]))['count'], 1);
      await expectLater(call('detail', ['/failed']), throwsA(anything));
      await expectLater(call('detail', ['/bad-json']), throwsA(anything));
    },
  );

  test(
    'strict unsupported and malformed options never reach the server',
    () async {
      for (final options in <Map<String, Object?>>[
        {'cookie': true},
        {'postType': 'form-data'},
        {'netId': 1},
        {'buffer': 4},
        {'callTimeout': 0},
        {
          'headers': {'content-length': '3'},
        },
        {
          'headers': {'x-value': 'a\r\nb'},
        },
        {
          'params': {'nested': {}},
        },
        {'method': 'POST', 'body': [], 'data': {}},
        {
          'method': 'POST',
          'body': [256],
          'headers': {'content-type': 'x'},
        },
      ]) {
        expect((await req('/echo', options))['error'], isNotEmpty);
      }
      expect(requests, isEmpty);
      for (final imported in [
        "import {local} from 'catvod';",
        "import {net} from 'catvod:host';",
      ]) {
        await expectLater(
          call(
            'home',
            [],
            source: '$imported export function home(){return {}}',
            key: imported,
          ),
          throwsA(anything),
        );
      }
    },
  );

  test(
    'no implicit cookie jar and cross-origin redirect drops explicit secrets',
    () async {
      await req('/cookie');
      final echo = await req('/echo');
      expect(jsonDecode(echo['content'])['cookie'], isNull);
      final redirected = await req('/redirect', {
        'headers': {
          'Authorization': 'owned',
          'Cookie': 'owned=secret',
          'Referer': origin,
        },
      });
      expect(jsonDecode(redirected['content']), {
        'auth': null,
        'cookie': null,
        'referer': origin,
      });
      expect((await req('/redirect', {'redirect': 0}))['code'], 302);
    },
  );

  test(
    'same retained Spider serves binary Range and is revoked on removal',
    () async {
      final play = await call('play', ['fixture', 'opaque', []]);
      final uri = Uri.parse(play['url']);
      final release = JsSourceHost.pinForPlayback('catvod-fixture');
      addTearDown(release);
      final http = HttpClient();
      addTearDown(() => http.close(force: true));
      final request = await http.getUrl(uri);
      request.headers.set('Range', 'bytes=1-2');
      final response = await request.close();
      expect(response.statusCode, 206);
      expect(await response.fold<List<int>>([], (a, b) => a..addAll(b)), [
        255,
        128,
      ]);
      await CmsClient.retainScriptSessions([]);
      final gone = await (await http.getUrl(uri)).close();
      expect(gone.statusCode, 404);
      await gone.drain<void>();
    },
  );

  test(
    'CmsClient imports nested CatVod without remote virtual-module lookup',
    () async {
      const script =
          "import {Spider} from 'catvod'; import {title} from './helper.js'; export default class extends Spider {homeContent(){return {list:[{vod_id:'one',vod_name:title}]}}}";
      final client = CmsClient();
      final imported = await client.resolveConfigInput(
        rawTextInput: jsonEncode({
          'sites': [
            {
              'key': 'catvod-local',
              'type': 3,
              'api': 'csp_LocalScript.js',
              'ext': {
                'script': script,
                'origin': 'pkg://owned/main.js',
                'modules': {
                  'pkg://owned/helper.js':
                      "import {page} from 'catvod'; export const title=page(['Owned'],1,1).list[0];",
                },
              },
            },
          ],
        }),
      );
      expect(
        (await client.fetchHome(
          imported.config.sites.single,
        )).$2.videos.single.title,
        'Owned',
      );
      expect(requests, isEmpty);
    },
  );

  test(
    'cancelled CatVod transport still terminates worker and permits a fresh call',
    () async {
      final cancel = Completer<void>();
      final pending = call('home', [
        {'path': '/slow', 'options': {}},
      ], cancellation: cancel);
      while (requests.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      cancel.complete();
      await expectLater(pending, throwsA(anything));
      expect((await call('home', [false]))['count'], 1);
    },
  );

  test(
    'normal close bounds a CPU-bound destroy and forbids cleanup HTTP',
    () async {
      const cleanup = r'''
import {Spider} from 'catvod';
export default class extends Spider {
  init(ext){this.base=ext;}
  homeContent(){return {ready:true};}
  async destroy(){
    const result=await this.net.req(this.base+'/must-not-run');
    if (!result.error) throw Error('cleanup network was allowed');
    while(true){}
  }
}
''';
      expect((await call('home', [], source: cleanup))['ready'], true);
      final watch = Stopwatch()..start();
      await CmsClient.closeScriptSessions();
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(300));
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
      expect(requests, isEmpty);
    },
  );

  test('callTimeout is enforced separately from a larger timeout', () async {
    expect(
      (await req('/slow', {'timeout': 2000, 'callTimeout': 40}))['error'],
      isNotEmpty,
    );
    expect((await call('home', [false]))['count'], 1);
  });

  test(
    'CatVod proxy identity survives mutation of legacy proxy globals',
    () async {
      const source = r'''
import {Spider,proxyUrl} from 'catvod';
export default class extends Spider {
  homeContent(){
    const before=proxyUrl({id:'a/b 中文'});
    globalThis.__movieProxyBase='https://invalid.example/not-this-source';
    globalThis.proxyUrl=()=> 'https://invalid.example/replaced';
    const after=this.proxyUrl({id:'a/b 中文'});
    return {before,after,key:this.siteKey};
  }
}
''';
      final value = await call('home', [], source: source);
      expect(value['after'], value['before']);
      final uri = Uri.parse(value['after']);
      expect(uri.host, '127.0.0.1');
      expect(uri.queryParameters['siteKey'], value['key']);
      expect(uri.queryParameters['id'], 'a/b 中文');
    },
  );

  test(
    'same Spider method can fall back after one request times out',
    () async {
      const source = r'''
import {Spider} from 'catvod';
export default class extends Spider {
  init(ext){this.base=ext;}
  async homeContent(){
    const failed=await this.net.req(this.base+'/slow',{callTimeout:40});
    const good=await this.net.json(this.base+'/echo');
    return {failed:!!failed.error,method:good.method};
  }
}
''';
      expect(await call('home', [], source: source), {
        'failed': true,
        'method': 'GET',
      });
    },
  );

  test(
    'concurrent CatVod requests have independent timeout ownership',
    () async {
      const source = r'''
import {Spider} from 'catvod';
export default class extends Spider {
  init(ext){this.base=ext;}
  async homeContent(){
    const [failed,good]=await Promise.all([
      this.net.req(this.base+'/slow',{callTimeout:40}),
      this.net.req(this.base+'/medium',{callTimeout:1000})
    ]);
    return {failed:!!failed.error,code:good.code,content:good.content,error:good.error||''};
  }
}
''';
      expect(await call('home', [], source: source), {
        'failed': true,
        'code': 200,
        'content': 'independent',
        'error': '',
      });
    },
  );
}
