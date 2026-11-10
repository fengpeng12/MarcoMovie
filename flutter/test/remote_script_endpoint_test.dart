import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/js_source_host.dart';
import 'package:marco_movie/core/models.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  tearDown(JsSourceHost.closeAll);

  for (final python in [true, false]) {
    test(
      '${python ? 'Python' : 'JS'} type-3 endpoints use content across PHP and extensionless subscriptions',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final origin = 'http://127.0.0.1:${server.port}';
        final requests = <String>[];
        server.listen((request) async {
          final path = request.uri.path;
          requests.add(path);
          final name = path.startsWith('/first/') ? 'first' : 'second';
          final endpoint = name == 'first' ? 'gateway.php' : 'endpoint';
          final root = '$origin/$name';
          request.response.headers.contentType = ContentType.text;
          if (path == '/$name/$endpoint') {
            request.response.write(
              python
                  ? '''
from helper import TITLE
class Spider:
 def homeContent(self, filter):
  self.title = TITLE
  return {'list':[{'vod_id':'$name','vod_name':TITLE}]}
 def detailContent(self, ids):
  assert self.title == TITLE
  return {'list':[{'vod_id':ids[0],'vod_play_from':'local','vod_play_url':'正片\$$root/media.mp4'}]}
 def playerContent(self, flag, id, vip): return {'url':id}
'''
                  : '''
const title = require('./helper.js');
const example = `
class Spider:
 def homeContent(self, filter): pass
`;
exports.home = () => ({list:[{vod_id:'$name',vod_name:title}]});
exports.detail = id => ({list:[{vod_id:id,vod_play_from:'local',vod_play_url:'正片\$$root/media.mp4'}]});
exports.play = (flag,id) => ({url:id});
''',
            );
          } else if (path == '/$name/helper.py' && python) {
            request.response.write("TITLE = '$name title'");
          } else if (path == '/$name/helper.js' && !python) {
            request.response.write("module.exports = '$name title';");
          } else {
            request.response.statusCode = 404;
            request.response.write('missing');
          }
          await request.response.close();
        });
        for (final name in ['first', 'second']) {
          final endpoint = name == 'first' ? 'gateway.php' : 'endpoint';
          final client = CmsClient();
          final config = await client.resolveConfigInput(
            rawTextInput: jsonEncode({
              'sites': [
                {
                  'key': name,
                  'name': name,
                  'type': 3,
                  'api': '$origin/$name/$endpoint?source=$name',
                },
              ],
            }),
            subscriptionId: '$name-subscription',
          );
          final site = config.config.sites.single;
          final video = (await client.fetchHome(site)).$2.videos.single;
          expect(video.title, '$name title');
          final detail = await CmsClient().fetchDetail(site, video);
          final play = await CmsClient().resolveEpisodeForPlayback(
            site,
            detail.lines.single.episodes.single,
          );
          expect(play.url, '$origin/$name/media.mp4');
        }
        expect(
          requests,
          containsAll([
            '/first/gateway.php',
            '/second/endpoint',
            '/first/helper.${python ? 'py' : 'js'}',
            '/second/helper.${python ? 'py' : 'js'}',
          ]),
        );
      },
    );
  }

  test(
    'opaque script endpoints reject data responses and do not claim Android JAR support',
    () async {
      final client = CmsClient(
        client: MockClient((_) async => http.Response('{"list":[]}', 200)),
      );
      const site = CmsSite(
        key: 'opaque',
        name: 'opaque',
        type: 3,
        api: 'https://fixture.invalid/gateway.php',
      );
      await expectLater(
        client.fetchHome(site),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('未返回可识别的脚本'),
          ),
        ),
      );
      const jar = CmsSite(
        key: 'binary',
        name: 'binary',
        type: 3,
        api: 'https://fixture.invalid/plugin.jar?version=1',
      );
      expect(jar.isRemoteScriptSource, isFalse);
      expect(jar.canBrowse, isFalse);
    },
  );
}
