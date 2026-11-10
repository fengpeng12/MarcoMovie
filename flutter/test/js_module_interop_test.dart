import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/js_source_host.dart';
import 'package:marco_movie/core/cms_client.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  test('static ESM scan recognizes minified syntax and skips comments and literals', () {
    const source = r'''
// import 'comment-a.js';
/* export*from'comment-b.js'; */
const text = "import 'string.js';";
const pattern = /import'pattern.js';/;
const template = `import 'template.js'; ${`export*from'nested.js';`}`;
import'./side.js';import{a as b}from'./named.js';import*as ns from"./all.js";
import d,{x}from'./default.js';export{x as y}from'./reexport.js';export*from'./star.js';
export*as group from'./namespace.js';import/* comment */'./co\u0064ed.js';
const dynamic = import('./dynamic.js');
export default {home(){return {}}};
''';
    expect(JsSourceHost.esModuleReferences(source), [
      './side.js',
      './named.js',
      './all.js',
      './default.js',
      './reexport.js',
      './star.js',
      './namespace.js',
      './coded.js',
    ]);
    expect(JsSourceHost.isEsModule(source), isTrue);
    expect(
      JsSourceHost.isEsModule(r'''const s=`
import'no.js';
`; /* export default {}; */ const p = /export{a}/;'''),
      isFalse,
    );
    expect(JsSourceHost.isEsModule("import'./side.js';"), isTrue);
    expect(JsSourceHost.isEsModule("export{home};"), isTrue);
  });

  test(
    'minified source imports and reexports load through CmsClient',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final base = 'http://127.0.0.1:${server.port}';
      final requests = <String>[];
      final modules = {
        '/main.js': r'''// import './missing.js';
const text="export*from'./missing-string.js';";
import'./side.js';import{word}from'./alias.js';
export{home}from'./home.js';
export const search=async(q)=>({list:[{vod_id:'s',vod_name:word+q}]});
export const detail=(id)=>({list:[{vod_id:id,vod_name:'Fixture',vod_play_from:'Main',vod_play_url:'Film$asset'}]});
export const play=(flag,id)=>({url:'https://fixture.invalid/'+id+'.mp4'});''',
        '/side.js': "globalThis.loadedSide='loaded';",
        '/alias.js': "export{word}from'./data.js';",
        '/data.js': "export const word='found:';",
        '/home.js': "export function home(){return {list:[{vod_id:'1',vod_name:globalThis.loadedSide}]}}",
      };
      server.listen((request) async {
        requests.add(request.uri.path);
        final body = modules[request.uri.path];
        request.response.statusCode = body == null ? 404 : 200;
        request.response.write(body ?? 'missing');
        await request.response.close();
      });
      final client = CmsClient();
      final imported = await client.resolveConfigInput(
        urlInput: '$base/main.js',
      );
      final site = imported.config.sites.single;
      expect((await client.fetchHome(site)).$2.videos.single.title, 'loaded');
      final result = (await client.fetchSearch(site, 'word')).videos.single;
      expect(result.title, 'found:word');
      final detail = await client.fetchDetail(site, result);
      final playback = await client.resolveEpisodeForPlayback(
        site,
        detail.lines.single.episodes.single,
      );
      expect(playback.url, 'https://fixture.invalid/asset.mp4');
      expect(requests.toSet(), modules.keys.toSet());
    },
  );
  const entry = 'pkg://fixture/main.js';
  Future<dynamic> call(
    Map<String, String> modules,
    String method, [
    List<Object?> args = const [],
    Object? ext,
  ]) async => jsonDecode(
    await JsSourceHost.invoke(
      entry: entry,
      modules: modules,
      method: method,
      arguments: args,
      extension: ext,
    ),
  );

  test('CommonJS no-init source resolves helper and JSON dependencies through all Spider methods', () async {
    final modules = {
      entry: r'''
const {title} = require('./helper');
const data = require('./data.json');
module.exports = {
 home(){return {class:[{type_id:'1',type_name:'Films'}],list:[{vod_id:'42',vod_name:title}]}},
 search(q){return {list:[{vod_id:'42',vod_name:q}]}},
 detail(id){return {list:[{vod_id:id,vod_name:title,vod_play_from:'Main',vod_play_url:'Play$opaque'}]}},
 play(flag,id){return {url:data.url,header:{Referer:data.referer},id,flag}}
};''',
      'pkg://fixture/helper.js': "exports.title = 'CommonJS film';",
      'pkg://fixture/data.json': '{"url":"https://media.example/fixture.mp4","referer":"https://source.example/"}',
    };
    expect(
      (await call(modules, 'home'))['list'][0]['vod_name'],
      'CommonJS film',
    );
    expect(
      (await call(modules, 'search', ['query']))['list'][0]['vod_name'],
      'query',
    );
    expect(
      (await call(modules, 'detail', ['42']))['list'][0]['vod_play_url'],
      r'Play$opaque',
    );
    final media = await call(modules, 'play', ['Main', 'opaque']);
    expect(media['url'], 'https://media.example/fixture.mp4');
    expect(media['header']['Referer'], 'https://source.example/');
    expect(media['id'], 'opaque');
  });

  test(
    'CommonJS caches circular modules and preserves this in init and calls',
    () async {
      final modules = {
        entry: '''
const a = require('./a.js'); const again = require('./a.js');
module.exports = {init(ext){this.label=ext.label},home(){return {same:a===again,title:this.label,cycle:a.cycle}}};''',
        'pkg://fixture/a.js':
            "exports.name='a'; exports.cycle=require('./b.js').parent;",
        'pkg://fixture/b.js': "exports.parent=require('./a.js').name;",
      };
      expect(await call(modules, 'home', [], {'label': 'Initialized'}), {
        'same': true,
        'title': 'Initialized',
        'cycle': 'a',
      });
    },
  );

  test(
    'named ES module functions run without a default export or init',
    () async {
      expect(
        await call(
          {
            entry: "export function home(){return {list:[]}}; export const play=(flag,id)=>({url:id});",
          },
          'play',
          ['Main', 'https://media.example/clip.mp4'],
        ),
        {'url': 'https://media.example/clip.mp4'},
      );
    },
  );

  test(
    'CommonJS failure and missing API are not mistaken for empty results',
    () async {
      await expectLater(
        call({
          entry: "module.exports={home(){throw new Error('source broke')}}",
        }, 'home'),
        throwsA(predicate((e) => e.toString().contains('source broke'))),
      );
      await expectLater(
        call({entry: 'module.exports={home(){return {list:[]}}}'}, 'play'),
        throwsA(predicate((e) => e.toString().contains('缺少 play'))),
      );
      await expectLater(
        call({
          entry: "const fs=require('fs');module.exports={home(){return fs}}",
        }, 'home'),
        throwsA(predicate((e) => e.toString().contains('Node 内置模块'))),
      );
    },
  );

  test('async CommonJS source can use HTTP verbs and request-local timeout', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final base = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      if (request.uri.path == '/slow') {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      try {
        request.response.write(jsonEncode({'method': request.method}));
        await request.response.close();
      } catch (_) {
        /* Expected when the caller aborts /slow. */
      }
    });
    expect(
      await call({
        entry:
            "module.exports={async search(){const r=await req('$base/verb',{method:'PATCH'});return JSON.parse(r.content)}}",
      }, 'search'),
      {'method': 'PATCH'},
    );
    await expectLater(
      call({
        entry:
            "module.exports={async search(){return await req('$base/slow',{timeout:50})}}",
      }, 'search'),
      throwsA(anything),
    );
  });
}
