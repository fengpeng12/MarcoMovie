import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/catpaw_host.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/cms_parser.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  test(
    'ZIP nested rule helpers, native playback proxy and reopen use the full client',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'marco-package-proxy-',
      );
      final node = (await Process.run('node', [
        '-p',
        'process.execPath',
      ])).stdout.toString().trim();
      final host = CatPawHost(
        directory: () async => root,
        executable: node,
        bootstrap: '${Directory.current.path}/assets/catpaw/host.cjs',
      );
      final previous = CatPawHost.instance;
      CatPawHost.instance = host;
      addTearDown(() async {
        CatPawHost.instance = previous;
        await host.close();
        await root.delete(recursive: true);
      });
      final rule = {
        'title': 'ZIP fixture',
        'host': 'https://fixture.invalid',
        'class_name': '电影',
        'class_url': 'films',
        'searchable': 2,
        'url': '/category/fyclass',
        'searchUrl': '/search?wd=**',
        '预处理': 'js:require("./lib/entry.js");',
        '推荐': 'js:VODS=[{vod_id:"one",vod_name:fixtureTitle}];',
        '一级': 'js:VODS=[{vod_id:"one",vod_name:fixtureTitle}];',
        '搜索': 'js:VODS=[{vod_id:"one",vod_name:fixtureTitle}];',
        '二级':
            'js:VOD={vod_name:fixtureTitle,vod_play_from:"线路",vod_play_url:"第一集\$opaque"};',
        'play_parse': true,
        'lazy': 'js:input={parse:0,url:getProxyUrl()+"&kind=playlist"};',
        'proxy_rule':
            'js:input=input.kind==="segment"?[200,"application/octet-stream",[0,1,255,42]]:'
            '[200,"application/vnd.apple.mpegurl",${jsonEncode('#EXTM3U\n#EXTINF:1,\n?do=js&kind=segment\n#EXT-X-ENDLIST\n')}];',
      };
      final files = {
        'config.json': jsonEncode({
          'sites': [
            {
              'key': 'zip',
              'name': 'Local rule',
              'type': 3,
              'api': 'csp_Drpy',
              'ext': './rules/main.js',
            },
          ],
        }),
        'rules/main.js': 'var rule=${jsonEncode(rule)};',
        'rules/lib/entry.js': 'require("./nested/title.js");',
        'rules/lib/nested/title.js': 'globalThis.fixtureTitle="完整本地影片";',
      };
      final archive = Archive();
      for (final entry in files.entries) {
        final bytes = utf8.encode(entry.value);
        archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
      }
      final raw = CmsClient.readSubscriptionFile(
        ZipEncoder().encode(archive),
        'fixture.zip',
      );
      final site = CmsParser.parseConfig(
        raw,
        subscriptionId: 'local-fixture',
      ).sites.single;
      final client = CmsClient(scriptHost: host);
      final home = await client.fetchHome(site);
      expect(home.$2.videos.single.title, '完整本地影片');
      final found = (await client.fetchSearch(site, '影片')).videos.single;
      final detail = await client.fetchDetail(site, found);
      expect(detail.id, found.id);
      final episode = detail.lines.single.episodes.single;
      final play = await client.resolveEpisodeForPlayback(site, episode);
      final http = HttpClient();
      addTearDown(() => http.close(force: true));
      final response = await (await http.getUrl(Uri.parse(play.url))).close();
      final playlist = await utf8.decoder.bind(response).join();
      expect(playlist, startsWith('#EXTM3U'));
      final segment = playlist
          .split('\n')
          .firstWhere((line) => line.startsWith('http'));
      final request = await http.getUrl(Uri.parse(segment));
      request.headers.set('Range', 'bytes=1-2');
      final bytes = await request.close();
      expect(bytes.statusCode, 206);
      expect(
        await bytes.fold<List<int>>([], (out, chunk) => out..addAll(chunk)),
        [1, 255],
      );
      await host.close();
      final reopened = await client.resolveEpisodeForPlayback(site, episode);
      expect(reopened.url, isNot(play.url));
      final again = await (await http.getUrl(Uri.parse(reopened.url))).close();
      expect(await utf8.decoder.bind(again).join(), startsWith('#EXTM3U'));
    },
    timeout: const Timeout(Duration(seconds: 70)),
  );
}
