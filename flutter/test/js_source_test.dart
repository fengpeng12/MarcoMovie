import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/js_source_host.dart';
import 'package:marco_movie/core/models.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  test('local subscription package resolves a Python sibling module', () async {
    final zip = Archive()
      ..addFile(
        ArchiveFile.string(
          'config.json',
          '{"sites":[{"key":"p","type":3,"api":"./src/movie.py"}]}',
        ),
      )
      ..addFile(
        ArchiveFile.string('src/movie.py', '''
from helper import title
class Spider:
    def homeContent(self, filter):
        return {"list":[{"vod_id":"x", "vod_name":title}]}
'''),
      )
      ..addFile(ArchiveFile.string('src/helper.py', 'title = "包内模块"'));
    final client = CmsClient();
    final raw = CmsClient.readSubscriptionFile(
      ZipEncoder().encode(zip),
      'demo.zip',
    );
    final config = await client.resolveConfigInput(rawTextInput: raw);
    expect(
      (await client.fetchHome(
        config.config.sites.single,
      )).$2.videos.single.title,
      '包内模块',
    );
  });
  test(
    'Python Spider imports base.spider and requests then resolves an episode',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final base = 'http://127.0.0.1:${server.port}';
      server.listen((r) async {
        if (r.uri.path == '/search') {
          expect(r.uri.queryParameters['pg'], '3');
          expect(r.uri.queryParameters['wd'], 'Python source');
        }
        r.response.write(
          '{"list":[{"vod_id":"1","vod_name":"Python source"}]}',
        );
        await r.response.close();
      });
      final client = CmsClient();
      final imported = await client.resolveConfigInput(
        rawTextInput:
            '''
from base.spider import Spider as Base
class Spider(Base):
    def homeContent(self, filter):
        return self.fetch("$base/feed").json()
    def detailContent(self, ids):
        return {"list":[{"vod_id":ids[0], "vod_name":"Python source", "vod_play_from":"A", "vod_play_url":"正片\$42"}]}
    def playerContent(self, flag, id, vip):
        return {"url":"$base/" + id + ".mp4", "header":{"Referer":"$base/"}}
    def searchContent(self, key, quick, pg="1"):
        return self.fetch("$base/search", params={"wd":key, "pg":pg}).json()
''',
      );
      final site = imported.config.sites.single;
      expect(
        (await client.fetchSearch(
          site,
          'Python source',
          page: 3,
        )).videos.single.id,
        '1',
      );
      final listing = (await client.fetchHome(site)).$2;
      final detail = await client.fetchDetail(site, listing.videos.single);
      final play = await client.resolveEpisodeForPlayback(
        site,
        detail.lines.single.episodes.single,
      );
      expect(play.url, '$base/42.mp4');
      expect(play.headers['Referer'], '$base/');
    },
  );
  test(
    'ES module source loads relative helper, searches, resolves opaque id and headers',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final base = 'http://127.0.0.1:${server.port}';
      server.listen((req) async {
        final response = req.response;
        switch (req.uri.path) {
          case '/main.mjs':
            response.write('''
import {title} from './helper.mjs';
export default {
  home(){return {class:[{type_id:"1",type_name:"分类"}],list:[{vod_id:"42",vod_name:title}]}},
  category(t,p){return {page:p,list:[{vod_id:"42",vod_name:title}]}},
  async search(q){const r=await req("$base/find");return JSON.parse(r.content)},
  detail(id){return {list:[{vod_id:id,vod_name:title,vod_play_from:"FLAG",vod_play_url:"正片\\\$opaque"}]}},
  play(flag,id){if(flag!=="FLAG"||id!=="opaque")throw new Error("wrong episode");return {url:"$base/sample.mp4",header:{Referer:"$base/"}}}
};''');
          case '/helper.mjs':
            response.write('export const title="模块影片";');
          case '/find':
            response.write(
              jsonEncode({
                'list': [
                  {'vod_id': '42', 'vod_name': '模块影片'},
                ],
              }),
            );
          default:
            response.statusCode = 404;
        }
        await response.close();
      });
      final site = CmsSite(
        key: 'js',
        name: 'JS',
        type: 3,
        api: '$base/main.mjs',
      );
      final client = CmsClient();
      final (categories, listing) = await client.fetchHome(site);
      expect(categories.single.id, '1');
      expect(listing.videos.single.title, '模块影片');
      expect((await client.fetchCategory(site, '1', 2)).videos.single.id, '42');
      final match = (await client.fetchSearch(site, '模块影片')).videos.single;
      final episode = (await client.fetchDetail(
        site,
        match,
      )).lines.single.episodes.single;
      expect(episode.isScriptEpisode, isTrue);
      final playable = await client.resolveEpisodeForPlayback(site, episode);
      expect(playable.url, '$base/sample.mp4');
      expect(playable.headers['Referer'], '$base/');
    },
  );

  test(
    'non-Error throws retain the source failure and allow a fresh runtime',
    () async {
      const entry = 'pkg://local/source.js';
      for (final thrown in [
        '"fixture_failure"',
        '{reason:"fixture_failure"}',
      ]) {
        await expectLater(
          JsSourceHost.invoke(
            entry: entry,
            modules: {entry: 'throw $thrown; export default {}'},
            method: 'home',
            arguments: [],
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message.toString(),
              'script failure',
              contains('fixture_failure'),
            ),
          ),
        );
      }
      expect(
        await JsSourceHost.invoke(
          entry: entry,
          modules: {entry: 'export default {home(){return {list:[]}}}'},
          method: 'home',
          arguments: [],
        ),
        '{"list":[]}',
      );
    },
  );

  test('one source with an endless loop times out independently', () async {
    const entry = 'pkg://local/source.js';
    await expectLater(
      JsSourceHost.invoke(
        entry: entry,
        modules: {entry: 'export default {home(){while(true){}}}'},
        method: 'home',
        arguments: [],
        budget: const Duration(milliseconds: 300),
      ),
      throwsA(anything),
    );
    final client = CmsClient();
    final config = await client.resolveConfigInput(
      rawTextInput:
          'export default {home(){return {list:[{vod_id:"1",vod_name:"独立源"}]}}}',
    );
    expect(
      (await client.fetchHome(
        config.config.sites.single,
      )).$2.videos.single.title,
      '独立源',
    );
  });
}
