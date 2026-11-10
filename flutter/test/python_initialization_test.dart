import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/js_source_host.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  tearDown(JsSourceHost.closeAll);

  test(
    'Python constructor completes HTTP before init and preserves state for playback',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final origin = 'http://127.0.0.1:${server.port}';
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.write('{"title":"Constructor fixture"}');
        await request.response.close();
      });
      final client = CmsClient();
      final config = await client.resolveConfigInput(
        rawTextInput:
            '''
import requests
from base.spider import Spider as Base
class Spider(Base):
 def __init__(self):
  self.metadata = requests.get('$origin/bootstrap').json()
 def init(self, ext):
  self.metadata['ready'] = True
 def homeContent(self, filter):
  assert self.metadata['ready']
  return {'list':[{'vod_id':'one','vod_name':self.metadata['title']}]}
 def detailContent(self, ids):
  return {'list':[{'vod_id':ids[0],'vod_play_from':'local','vod_play_url':'正片\$episode'}]}
 def playerContent(self, flag, id, vip):
  assert self.metadata['title'] == 'Constructor fixture'
  return {'url':'$origin/media.mp4'}
''',
      );
      final site = config.config.sites.single;
      final video = (await client.fetchHome(site)).$2.videos.single;
      expect(video.title, 'Constructor fixture');
      final detail = await CmsClient().fetchDetail(site, video);
      final play = await CmsClient().resolveEpisodeForPlayback(
        site,
        detail.lines.single.episodes.single,
      );
      expect(play.url, '$origin/media.mp4');
      expect(requests, 1, reason: 'constructor runs once per source session');
    },
  );

  test(
    'Python failed constructor discards its context and permits a clean retry',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final origin = 'http://127.0.0.1:${server.port}';
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.statusCode = requests == 1 ? 503 : 200;
        request.response.write('{}');
        await request.response.close();
      });
      final client = CmsClient();
      final config = await client.resolveConfigInput(
        rawTextInput:
            '''
import requests
class Spider:
 def __init__(self):
  requests.get('$origin/bootstrap').raise_for_status()
 def homeContent(self, filter):
  return {'list':[{'vod_id':'one','vod_name':'Retry ready'}]}
''',
      );
      final site = config.config.sites.single;
      await expectLater(
        client.fetchHome(site),
        throwsA(predicate((e) => e.toString().contains('HTTP 503'))),
      );
      expect(
        (await client.fetchHome(site)).$2.videos.single.title,
        'Retry ready',
      );
      expect(requests, 2);
    },
  );
}
