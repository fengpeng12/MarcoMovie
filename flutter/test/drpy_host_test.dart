import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/catpaw_host.dart';

Map<String, dynamic> manifest() => {
  'version': 1,
  'kind': 'drpy',
  'runtime': CatPawHost.drpyRuntime,
  'sourceId': sha256.convert(utf8.encode('local source fixture')).toString(),
  'origin': 'pkg://local/rule.js',
  'rule': "var rule = {title:'本地 fixture',host:'https://fixture.invalid'};",
  'headers': <String, String>{'X-Fixture': 'local'},
  'requestTimeoutMs': 1000,
};

Future<String> fixtureBootstrap(Directory directory) async {
  final assets = Directory('${directory.path}/bootstrap');
  await assets.create();
  final entries = <Map<String, dynamic>>[];
  for (final name in [
    'drpy-worker.cjs',
    'drpy-http.cjs',
    'drpy-schema.cjs',
    'drpy-core.js',
    'drpy-dependencies.js',
    'drpy-LICENSE.txt',
  ]) {
    final bytes = utf8.encode('// Transport fixture asset: $name\n');
    await File('${assets.path}/$name').writeAsBytes(bytes);
    entries.add({
      'name': name,
      'sha256': sha256.convert(bytes).toString(),
      'bytes': bytes.length,
    });
  }
  await File('${assets.path}/drpy-assets.json').writeAsString(
    jsonEncode({
      'version': 1,
      'runtime': CatPawHost.drpyRuntime,
      'files': entries,
    }),
  );
  final file = File('${assets.path}/host.cjs');
  await file.writeAsString(r'''
const fs=require('node:fs'),http=require('node:http'),path=require('node:path');
const root=process.argv[2],ready=process.argv[3],secret='c'.repeat(64);
const server=http.createServer(async(req,res)=>{
  let raw=''; for await(const chunk of req) raw+=chunk;
  fs.writeFileSync(path.join(root,'last-request.json'),JSON.stringify({method:req.method,url:req.url,body:raw,contentType:req.headers['content-type']}));
  res.setHeader('Content-Type','application/json');
  if(req.url.endsWith('/_release')){fs.appendFileSync(path.join(root,'releases.txt'),'1');res.end(JSON.stringify({released:true}));}
  else {const value=JSON.parse(raw);if(value.args[0]==='hold'){fs.appendFileSync(path.join(root,'started.txt'),'1');await new Promise(resolve=>setTimeout(resolve,300));}
    if(!res.destroyed)res.end(JSON.stringify({list:[{vod_id:'fixture',vod_name:'fixture'}],request:value}));}
});
server.listen(0,'127.0.0.1',()=>fs.writeFileSync(ready,JSON.stringify({port:server.address().port,secret})));
process.stdin.resume();process.stdin.on('end',()=>server.close());
''');
  return file.path;
}

void main() {
  late Directory directory;
  late CatPawHost host;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('marco-drpy-test-');
    host = CatPawHost(
      directory: () async => Directory('${directory.path}/state'),
    );
  });
  tearDown(() async {
    await host.close();
    await directory.delete(recursive: true);
  });

  test(
    'DRPY install preserves exact UTF-8 manifest bytes and stable identity',
    () async {
      final bytes = utf8.encode(
        '${const JsonEncoder.withIndent('  ').convert(manifest())}\n',
      );
      final address = await host.installDrpy(bytes);
      final hash = sha256.convert(bytes).toString();
      expect(address, 'catpaw://$hash/api/drpy');
      expect(
        await File('${directory.path}/state/$hash/drpy.json').readAsBytes(),
        bytes,
      );
      expect(await host.installDrpy(bytes), address);
      expect(await host.installDrpy(manifest()), isNot(address));
      expect(await Directory('${directory.path}/state/$hash').list().length, 1);
    },
  );

  test(
    'DRPY rejects unsupported schema, paths and malformed UTF-8 before start',
    () async {
      for (final change in [
        {'version': 2},
        {'kind': 'other'},
        {'runtime': 'unknown'},
        {'sourceId': '../source'},
        {'origin': 'file:///private/source'},
        {'origin': 'https://user:secret@fixture.invalid/rule.js'},
        {'rule': ' '},
        {'requestTimeoutMs': 99},
        {'requestTimeoutMs': 15001},
        {
          'headers': {'Authorization': 'value\r\nX-Extra: nope'},
        },
        {
          'headers': {'Host': 'unrelated.invalid'},
        },
        {'unexpected': true},
      ]) {
        await expectLater(
          host.installDrpy({...manifest(), ...change}),
          throwsFormatException,
        );
      }
      await expectLater(
        host.installDrpy([255, 254, 123]),
        throwsFormatException,
      );
      await expectLater(
        host.callDrpy('catpaw://bad/api/drpy', 'home', []),
        throwsFormatException,
      );
      final address = await host.installDrpy(manifest());
      for (final suffix in [
        '/website',
        '/api/drpy/extra',
        '/api/drpy?secret=x',
      ]) {
        await expectLater(
          host.resolve(address.replaceFirst('/api/drpy', suffix)),
          throwsFormatException,
        );
      }
      await expectLater(
        host.callDrpy(address, 'eval', ['code']),
        throwsFormatException,
      );
    },
  );

  test(
    'DRPY POST transport sends one JSON object and releases source without restarting',
    () async {
      final node = (await Process.run('node', [
        '-p',
        'process.execPath',
      ])).stdout.toString().trim();
      final bootstrap = await fixtureBootstrap(directory);
      host = CatPawHost(
        directory: () async => Directory('${directory.path}/state'),
        executable: node,
        bootstrap: bootstrap,
      );
      final address = await host.installDrpy(manifest());
      final raw = await host.callDrpy(address, 'search', ['中文', false, 2]);
      expect(jsonDecode(raw), isA<Map<String, dynamic>>());
      expect((jsonDecode(raw) as Map)['request'], {
        'version': 1,
        'method': 'search',
        'args': ['中文', false, 2],
      });
      final observed =
          jsonDecode(
                await File(
                  '${directory.path}/state/last-request.json',
                ).readAsString(),
              )
              as Map;
      expect(observed['method'], 'POST');
      expect(observed['contentType'], startsWith('application/json'));
      expect(jsonDecode(observed['body']), isA<Map>());
      final before = await host.resolve(address);
      await host.releaseDrpy(address);
      expect(
        (jsonDecode(
              await File(
                '${directory.path}/state/last-request.json',
              ).readAsString(),
            )
            as Map)['url'],
        endsWith('/_release'),
      );
      expect(await host.resolve(address), before);
      expect(
        await File('${directory.path}/state/drpy-LICENSE.txt').exists(),
        isTrue,
      );
      await host.close();
      expect(
        (jsonDecode(await host.callDrpy(address, 'home', [true]))
            as Map)['list'],
        hasLength(1),
      );
    },
  );

  test(
    'DRPY detects modified source and pinned runtime before execution',
    () async {
      final address = await host.installDrpy(manifest());
      await File(
        '${directory.path}/state/${Uri.parse(address).host}/drpy.json',
      ).writeAsString(jsonEncode({...manifest(), 'rule': 'var rule = {};'}));
      await expectLater(host.resolve(address), throwsFormatException);
      final bootstrap = await fixtureBootstrap(directory);
      await File(
        '${File(bootstrap).parent.path}/drpy-core.js',
      ).writeAsString('tampered');
      host = CatPawHost(
        directory: () async => Directory('${directory.path}/fresh'),
        executable: 'missing-node',
        bootstrap: bootstrap,
      );
      final fresh = await host.installDrpy(manifest());
      await expectLater(
        host.callDrpy(fresh, 'home', [true]),
        throwsFormatException,
      );
      expect(
        await File('${directory.path}/fresh/ready.json').exists(),
        isFalse,
      );
    },
  );

  test(
    'pinned DRPY router executes local catalogue, search, detail and play',
    () async {
      final node = (await Process.run('node', [
        '-p',
        'process.execPath',
      ])).stdout.toString().trim();
      host = CatPawHost(
        directory: () async => Directory('${directory.path}/state'),
        executable: node,
        bootstrap: '${Directory.current.path}/assets/catpaw/host.cjs',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final base = 'http://127.0.0.1:${server.port}';
      final paths = <String>[];
      final headers = <String?>[];
      server.listen((request) async {
        paths.add(request.uri.path);
        headers.add(request.headers.value('x-fixture'));
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'list': [
              {
                'vod_id': '1',
                'vod_name': '本地 DRPY 影片',
                if (request.uri.path.startsWith('/detail/')) ...{
                  'vod_play_from': 'Fixture',
                  'vod_play_url': 'Episode\$$base/media.mp4',
                },
              },
            ],
          }),
        );
        await request.response.close();
      });
      const listing = 'js:VODS=JSON.parse(request(input)).list;';
      final rule = {
        'title': 'DRPY transport fixture',
        'host': base,
        'homeUrl': '/home',
        'url': '/category?type=fyclass&page=fypage',
        'searchUrl': '/search?wd=**&pg=fypage',
        'detailUrl': '/detail/fyid',
        'class_name': '本地分类',
        'class_url': '1',
        '推荐': listing,
        '一级': listing,
        '搜索': listing,
        '二级': 'js:VOD=JSON.parse(request(input)).list[0];',
        'play_parse': true,
        'play_json': <Object>[],
        'lazy': 'js:input={parse:0,url:input};',
      };
      final address = await host.installDrpy({
        ...manifest(),
        'origin': '$base/rule.js',
        'rule': 'var rule = ${jsonEncode(rule)};',
      });
      final home =
          jsonDecode(await host.callDrpy(address, 'home', [true])) as Map;
      expect((home['class'] as List).single['type_name'], '本地分类');
      for (final call in [
        ('homeVod', <Object?>[]),
        ('category', <Object?>['1', 2, false, {}]),
        ('search', <Object?>['中文', false, 1]),
      ]) {
        final value =
            jsonDecode(await host.callDrpy(address, call.$1, call.$2)) as Map;
        expect((value['list'] as List).single['vod_name'], '本地 DRPY 影片');
      }
      final detail =
          jsonDecode(await host.callDrpy(address, 'detail', ['1'])) as Map;
      expect(
        (detail['list'] as List).single['vod_play_url'],
        'Episode\$$base/media.mp4',
      );
      final play =
          jsonDecode(
                await host.callDrpy(address, 'play', [
                  'Fixture',
                  '$base/media.mp4',
                  [],
                ]),
              )
              as Map;
      expect(play['url'], '$base/media.mp4');
      expect(play['parse'], 0);
      expect(
        paths,
        containsAll(['/home', '/category', '/search', '/detail/1']),
      );
      expect(headers, everyElement('local'));
      final before = await host.resolve(address);
      await host.releaseDrpy(address);
      final again =
          jsonDecode(await host.callDrpy(address, 'home', [true])) as Map;
      expect((again['class'] as List).single['type_id'], '1');
      expect(await host.resolve(address), before);
    },
  );
}
