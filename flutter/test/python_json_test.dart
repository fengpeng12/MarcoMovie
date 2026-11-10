import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/js_source_host.dart';
import 'package:marco_movie/core/python_source_assets.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  tearDown(JsSourceHost.closeAll);

  test('Python JSON matches the complete CPython oracle in QuickJS', () async {
    const entry = 'pkg://fixture/contract.py';
    final fixture = Directory('../scripts/fixtures');
    final source = File(
      '${fixture.path}/python_json_contract.py',
    ).readAsStringSync();
    final expected =
        jsonDecode(
              File(
                '${fixture.path}/python_json_expected.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final actual =
        jsonDecode(
              await JsSourceHost.invoke(
                entry: entry,
                modules: {entry: source},
                pythonPrelude: await loadPythonSourcePrelude(),
                method: 'home',
                arguments: [true],
              ),
            )
            as Map<String, dynamic>;
    expect(actual.keys.toSet(), expected.keys.toSet());
    for (final key in expected.keys) {
      expect(actual[key], expected[key], reason: key);
    }
  });

  test(
    'Python JSON preserves signed payloads and errors through the real client',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final origin = 'http://127.0.0.1:${server.port}';
      final observed = <String, String>{};
      server.listen((request) async {
        observed[request.uri.path] = await utf8.decoder.bind(request).join();
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          request.uri.path == '/malformed'
              ? '{"data": bad}'
              : '{"id":9007199254740993123456789}',
        );
        await request.response.close();
      });
      final client = CmsClient();
      final imported = await client.resolveConfigInput(
        rawTextInput:
            '''
import json, requests
class Spider:
 def homeContent(self, filter):
  payload = json.dumps({'z':'中文🎬','a':9007199254740993123456789}, sort_keys=True, ensure_ascii=False, separators=(',',':'))
  requests.post('$origin/signed', data=payload)
  response = requests.post('$origin/json', json={'id':9007199254740993123456789,'name':'中文'})
  self.identifier = str(response.json()['id'])
  try: requests.get('$origin/malformed').json()
  except json.JSONDecodeError as error:
   self.error_position = error.pos
  return {'list':[{'vod_id':self.identifier,'vod_name':self.identifier}]}
 def detailContent(self, ids):
  assert self.error_position == 9
  assert self.identifier == ids[0]
  return {'list':[{'vod_id':ids[0], 'vod_play_from':'local', 'vod_play_url':'正片\$' + ids[0]}]}
 def playerContent(self, flag, id, vip):
  return {'url':'$origin/media.mp4', 'header':{'X-Asset':self.identifier}}
''',
      );
      final site = imported.config.sites.single;
      final video = (await client.fetchHome(site)).$2.videos.single;
      expect(video.id, '9007199254740993123456789');
      expect(observed['/signed'], '{"a":9007199254740993123456789,"z":"中文🎬"}');
      expect(
        observed['/json'],
        r'{"id": 9007199254740993123456789, "name": "\u4e2d\u6587"}',
      );
      final detail = await client.fetchDetail(site, video);
      final play = await CmsClient().resolveEpisodeForPlayback(
        site,
        detail.lines.single.episodes.single,
      );
      expect(play.url, '$origin/media.mp4');
      expect(play.headers['X-Asset'], video.id);
    },
  );

  test(
    'Python JSON in QuickJS preserves hooks, streams and invalid input positions',
    () async {
      const entry = 'pkg://fixture/json.py';
      final result = jsonDecode(
        await JsSourceHost.invoke(
          entry: entry,
          modules: {
            entry: r'''
import json
class Stream:
 def __init__(self): self.value = ''
 def write(self, value): self.value += value
 def read(self): return self.value
class Spider:
 def homeContent(self, filter):
  stream = Stream()
  returned = json.dump({'二':[1,True,None]}, stream, ensure_ascii=False, indent=2)
  errors = []
  for doc in ['{"🎬":\n ?}', '"bad\\q"']:
   try: json.loads(doc)
   except json.JSONDecodeError as e: errors.append([e.pos,e.lineno,e.colno])
  return {'text':stream.value, 'value':json.load(stream), 'return':returned, 'errors':errors,
   'number':json.dumps([1.2345678901234567,-0.0,1e-6]),
   'pairs':json.loads('{"x":1,"x":2}',object_pairs_hook=lambda v:v)}
''',
          },
          pythonPrelude: await loadPythonSourcePrelude(),
          method: 'home',
          arguments: [true],
        ),
      );
      expect(result['value'], {
        '二': [1, true, null],
      });
      expect(
        result['text'],
        '{\n  "二": [\n    1,\n    true,\n    null\n  ]\n}',
      );
      expect(result['return'], isNull);
      expect(result['errors'], [
        [7, 2, 2],
        [4, 1, 5],
      ]);
      expect(result['number'], '[1.2345678901234567, -0.0, 1e-06]');
      expect(result['pairs'], [
        ['x', 1],
        ['x', 2],
      ]);
    },
  );
}
