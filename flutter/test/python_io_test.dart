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

  test(
    'Python memory streams match CPython in the production QuickJS host',
    () async {
      const entry = 'pkg://fixture/stream.py';
      final expected =
          jsonDecode(
                File(
                  '../scripts/fixtures/python_io_expected.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final result =
          jsonDecode(
                await JsSourceHost.invoke(
                  entry: entry,
                  modules: {
                    entry: File(
                      '../scripts/fixtures/python_io_contract.py',
                    ).readAsStringSync(),
                  },
                  pythonPrelude: await loadPythonSourcePrelude(),
                  method: 'home',
                  arguments: [true],
                ),
              )
              as Map<String, dynamic>;
      expect(result.keys.toSet(), expected.keys.toSet());
      for (final key in expected.keys) {
        expect(result[key], expected[key], reason: key);
      }
    },
  );

  test(
    'Python stream state and binary requests survive catalogue to playback',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final origin = 'http://127.0.0.1:${server.port}';
      final bodies = <List<int>>[];
      server.listen((request) async {
        bodies.add(
          await request.fold<List<int>>([], (out, part) => out..addAll(part)),
        );
        request.response.write('{}');
        await request.response.close();
      });
      final client = CmsClient();
      final config = await client.resolveConfigInput(
        rawTextInput:
            '''
import io, json, requests
class Spider:
 def homeContent(self, filter):
  self.stream = io.BytesIO(bytes([0,255,128,65]))
  self.metadata = io.StringIO()
  json.dump({'title':'中文🎬'}, self.metadata, ensure_ascii=False)
  return {'list':[{'vod_id':'one','vod_name':'Stream fixture'}]}
 def detailContent(self, ids):
  self.metadata.seek(0)
  assert json.load(self.metadata)['title'] == '中文🎬'
  assert self.stream.read(1) == bytes([0])
  return {'list':[{'vod_id':'one','vod_play_from':'local','vod_play_url':'正片\$episode'}]}
 def playerContent(self, flag, id, vip):
  assert self.stream.tell() == 1
  self.stream.seek(0)
  requests.post('$origin/binary',data=self.stream.read())
  self.stream.close()
  return {'url':'$origin/media.mp4'}
''',
      );
      final site = config.config.sites.single;
      final video = (await client.fetchHome(site)).$2.videos.single;
      final detail = await client.fetchDetail(site, video);
      final play = await CmsClient().resolveEpisodeForPlayback(
        site,
        detail.lines.single.episodes.single,
      );
      expect(play.url, '$origin/media.mp4');
      expect(bodies, [
        [0, 255, 128, 65],
      ]);
    },
  );
}
