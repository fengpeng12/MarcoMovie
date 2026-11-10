import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/js_source_host.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  tearDown(CmsClient.closeScriptSessions);

  test(
    'Python cookies and episode cache survive catalogue, detail and a separate player client',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final base = 'http://127.0.0.1:${server.port}';
      final cookies = <String>[];
      server.listen((request) async {
        if (request.uri.path == '/login') {
          request.response.cookies.add(
            Cookie('session', 'source-fixture')..path = '/',
          );
        } else {
          cookies.add(request.headers.value('cookie') ?? '');
        }
        request.response.write('{}');
        await request.response.close();
      });
      final client = CmsClient();
      final config = await client.resolveConfigInput(
        rawTextInput:
            '''
import requests
class Spider:
    def init(self, extend):
        self.session = requests.Session()
        self.cache = {}
    def homeContent(self, filter):
        self.session.get('$base/login')
        self.cache['selected'] = 'opaque-detail'
        return {'list':[{'vod_id':'opaque-detail','vod_name':'session fixture'}]}
    def detailContent(self, ids):
        assert self.cache['selected'] == ids[0]
        self.session.get('$base/detail')
        self.cache['episode'] = '$base/video.mp4'
        return {'list':[{'vod_id':ids[0], 'vod_name':'session fixture', 'vod_play_from':'local', 'vod_play_url':'play\$opaque-episode'}]}
    def playerContent(self, flag, id, vipFlags):
        assert id == 'opaque-episode'
        self.session.get('$base/play')
        return {'parse':0, 'url':self.cache['episode']}
''',
        subscriptionId: 'python-session-test',
      );
      final site = config.config.sites.single;
      final video = (await client.fetchHome(site)).$2.videos.single;
      // Browsing time must not count against Skulpt's per-operation 8 s limit.
      await Future<void>.delayed(const Duration(milliseconds: 8200));
      final detail = await client.fetchDetail(site, video);
      final playable = await CmsClient().resolveEpisodeForPlayback(
        site,
        detail.lines.single.episodes.single,
      );
      expect(playable.url, '$base/video.mp4');
      expect(cookies, ['session=source-fixture', 'session=source-fixture']);

      // The same bytes and source URL in a second subscription start clean.
      final other = site.copyWith(subscriptionId: 'other-subscription');
      await expectLater(client.fetchDetail(other, video), throwsA(anything));
      final privateSite = site.copyWith(isPrivate: true);
      await expectLater(
        client.fetchDetail(privateSite, video),
        throwsA(anything),
      );
      await client.fetchHome(privateSite);
      await CmsClient.retainScriptSessions([site]); // Lock private space.
      await expectLater(
        client.fetchDetail(privateSite, video),
        throwsA(anything),
      );
      expect((await client.fetchDetail(site, video)).lines, isNotEmpty);
      await CmsClient.retainScriptSessions([]); // Remove subscription.
      await expectLater(client.fetchDetail(site, video), throwsA(anything));
    },
  );

  test(
    'retained JS serializes calls, renews deadlines and resets after interruption',
    () async {
      const entry = 'pkg://session/source.js';
      const script = '''
let count = 0;
export default {
  init(){ count = 10; },
  home(){ return ++count; },
  hang(){ while(true){} }
};
''';
      Future<String> call(String method) => JsSourceHost.invoke(
        entry: entry,
        modules: {entry: script},
        method: method,
        arguments: [],
        sessionKey: 'serial',
        budget: const Duration(milliseconds: 250),
      );
      expect(await call('home'), '11');
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(await Future.wait([call('home'), call('home'), call('home')]), [
        '12',
        '13',
        '14',
      ]);
      await expectLater(
        call('hang').timeout(const Duration(seconds: 3)),
        throwsA(isA<StateError>()),
      );
      expect(await call('home'), '11');
    },
  );

  test(
    'cancelled HTTP releases its context; queued cancellation leaves the active call intact',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final arrived = StreamController<HttpRequest>();
      addTearDown(arrived.close);
      server.listen(arrived.add);
      final requests = StreamIterator(arrived.stream);
      addTearDown(requests.cancel);
      const entry = 'pkg://session/cancel.js';
      final script =
          '''
let count = 0;
export default {
  home(){ return ++count; },
  async wait(){ await req('http://127.0.0.1:${server.port}/slow'); return ++count; }
};
''';
      Future<String> call(String method, [Completer<void>? cancellation]) =>
          JsSourceHost.invoke(
            entry: entry,
            modules: {entry: script},
            method: method,
            arguments: [],
            sessionKey: 'cancel',
            cancellation: cancellation,
          );
      expect(await call('home'), '1');
      final cancel = Completer<void>();
      final waiting = expectLater(
        call('wait', cancel),
        throwsA(isA<StateError>()),
      );
      expect(await requests.moveNext(), isTrue);
      cancel.complete();
      await waiting.timeout(const Duration(seconds: 3));
      expect(await call('home'), '1');

      final active = call('wait');
      expect(await requests.moveNext(), isTrue);
      final queuedCancel = Completer<void>();
      final queued = expectLater(
        call('home', queuedCancel),
        throwsA(isA<StateError>()),
      );
      queuedCancel.complete();
      requests.current.response.write('{}');
      await requests.current.response.close();
      expect(await active, '2');
      await queued;
      expect(await call('home'), '3');
    },
  );

  test(
    'a load started before subscription removal cannot recreate its session',
    () async {
      final generation = JsSourceHost.generation;
      await JsSourceHost.retainSessions({});
      await expectLater(
        JsSourceHost.invoke(
          entry: 'pkg://late/source.js',
          modules: {
            'pkg://late/source.js': 'export default {home(){return 1}}',
          },
          method: 'home',
          arguments: [],
          sessionKey: 'deleted',
          expectedGeneration: generation,
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        await JsSourceHost.callCached(
          sessionKey: 'deleted',
          method: 'home',
          arguments: [],
        ),
        isNull,
      );
    },
  );

  test(
    'closing an active source aborts both its HTTP operation and queued work',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final arrived = Completer<void>();
      server.listen((request) {
        arrived.complete();
      });
      const entry = 'pkg://session/closing.js';
      final script =
          'export default {async home(){await req("http://127.0.0.1:${server.port}/wait");return 1;}}';
      Future<String> call() => JsSourceHost.invoke(
        entry: entry,
        modules: {entry: script},
        method: 'home',
        arguments: [],
        sessionKey: 'closing',
      );
      final active = expectLater(call(), throwsA(isA<StateError>()));
      await arrived.future;
      final queued = expectLater(call(), throwsA(isA<StateError>()));
      await CmsClient.closeScriptSessions().timeout(const Duration(seconds: 3));
      await Future.wait([active, queued]).timeout(const Duration(seconds: 3));
      expect(
        await JsSourceHost.callCached(
          sessionKey: 'closing',
          method: 'home',
          arguments: [],
        ),
        isNull,
      );
    },
  );

  test('background script timers do not mutate the next operation', () async {
    const entry = 'pkg://session/timer.js';
    const script = '''
let value=1;
export default {
  home(){setTimeout(()=>{value=99;},100);return value;},
  detail(){return value;}
};
''';
    expect(
      await JsSourceHost.invoke(
        entry: entry,
        modules: {entry: script},
        method: 'home',
        arguments: [],
        sessionKey: 'timer',
      ),
      '1',
    );
    await Future<void>.delayed(const Duration(milliseconds: 160));
    expect(
      await JsSourceHost.callCached(
        sessionKey: 'timer',
        method: 'detail',
        arguments: [],
      ),
      '1',
    );
  });

  test(
    'a new source waits for a busy pool slot without evicting active requests',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final arrivals = <HttpRequest>[];
      final full = Completer<void>();
      server.listen((request) {
        arrivals.add(request);
        if (arrivals.length == 6) full.complete();
      });
      const entry = 'pkg://pool/source.js';
      final script =
          'export default {async home(){await req("http://127.0.0.1:${server.port}/wait");return 1;}}';
      final active = List.generate(
        6,
        (i) => JsSourceHost.invoke(
          entry: entry,
          modules: {entry: script},
          method: 'home',
          arguments: [],
          sessionKey: 'busy-$i',
        ),
      );
      await full.future;
      bool extraFinished = false;
      final extra =
          JsSourceHost.invoke(
            entry: entry,
            modules: {entry: 'export default {home(){return 7;}}'},
            method: 'home',
            arguments: [],
            sessionKey: 'extra',
          ).then((value) {
            extraFinished = true;
            return value;
          });
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(extraFinished, isFalse);
      arrivals.first.response.write('{}');
      await arrivals.first.response.close();
      expect(await extra.timeout(const Duration(seconds: 3)), '7');
      for (final request in arrivals.skip(1)) {
        request.response.write('{}');
        await request.response.close();
      }
      expect(await Future.wait(active), List.filled(6, '1'));
    },
  );
}
