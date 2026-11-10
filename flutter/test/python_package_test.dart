import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/js_source_host.dart';
import 'package:marco_movie/core/python_source_assets.dart';

Archive package(String title, {bool config = false}) {
  final result = Archive()
    ..addFile(
      ArchiveFile.string('bundle/main.py', '''
import io, json
from helper import title
class Spider:
 def homeContent(self, filter):
  assert __file__ == '/__package__/bundle/main.py'
  self.stream = io.open('data/payload.bin', 'rb')
  assert self.stream.read(1) == bytes([0])
  with open(__file__.rsplit('/',1)[0] + '/data/metadata.json', encoding='utf-8') as f:
   assert json.load(f)['title'] == title
  assert f.closed
  return {'list':[{'vod_id':'one','vod_name':title}]}
 def detailContent(self, ids):
  assert self.stream.tell() == 1
  return {'list':[{'vod_id':ids[0],'vod_play_from':'local','vod_play_url':'正片\$episode'}]}
 def playerContent(self, flag, id, vip):
  assert list(self.stream.read()) == [255,128,65]
  self.stream.close()
  return {'url':'https://media.example/movie.mp4'}
'''),
    )
    ..addFile(
      ArchiveFile.string('bundle/helper.py', '''
import json
with open(__file__.rsplit('/',1)[0] + '/data/metadata.json', encoding='utf-8') as f:
 title = json.load(f)['title']
'''),
    )
    ..addFile(
      ArchiveFile.string(
        'bundle/data/metadata.json',
        jsonEncode({'title': title}),
      ),
    )
    ..addFile(ArchiveFile('bundle/data/payload.bin', 4, [0, 255, 128, 65]));
  if (config) {
    result.addFile(
      ArchiveFile.string(
        'config.json',
        jsonEncode({
          'sites': [
            {
              'key': 'packed',
              'name': 'Packed source',
              'type': 3,
              'api': './bundle/main.py',
            },
          ],
        }),
      ),
    );
  }
  return result;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  tearDown(JsSourceHost.closeAll);

  test(
    'Python package file operations match the independent CPython oracle in QuickJS',
    () async {
      final fixture =
          jsonDecode(
                File(
                  '../scripts/fixtures/python_package_fixture.json',
                ).readAsStringSync(),
              )
              as Map;
      final expected =
          jsonDecode(
                File(
                  '../scripts/fixtures/python_package_expected.json',
                ).readAsStringSync(),
              )
              as Map;
      const entry = 'pkg://archive/bundle/main.py';
      final result =
          jsonDecode(
                await JsSourceHost.invoke(
                  entry: entry,
                  modules: {
                    entry: File(
                      '../scripts/fixtures/python_package_contract.py',
                    ).readAsStringSync(),
                    for (final item in (fixture['modules'] as Map).entries)
                      Uri.parse(entry).resolve(item.key as String).toString():
                          item.value as String,
                  },
                  pythonPackage: Map<String, Object?>.from(
                    fixture['packageData'] as Map,
                  ),
                  pythonPrelude: await loadPythonSourcePrelude(),
                  method: 'home',
                  arguments: [true],
                ),
              )
              as Map;
      expect(result.keys.toSet(), expected.keys.toSet());
      for (final key in expected.keys) {
        expect(result[key], expected[key], reason: key.toString());
      }
    },
  );

  for (final config in [false, true]) {
    test(
      'Python ${config ? 'configured' : 'standalone'} ZIP reads exact local bytes through playback',
      () async {
        final client = CmsClient();
        for (final title in ['第一份包🎬', '第二份包']) {
          final raw = CmsClient.readSubscriptionFile(
            ZipEncoder().encode(package(title, config: config)),
            'source.zip',
          );
          final imported = await client.resolveConfigInput(
            rawTextInput: raw,
            subscriptionId: title,
          );
          final site = imported.config.sites.single;
          final video = (await client.fetchHome(site)).$2.videos.single;
          expect(video.title, title);
          final detail = await CmsClient().fetchDetail(site, video);
          final play = await CmsClient().resolveEpisodeForPlayback(
            site,
            detail.lines.single.episodes.single,
          );
          expect(play.url, 'https://media.example/movie.mp4');
        }
      },
    );
  }

  test(
    'Python ZIP retains data bytes and normalizes harmless archive prefixes',
    () {
      final input = Archive()
        ..addFile(ArchiveFile.string('./bundle/main.py', 'class Spider: pass'))
        ..addFile(ArchiveFile('./bundle/data.bin', 4, [0, 255, 128, 65]));
      final doc =
          jsonDecode(
                CmsClient.readSubscriptionFile(
                  ZipEncoder().encode(input),
                  'source.zip',
                ),
              )
              as Map;
      final data = doc['sites'][0]['ext']['package'] as Map;
      expect(data['entry'], 'bundle/main.py');
      expect(base64Decode(data['files']['bundle/data.bin']), [0, 255, 128, 65]);
    },
  );

  test(
    'ZIP rejects normalized duplicate paths and Python package file limits',
    () {
      final duplicate = Archive()
        ..addFile(ArchiveFile.string('main.py', 'class Spider: pass'))
        ..addFile(ArchiveFile.string('./main.py', 'class Spider: pass'));
      expect(
        () => CmsClient.readSubscriptionFile(
          ZipEncoder().encode(duplicate),
          'source.zip',
        ),
        throwsFormatException,
      );
      final oversized = package('fixture')
        ..addFile(
          ArchiveFile(
            'large.bin',
            2 * 1024 * 1024 + 1,
            List.filled(2 * 1024 * 1024 + 1, 0),
          ),
        );
      expect(
        () => CmsClient.readSubscriptionFile(
          ZipEncoder().encode(oversized),
          'source.zip',
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('单个文件'),
          ),
        ),
      );
      final many = package('fixture');
      for (var n = 0; n < 256; n++) {
        many.addFile(ArchiveFile.string('data/$n.txt', 'x'));
      }
      expect(
        () => CmsClient.readSubscriptionFile(
          ZipEncoder().encode(many),
          'source.zip',
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('数量'),
          ),
        ),
      );
    },
  );
}
