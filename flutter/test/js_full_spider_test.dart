import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/js_source_host.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  tearDown(CmsClient.closeScriptSessions);

  for (final prefix in ['export default', 'module.exports =']) {
    test(
      '$prefix class uses full methods, one instance and raw extension',
      () async {
        const entry = 'pkg://full-spider/main.js';
        final source =
            '''
let constructed = 0;
$prefix class {
 #state;
 constructor(){constructed++;this.#state={calls:0};}
 init(ext){this.#state.ext=ext;}
 homeContent(filter){return {constructed,calls:++this.#state.calls,ext:this.#state.ext,filter};}
 homeVideoContent(){return 'unchanged-string';}
 categoryContent(id,pg,filter,extend){return {id,pg,filter,extend};}
 detailContent(ids){return {ids,calls:this.#state.calls};}
 async searchContent(word,quick,pg){await Promise.resolve();return {word,quick,pg};}
 playerContent(flag,id,vip){return {flag,id,vip};}
}
''';
        Future<dynamic> call(String method, List<Object?> args) async {
          final value = await JsSourceHost.invoke(
            entry: entry,
            modules: {entry: source},
            method: method,
            arguments: args,
            extension: {'old': 'object'},
            rawExtension: '  { "raw": true }\n',
            sessionKey: 'full-$prefix',
          );
          return method == 'homeVod' ? value : jsonDecode(value);
        }

        expect(await call('home', [true]), {
          'constructed': 1,
          'calls': 1,
          'ext': '  { "raw": true }\n',
          'filter': true,
        });
        expect((await call('home', [false]))['calls'], 2);
        expect(await call('homeVod', []), 'unchanged-string');
        expect(
          await call('category', [
            'id',
            3,
            true,
            {'year': '2025'},
          ]),
          {
            'id': 'id',
            'pg': '3',
            'filter': true,
            'extend': {'year': '2025'},
          },
        );
        expect(await call('detail', ['a\$b#c']), {
          'ids': ['a\$b#c'],
          'calls': 2,
        });
        expect(await call('detail', [<String>[]]), {'ids': [], 'calls': 2});
        expect(
          await call('detail', [
            ['one', 'one'],
          ]),
          {
            'ids': ['one', 'one'],
            'calls': 2,
          },
        );
        expect(await call('search', ['word', false, 4]), {
          'word': 'word',
          'quick': false,
          'pg': '4',
        });
        expect(
          await call('play', [
            'line',
            'opaque',
            ['vip'],
          ]),
          {
            'flag': 'line',
            'id': 'opaque',
            'vip': ['vip'],
          },
        );
      },
    );
  }

  test(
    'imported subscription retains exact string ext through full JS playback',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      const originalExt = ' \n{ "ticket": "retained" }\t ';
      final script =
          '''
export default class {
 init(ext){if(ext!==${jsonEncode(originalExt)})throw Error('raw extension lost');this.ticket=JSON.parse(ext).ticket;}
 homeContent(filter){if(typeof filter!=='boolean')throw Error('filter type');return {class:[{type_id:'films',type_name:'Films'}]};}
 homeVideoContent(){return {list:[{vod_id:'one',vod_name:this.ticket}]};}
 categoryContent(id,pg,filter,ext){if(typeof pg!=='string')throw Error('page type');return {page:+pg,list:[{vod_id:id,vod_name:this.ticket}]};}
 searchContent(word,quick,pg){if(pg!=='4')throw Error('search page type');return {list:[{vod_id:word,vod_name:this.ticket}]};}
 detailContent(ids){if(!Array.isArray(ids)||ids[0]!=='one')throw Error('detail collection');return {list:[{vod_id:ids[0],vod_name:this.ticket,vod_play_from:'local',vod_play_url:'One\$opaque'}]};}
 playerContent(flag,id,vip){if(flag!=='local'||id!=='opaque'||!Array.isArray(vip))throw Error('player args');return {url:proxyUrl({ticket:this.ticket})};}
 proxy(params){if(params.ticket!==this.ticket)throw Error('source state lost');return [200,'text/plain',this.ticket];}
}
''';
      server.listen((request) async {
        request.response.write(script);
        await request.response.close();
      });
      final client = CmsClient();
      final imported = await client.resolveConfigInput(
        rawTextInput: jsonEncode({
          'sites': [
            {
              'key': 'full',
              'name': 'Fixture',
              'type': 3,
              'api': 'http://127.0.0.1:${server.port}/source.js',
              'ext': originalExt,
            },
          ],
        }),
      );
      final site = imported.config.sites.single;
      expect(site.ext, originalExt.trim());
      expect(site.rawExtension, originalExt);
      expect(site.copyWith(name: 'Renamed').rawExtension, originalExt);
      expect(site.copyWith(ext: 'new').rawExtension, isNull);
      final home = await client.fetchHome(site);
      expect(home.$1.single.id, 'films');
      expect(home.$2.videos.single.title, 'retained');
      expect((await client.fetchCategory(site, 'films', 3)).page, 3);
      expect(
        (await client.fetchSearch(site, 'word', page: 4)).videos.single.id,
        'word',
      );
      final detail = await client.fetchDetail(site, home.$2.videos.single);
      final release = client.pinPlaybackSource(site);
      addTearDown(release);
      final episode = await client.resolveEpisodeForPlayback(
        site,
        detail.lines.single.episodes.single,
      );
      final http = HttpClient();
      addTearDown(() => http.close(force: true));
      final response = await (await http.getUrl(
        Uri.parse(episode.url),
      )).close();
      expect(response.statusCode, 200);
      expect(await utf8.decoder.bind(response).join(), 'retained');
      // An ext-only edit must not silently reuse the previous initialized source.
      await expectLater(
        client.fetchHome(site.copyWith(rawExtension: site.ext)),
        throwsA(anything),
      );
    },
  );

  for (final extension in <Object>[
    '  exact text\n',
    {'object': true},
  ]) {
    test(
      'local package preserves string ext or serializes object ext: ${extension.runtimeType}',
      () async {
        final expected = extension is String
            ? extension
            : jsonEncode(extension);
        final archive = Archive()
          ..addFile(
            ArchiveFile.string(
              'config.json',
              jsonEncode({
                'sites': [
                  {
                    'key': 'local',
                    'type': 3,
                    'api': 'main.js',
                    'ext': extension,
                  },
                ],
              }),
            ),
          )
          ..addFile(
            ArchiveFile.string('main.js', '''
module.exports={init(ext){this.ext=ext},homeContent(){return {list:[{vod_id:'one',vod_name:JSON.stringify(this.ext)}]}}};
'''),
          );
        final client = CmsClient();
        final imported = await client.resolveConfigInput(
          rawTextInput: CmsClient.readSubscriptionFile(
            ZipEncoder().encode(archive),
            'fixture.zip',
          ),
        );
        expect(
          (await client.fetchHome(
            imported.config.sites.single,
          )).$2.videos.single.title,
          jsonEncode(expected),
        );
      },
    );
  }

  test(
    'legacy Cat metadata and already-array detail arguments remain unchanged',
    () async {
      const entry = 'pkg://cat/source.js';
      const script = '''
var __jsEvalReturn=()=>({
 init(ext){this.ext=ext},
 homeContent(){return this.ext},
 detailContent(ids){return {ids,ext:this.ext}}
});
''';
      Future<dynamic> call(String method, List<Object?> args) async =>
          jsonDecode(
            await JsSourceHost.invoke(
              entry: entry,
              modules: {entry: script},
              method: method,
              arguments: args,
              extension: {
                'stype': 3,
                'skey': 'cat',
                'ext': {'value': 1},
              },
              rawExtension: 'must not replace cat metadata',
              catDetails: true,
              sessionKey: 'legacy-cat',
            ),
          );
      expect(await call('home', []), {
        'stype': 3,
        'skey': 'cat',
        'ext': {'value': 1},
      });
      expect((await call('detail', ['opaque']))['ids'], ['opaque']);
    },
  );

  test(
    'mixed short names retain precedence and existing init value types',
    () async {
      const entry = 'pkg://mixed/source.js';
      const source = '''
export default {init(ext){this.ext=ext},home(){return this.ext},homeContent(){throw Error('wrong precedence')},detailContent(ids){return ids}};
''';
      final result = await JsSourceHost.invoke(
        entry: entry,
        modules: {entry: source},
        method: 'home',
        arguments: [],
        extension: {'legacy': true},
        rawExtension: 'not the old init value',
      );
      expect(jsonDecode(result), {'legacy': true});
    },
  );

  test(
    'named module exports receive full-name aliases without mutation',
    () async {
      const entry = 'pkg://named/source.js';
      const source = '''
let extension;
export function init(ext){extension=ext;}
export function homeContent(){return {extension};}
export function detailContent(ids){return ids;}
''';
      expect(
        jsonDecode(
          await JsSourceHost.invoke(
            entry: entry,
            modules: {entry: source},
            method: 'home',
            arguments: [],
            extension: {'value': 1},
          ),
        ),
        {'extension': '{"value":1}'},
      );
    },
  );

  test(
    'backup and restore keep original string ext alongside normalized ext',
    () async {
      const rawExt = ' \n signed fixture text\t ';
      SharedPreferences.setMockInitialValues({});
      var storage = await StorageService.init();
      await storage.saveConfig(
        jsonEncode({
          'sites': [
            {
              'key': 'backup',
              'name': 'Fixture',
              'api': 'https://source.example/main.js',
              'type': 3,
              'ext': rawExt,
            },
          ],
        }),
      );
      final backup = storage.exportBackupJson();
      SharedPreferences.setMockInitialValues({});
      storage = await StorageService.init();
      await storage.importBackupJson(backup);
      final site = storage.loadSavedConfig()!.sites.single;
      expect(site.ext, rawExt.trim());
      expect(site.rawExtension, rawExt);
    },
  );

  test('class-field entrypoints are instantiated once', () async {
    const entry = 'pkg://class-fields/main.js';
    const source = '''
export default class {
 #value=0;
 homeContent=()=>({value:++this.#value});
}
''';
    Future<String> call() => JsSourceHost.invoke(
      entry: entry,
      modules: {entry: source},
      method: 'home',
      arguments: [],
      sessionKey: 'class-fields',
    );
    expect(jsonDecode(await call()), {'value': 1});
    expect(jsonDecode(await call()), {'value': 2});
  });

  test(
    'unsupported catvod host imports fail explicitly before evaluation',
    () async {
      const entry = 'pkg://unsupported/source.js';
      await expectLater(
        JsSourceHost.invoke(
          entry: entry,
          modules: {
            entry:
                "import {Spider} from 'catvod:host'; export default class extends Spider {homeContent(){return {}}}",
          },
          method: 'home',
          arguments: [],
        ).timeout(const Duration(seconds: 3)),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message.toString(),
            'reason',
            contains('CatVod'),
          ),
        ),
      );
    },
  );
}
