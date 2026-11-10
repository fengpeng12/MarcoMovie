import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/csp_bridge.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/wogg_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // Exercise real loopback sockets on the host OS.

  test('unported music and live plugins never select an unrelated built-in provider', () {
    for (final api in ['csp_Music', 'csp_Tingshu', 'csp_Kanqiu',
      'csp_Doubao', 'csp_Livegz', 'csp_AllLive', 'csp_Children']) {
      final site = CmsSite(key: api, name: '儿童音乐直播', type: 3, api: api);
      expect(CspBridge.isBiliSite(site), isFalse, reason: api);
      expect(CspBridge.isTuxiaobeiSite(site), isFalse, reason: api);
      expect(CspBridge.isHuyaSite(site), isFalse, reason: api);
      expect(site.canBrowse, isFalse, reason: api);
    }
  });

  test('desktop sockets keep the configured catalogue and original media owner', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final origin = 'http://127.0.0.1:${server.port}';
    final requests = <Uri>[];
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      requests.add(request.uri);
      if (request.uri.path == '/original.mp4') {
        request.response.add([0, 1, 2, 255]);
      } else {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'class': [{'type_id': '17', 'type_name': 'Original category'}],
          'list': [{
            'vod_id': '42', 'vod_name': 'Original file',
            'vod_play_from': 'Original line',
            'vod_play_url': 'Episode\$$origin/original.mp4',
          }],
        }));
      }
      await request.response.close();
    });
    final site = CmsSite(key: 'desktop-socket', name: 'Original', type: 3,
        api: 'csp_Portable', ext: '$origin/vod?tenant=one');
    final client = CmsClient();
    final (categories, home) = await client.fetchHome(site);
    expect(categories.single.id, '17');
    await client.fetchCategory(site, categories.single.id, 1);
    await client.fetchSearch(site, 'Original file');
    final (owner, detail) = await client.playableDetail(site, home.videos.single, []);
    expect(owner.sourceKey, site.sourceKey);
    expect(detail.id, '42');
    final play = await client.resolveEpisodeForPlayback(site, detail.lines.single.episodes.single);
    expect(play.url, '$origin/original.mp4');
    final response = await http.get(Uri.parse(play.url));
    expect(response.bodyBytes, [0, 1, 2, 255]);
    expect(requests.where((r) => r.path == '/vod'), hasLength(5));
    expect(requests.where((r) => r.path == '/vod')
        .every((r) => r.queryParameters['tenant'] == 'one'), isTrue);
  });

  test('desktop app-v2 detail keeps its configured path and query', () async {
    const site = CmsSite(key: 'app', name: 'Configured', type: 3,
        api: 'csp_Portable', ext: 'https://original.invalid/api.php/app?tenant=one');
    Uri? requested;
    await CspBridge.fetchDetail(site, const CmsVideo(id: '42', title: 'File'),
        (url, {headers = const {}, requestTimeout}) async {
      requested = Uri.parse(url);
      return '{"list":[]}';
    });
    expect(requested!.path, '/api.php/app/video_detail');
    expect(requested!.queryParameters, {'tenant': 'one', 'id': '42'});
  });

  test('empty ordinary source does not trigger automatic same-title substitution', () async {
    const source = CmsSite(key: 'one', name: 'Original', type: 1,
        api: 'https://one.invalid/vod');
    const other = CmsSite(key: 'two', name: 'Unrelated', type: 1,
        api: 'https://two.invalid/vod');
    final requests = <Uri>[];
    final client = CmsClient(client: MockClient((request) async {
      requests.add(request.url);
      return http.Response('{"list":[]}', 200);
    }));
    final (owner, video) = await client.playableDetail(source,
        const CmsVideo(id: '42', title: 'Same title'), [other]);
    expect(owner.sourceKey, 'one');
    expect(video.lines, isEmpty);
    expect(requests.single.host, 'one.invalid');
  });

  test('reviewed Guard cannot play foreign direct media from an old cache', () async {
    const source = CmsSite(key: 'guard', name: 'Guard', type: 3,
        api: 'csp_Dm84Guard', spider: 'https://plugin.invalid/source.jar');
    final client = CmsClient(client: MockClient((request) async {
      fail('Cached foreign media must be rejected without network access');
    }));
    await expectLater(client.resolveEpisodeForPlayback(source,
        const CmsEpisode(name: 'Episode', url: 'https://foreign.invalid/one.mp4')),
        throwsFormatException);
  });

  test('timed-out share reads are cancelled before the next original share', () async {
    const detail = '''<title>玩偶共享站</title><div class="video-info"></div>
<div class="module-row-info"><a data-clipboard-text="https://drive.uc.cn/s/slow"></a></div>
<div class="module-row-info"><a data-clipboard-text="https://drive.uc.cn/s/next"></a></div>''';
    const site = CmsSite(key: 'timeout', name: 'Original', type: 3,
        api: 'csp_WoGGGuard', ext: '{"siteUrl":"https://original.invalid"}');
    Completer<void>? firstAbort;
    final slow = Completer<List<CmsEpisode>>();
    final adapter = WoggSource(
      read: (_, __) async => detail,
      readBytes: (_, __) async => throw StateError('No plugin download expected'),
      listShare: (_) async => throw StateError('Cancellation-aware callback expected'),
      shareTimeout: const Duration(milliseconds: 30),
      listShareWithCancellation: (url, abort) async {
        if (url.endsWith('/slow')) {
          firstAbort = abort;
          return slow.future;
        }
        expect(firstAbort!.isCompleted, isTrue);
        return const [CmsEpisode(name: 'Original file', url: 'mmcloud://uc?fid=next')];
      },
    );
    final result = jsonDecode(await adapter.invoke(site, 'detail', ['42']));
    expect(result['list'][0]['lines'], hasLength(1));
    expect(result['list'][0]['wogg_share_errors'], hasLength(1));
    slow.complete(const []);
  });
}
