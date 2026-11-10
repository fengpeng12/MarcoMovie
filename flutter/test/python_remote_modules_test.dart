import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/js_source_host.dart';
import 'package:marco_movie/core/python_source_assets.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  tearDown(JsSourceHost.closeAll);

  test(
    'remote Python imports nested packages and later modules in the same source',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final origin = 'http://127.0.0.1:${server.port}';
      final paths = <String>[];
      final credentials = <String?>[];
      final scripts = <String, String>{
        '/scripts/main.py': '''
from helpers import NAME
from base.spider import Spider as Base
class Spider(Base):
 def homeContent(self, filter):
  self.title = NAME
  return {'list':[{'vod_id':'one','vod_name':NAME}]}
 def detailContent(self, ids):
  from later import episode
  assert self.title == NAME
  return {'list':[{'vod_id':ids[0], 'vod_play_from':'local', 'vod_play_url':'正片\$' + episode}]}
 def playerContent(self, flag, id, vip):
  from helpers import NAME
  return {'url':id, 'header':{'X-Fixture':NAME}}
''',
        '/scripts/helpers/__init__.py': 'from .value import NAME',
        '/scripts/helpers/value.py': "NAME = 'remote helper'",
        '/scripts/later.py': "episode = '$origin/media.mp4'",
      };
      server.listen((request) async {
        paths.add(request.uri.path);
        credentials.add(request.headers.value('authorization'));
        final source = scripts[request.uri.path];
        request.response.statusCode = source == null ? 404 : 200;
        request.response.write(source ?? 'missing');
        await request.response.close();
      });
      final client = CmsClient();
      final site = CmsSite(
        key: 'remote',
        name: 'remote',
        type: 3,
        api: '$origin/scripts/main.py',
        headers: {'Authorization': 'Bearer fixture'},
      );
      final video = (await client.fetchHome(site)).$2.videos.single;
      expect(video.title, 'remote helper');
      final detail = await CmsClient().fetchDetail(site, video);
      final play = await CmsClient().resolveEpisodeForPlayback(
        site,
        detail.lines.single.episodes.single,
      );
      expect(play.url, '$origin/media.mp4');
      expect(play.headers['X-Fixture'], video.title);
      expect(credentials, everyElement('Bearer fixture'));
      expect(paths.where((p) => p.endsWith('/value.py')), hasLength(1));
      expect(
        paths,
        containsAll(['/scripts/helpers/__init__.py', '/scripts/later.py']),
      );
    },
  );

  test('missing local Python module never makes a network request', () async {
    const entry = 'pkg://archive/main.py';
    final result = jsonDecode(
      await JsSourceHost.invoke(
        entry: entry,
        modules: {
          entry: '''
class Spider:
 def homeContent(self, filter):
  try: import missing
  except ImportError: return {'missing': True}
  return {'missing':False}
''',
        },
        pythonPrelude: await loadPythonSourcePrelude(),
        method: 'home',
        arguments: [true],
      ),
    );
    expect(result, {'missing': true});
  });

  test(
    'cancelled remote Python import does not retain a late module or session',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final started = Completer<HttpRequest>();
      var respond = false;
      var requests = 0;
      server.listen((request) async {
        requests++;
        if (!respond) {
          if (!started.isCompleted) started.complete(request);
          return;
        }
        request.response.statusCode = request.uri.path.endsWith('__init__.py')
            ? 404
            : 200;
        request.response.write('VALUE = "fresh"');
        await request.response.close();
      });
      final entry = 'http://127.0.0.1:${server.port}/main.py';
      const source =
          'import missing\nclass Spider:\n def homeContent(self, filter): return {"value":missing.VALUE}';
      final abort = Completer<void>();
      final future = JsSourceHost.invoke(
        entry: entry,
        modules: {entry: source},
        pythonPrelude: await loadPythonSourcePrelude(),
        method: 'home',
        arguments: [true],
        cancellation: abort,
        sessionKey: 'cancelled-python-module',
      );
      final failure = expectLater(future, throwsA(anything));
      final first = await started.future.timeout(const Duration(seconds: 10));
      abort.complete();
      await failure.timeout(const Duration(seconds: 3));
      respond = true;
      first.response.write('VALUE = "stale"');
      await first.response.close().catchError((_) {});
      expect(
        await JsSourceHost.callCached(
          sessionKey: 'cancelled-python-module',
          method: 'home',
          arguments: [true],
        ),
        isNull,
      );
      // A failed worker is gone, including its proxy capability. The client
      // loads a new worker after this cache miss; late bytes cannot enter it.
      expect(
        await JsSourceHost.invoke(
          entry: entry,
          modules: {entry: source},
          pythonPrelude: await loadPythonSourcePrelude(),
          method: 'home',
          arguments: [true],
          sessionKey: 'cancelled-python-module',
        ),
        '{"value":"fresh"}',
      );
      expect(requests, greaterThan(1));
    },
  );
}
