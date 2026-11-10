import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/cms_parser.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  test('UTF-16 Windows playlists and JSON decode in both byte orders', () {
    for (final raw in ['频道,http://media.example/a.m3u8', '{"sites":[]}']) {
      for (final little in [true, false]) {
        final bytes = <int>[
          if (little) ...[255, 254] else ...[254, 255],
        ];
        for (final code in raw.codeUnits) {
          bytes.addAll(
            little ? [code & 255, code >> 8] : [code >> 8, code & 255],
          );
        }
        expect(CmsClient.readSubscriptionFile(bytes, 'export.txt'), raw);
      }
    }
    expect(
      () => CmsClient.readSubscriptionFile([255, 254, 1], 'broken.txt'),
      throwsFormatException,
    );
  });

  test(
    'pasted plain TXT remains a playlist instead of fetching the first stream',
    () async {
      final client = CmsClient(
        client: MockClient(
          (_) async => throw StateError('must not fetch media while importing'),
        ),
      );
      final result = await client.resolveConfigInput(
        rawTextInput:
            '一台,https://media.example/a.m3u8\n二台,https://media.example/b.mp4',
      );
      expect(result.origin, isEmpty);
      final listing = (await client.fetchHome(result.config.sites.single)).$2;
      expect(listing.videos.map((v) => v.title), ['一台', '二台']);
      expect(
        listing.videos.first.lines.single.episodes.single.url,
        'https://media.example/a.m3u8',
      );
    },
  );

  test(
    'PHP playlist resolves relative streams and logos for live and catalogue',
    () async {
      const url = 'https://source.example/channels/list.php?token=sample';
      const raw =
          '#EXTM3U\n#EXTINF:-1 tvg-logo="../logo.png" group-title="新闻",测试台\n../play/live.m3u8';
      final client = CmsClient(
        client: MockClient((request) async {
          expect(request.url.toString(), url);
          return http.Response(
            raw,
            200,
            headers: {'content-type': 'text/plain; charset=utf-8'},
          );
        }),
      );
      final result = await client.resolveConfigInput(urlInput: url);
      final live = await client.fetchLiveGroups(result.config.lives.single);
      expect(
        live.single.channels.single.urls.single,
        'https://source.example/play/live.m3u8',
      );
      expect(
        live.single.channels.single.logo,
        'https://source.example/logo.png',
      );
      final listing = (await client.fetchHome(result.config.sites.single)).$2;
      expect(
        listing.videos.single.lines.single.episodes.single.url,
        'https://source.example/play/live.m3u8',
      );
    },
  );

  test(
    'PHP returns CMS JSON and preserves authentication query during requests',
    () async {
      final client = CmsClient(
        client: MockClient((request) async {
          expect(request.url.path, '/gateway.php');
          expect(request.url.queryParameters['token'], 'sample');
          return http.Response(
            jsonEncode({
              'class': [
                {'type_id': '1', 'type_name': '电影'},
              ],
              'list': [
                {
                  'vod_id': '1',
                  'vod_name': '测试影片',
                  'vod_play_from': '直连',
                  'vod_play_url': '正片\$https://media.example/movie.mp4',
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final result = await client.resolveConfigInput(
        urlInput: 'https://source.example/gateway.php?token=sample&ac=list',
      );
      final site = result.config.sites.single;
      final listing = (await client.fetchHome(site)).$2;
      final detail = await client.fetchDetail(site, listing.videos.single);
      final episode = await client.resolveEpisodeForPlayback(
        site,
        detail.lines.single.episodes.single,
      );
      expect(episode.url, 'https://media.example/movie.mp4');
    },
  );

  test(
    'standalone Python ZIP selects main and executes its sibling dependency',
    () async {
      final archive = Archive()
        ..addFile(
          ArchiveFile.string('bundle/main.py', '''
from helper import title
class Spider:
    def homeContent(self, filter):
        return {"list":[{"vod_id":"1","vod_name":title}]}
'''),
        )
        ..addFile(ArchiveFile.string('bundle/helper.py', 'title = "本地脚本"'));
      final raw = CmsClient.readSubscriptionFile(
        ZipEncoder().encode(archive),
        'local.zip',
      );
      final client = CmsClient();
      final result = await client.resolveConfigInput(rawTextInput: raw);
      expect(
        (await client.fetchHome(
          result.config.sites.single,
        )).$2.videos.single.title,
        '本地脚本',
      );
    },
  );

  test(
    'ambiguous script package fails instead of silently choosing a different source',
    () {
      final archive = Archive()
        ..addFile(ArchiveFile.string('main.py', 'class Spider: pass'))
        ..addFile(ArchiveFile.string('index.js', 'export default {};'));
      expect(
        () => CmsClient.readSubscriptionFile(
          ZipEncoder().encode(archive),
          'ambiguous.zip',
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'CommonJS ZIP uses extensionless helper and JSON data without treating README as playlist',
    () async {
      final archive = Archive()
        ..addFile(
          ArchiveFile.string('main.js', '''
const title = require('./helper');
exports.home = function() { return {list:[{vod_id:'1',vod_name:title}]}; };
'''),
        )
        ..addFile(
          ArchiveFile.string(
            'helper.js',
            "module.exports = require('./config.json').title;",
          ),
        )
        ..addFile(
          ArchiveFile.string(
            'config.json',
            '{"title":"本地 CommonJS","list":["helper data"]}',
          ),
        )
        ..addFile(
          ArchiveFile.string(
            'README.txt',
            'Package instructions, not a channel list.',
          ),
        );
      final raw = CmsClient.readSubscriptionFile(
        ZipEncoder().encode(archive),
        'commonjs.zip',
      );
      final client = CmsClient();
      final result = await client.resolveConfigInput(rawTextInput: raw);
      expect(
        (await client.fetchHome(
          result.config.sites.single,
        )).$2.videos.single.title,
        '本地 CommonJS',
      );
    },
  );

  test(
    'ZIP accepts root site arrays and single-site configs with relative scripts',
    () async {
      final site = {
        'key': 'entry',
        'name': '打包片源',
        'type': 3,
        'api': './spider.js',
      };
      for (final document in [
        site,
        [site],
      ]) {
        final archive = Archive()
          ..addFile(
            ArchiveFile.string('package/config.json', jsonEncode(document)),
          )
          ..addFile(
            ArchiveFile.string(
              'package/spider.js',
              "exports.home = function() {return {list:[{vod_id:'1',vod_name:'打包片源'}]};};",
            ),
          );
        final raw = CmsClient.readSubscriptionFile(
          ZipEncoder().encode(archive),
          'config.zip',
        );
        final client = CmsClient();
        final config = await client.resolveConfigInput(rawTextInput: raw);
        expect(
          (await client.fetchHome(
            config.config.sites.single,
          )).$2.videos.single.title,
          '打包片源',
        );
      }
    },
  );

  test('ZIP expansion budget applies before inspecting candidate contents', () {
    final archive = Archive()
      ..addFile(ArchiveFile.string('a.json', ' ' * (4 * 1024 * 1024)))
      ..addFile(ArchiveFile.string('b.json', ' ' * (4 * 1024 * 1024)));
    expect(
      () => CmsClient.readSubscriptionFile(
        ZipEncoder().encode(archive),
        'oversized.zip',
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('解压后的内容'),
        ),
      ),
    );
  });

  test(
    'relative playlist resolution does not turn error CSV into channels',
    () {
      expect(
        CmsParser.parseLivePlaylist(
          'error,service unavailable',
          origin: 'https://example.test/list.php',
        ),
        isEmpty,
      );
      expect(
        CmsParser.parseLivePlaylist(
          '频道,streams/live.m3u8',
          origin: 'https://example.test/list.php',
        ).single.channels.single.urls.single,
        'https://example.test/streams/live.m3u8',
      );
    },
  );

  test(
    'CommonJS and named exports import as executable sources without claiming DRPY',
    () {
      for (final script in [
        'module.exports = {home: function() {return {};}};',
        'exports.home = function() {return {};};',
        'export async function home() {return {};}',
      ]) {
        final source = CmsParser.parseConfig(script).sites.single;
        expect(source.api, 'csp_LocalScript.js');
        expect(source.isJavaScriptSource, isTrue);
      }
      expect(
        CmsParser.parseConfig('var rule = {title:"fixture"};').sites.single.api,
        'csp_LocalRule.js',
      );
    },
  );
}
