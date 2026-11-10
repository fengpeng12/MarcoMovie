import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/cms_parser.dart';
import 'package:marco_movie/core/csp_bridge.dart';
import 'package:marco_movie/core/models.dart';

const _wogg = CmsSite(
  key: 'wogg', name: '玩偶哥哥┃4K弹幕', type: 3, api: 'csp_WoGGGuard',
  spider: 'https://plugin-source.invalid/spider.jar',
  ext: '{"Cloud-drive":"https://config.invalid/cloud.json"}',
);
const _staleVideo = CmsVideo(id: '178', title: '测试剧集', lines: [
  CmsLine(name: '360超清', episodes: [
    CmsEpisode(name: '第1集', url: 'https://unrelated.invalid/178.m3u8'),
  ]),
]);

String _detail({String id = '178', bool cloudIds = false}) => jsonEncode({
  'list': [{
    'vod_id': id, 'vod_name': '测试剧集', 'vod_year': '2026',
    'vod_play_from': r'优汐智1$$$嘟嘟无限2',
    'vod_play_url': cloudIds
        ? r'[5.20GB]E01.mkv$uc-original-id$$$[8.40GB]E01.mkv$baidu-original-id'
        : r'[5.20GB]E01.mkv$https://uc-media.invalid/one.mkv$$$[8.40GB]E01.mkv$https://baidu-media.invalid/one.mkv',
  }],
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('WoGGGuard uses its portable adapter without adding foreign backends', () {
    final config = CmsParser.parseConfig(jsonEncode({
      'spider': _wogg.spider,
      'sites': [{
        'key': _wogg.key, 'name': _wogg.name, 'type': 3, 'api': _wogg.api,
        'ext': {'Cloud-drive': 'https://config.invalid/cloud.json'},
      }],
    }));
    expect(config.sites.single.api, 'csp_WoGGGuard');
    expect(config.supportedSites, hasLength(1));
    expect(CspBridge.backendsForSite(config.sites.single), isEmpty);
  });

  test('unsupported cloud sources never map to another provider', () {
    for (final api in ['csp_WoGGGuard', 'csp_S_zpsGuard', 'csp_Ucss', 'csp_Bpanso']) {
      final site = CmsSite(key: api, name: api, type: 3, api: api,
          ext: 'https://html-source.invalid/');
      expect(CspBridge.backendsForSite(site), isEmpty, reason: api);
      expect(site.canBrowse, isFalse, reason: api);
    }
  });

  test('unconfigured WoGG rejects operations before sending requests', () async {
    const source = CmsSite(key: 'wogg', name: '玩偶哥哥', type: 3, api: 'csp_WoGGGuard');
    final requests = <Uri>[];
    final client = CmsClient(client: MockClient((request) async {
      requests.add(request.url);
      return http.Response(_detail(), 200);
    }));
    final unsupported = isA<FormatException>().having(
        (e) => e.message, 'message', contains('原始网盘线路'));
    await expectLater(client.fetchHome(source), throwsA(unsupported));
    await expectLater(client.fetchCategory(source, '1', 1), throwsA(unsupported));
    await expectLater(client.fetchSearch(source, '测试剧集'), throwsA(unsupported));
    await expectLater(client.fetchDetail(source, _staleVideo), throwsA(unsupported));
    await expectLater(client.resolveEpisodeForPlayback(
        source, _staleVideo.lines.single.episodes.single), throwsA(unsupported));
    expect(requests, isEmpty);
  });

  test('unknown plugin cannot revive cached foreign episodes', () async {
    final requests = <Uri>[];
    final client = CmsClient(client: MockClient((request) async {
      requests.add(request.url);
      return http.Response.bytes(utf8.encode(_detail()), 200);
    }));
    await expectLater(client.fetchDetail(_wogg, _staleVideo), throwsFormatException);
    expect(requests.map((uri) => uri.host).toSet(), {'plugin-source.invalid'});
    requests.clear();
    await expectLater(client.resolveEpisodeForPlayback(_wogg,
        _staleVideo.lines.single.episodes.single), throwsFormatException);
    expect(requests, isEmpty);
  });

  test('bridge detail cannot return cached foreign lines for WoGG', () async {
    var requests = 0;
    await expectLater(CspBridge.fetchDetail(_wogg, _staleVideo,
      (url, {headers = const {}, requestTimeout}) async {
        requests++;
        return _detail();
      }), throwsFormatException);
    expect(requests, 0);
  });

  test('configured backend detail preserves its own lines without enrichment', () async {
    const source = CmsSite(key: 'portable', name: '配置接口', type: 3,
        api: 'csp_Portable', ext: 'https://configured.invalid/vod?tenant=one');
    expect(CspBridge.backendsForSite(source).map((e) => e.api),
        ['https://configured.invalid/vod?tenant=one']);
    final requests = <Uri>[];
    final video = await CspBridge.fetchDetail(source, _staleVideo,
      (url, {headers = const {}, requestTimeout}) async {
        requests.add(Uri.parse(url));
        return _detail();
      });
    expect(requests, hasLength(1));
    expect(requests.single.host, 'configured.invalid');
    expect(requests.single.queryParameters,
        {'tenant': 'one', 'ac': 'detail', 'ids': '178'});
    expect(video.lines.map((l) => l.name), ['优汐智1', '嘟嘟无限2']);
    expect(video.lines.first.episodes.single.name, '[5.20GB]E01.mkv');
    expect(video.lines.last.episodes.single.url, 'https://baidu-media.invalid/one.mkv');
  });

  test('an empty configured detail discards stale lines', () async {
    const source = CmsSite(key: 'empty', name: '配置接口', type: 3,
        api: 'csp_Portable', ext: 'https://configured.invalid/vod');
    var requests = 0;
    final video = await CspBridge.fetchDetail(source, _staleVideo,
      (url, {headers = const {}, requestTimeout}) async {
        requests++;
        return '{"list":[]}';
      });
    expect(video.lines, isEmpty);
    expect(video.title, _staleVideo.title);
    expect(requests, 1);
  });

  for (final appV2 in [false, true]) {
    test('configured catalogue and search keep source routing, appV2=$appV2', () async {
      final source = CmsSite(key: 'configured-$appV2', name: '配置接口', type: 3,
          api: 'csp_Portable', ext: appV2
              ? 'https://configured.invalid/api.php/app?tenant=one'
              : 'https://configured.invalid/vod?tenant=one');
      final requests = <Uri>[];
      Future<String> fetch(String url, {Map<String, String> headers = const {},
          Duration? requestTimeout}) async {
        requests.add(Uri.parse(url));
        return _detail();
      }
      await CspBridge.fetchHome(source, fetch);
      await CspBridge.fetchCategory(source, '1', 1, fetch);
      await CspBridge.fetchSearch(source, '测试剧集', 1, fetch);
      expect(requests, hasLength(4));
      expect(requests.every((u) => u.host == 'configured.invalid' &&
          u.queryParameters['tenant'] == 'one'), isTrue);
      if (appV2) {
        expect(requests.map((u) => u.path), [
          '/api.php/app/nav', '/api.php/app/video',
          '/api.php/app/video', '/api.php/app/search',
        ]);
      }
    });
  }

  test('compatible cloud T4 keeps original provider flags and playback IDs', () async {
    const source = CmsSite(key: 'real-wogg-t4', name: '玩偶哥哥', type: 4,
        api: 'https://original-source.invalid/t4');
    final requests = <Uri>[];
    final client = CmsClient(client: MockClient((request) async {
      requests.add(request.url);
      if (request.url.queryParameters.containsKey('play')) {
        expect(request.url.queryParameters['flag'], '嘟嘟无限2');
        expect(request.url.queryParameters['play'], 'baidu-original-id');
        return http.Response(jsonEncode({
          'parse': 0, 'url': 'https://baidu-media.invalid/original.mkv',
          'header': {'Referer': 'https://original-source.invalid/'},
        }), 200);
      }
      return http.Response(_detail(cloudIds: true), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }));
    expect(source.canBrowse, isTrue);
    final video = await client.fetchDetail(source, _staleVideo);
    expect(video.lines.map((l) => l.name), ['优汐智1', '嘟嘟无限2']);
    final resolved = await client.resolveEpisodeForPlayback(
        source, video.lines.last.episodes.single);
    expect(resolved.url, 'https://baidu-media.invalid/original.mkv');
    expect(resolved.headers['Referer'], 'https://original-source.invalid/');
    expect(requests, hasLength(2));
    expect(requests.every((u) => u.host == 'original-source.invalid'), isTrue);
  });

  test('Guard download errors propagate without calling unrelated providers', () async {
    const source = CmsSite(key: 'guard', name: 'Guard', type: 3,
        api: 'csp_Dm84Guard', spider: 'https://plugin-source.invalid/spider.jar');
    final requests = <Uri>[];
    final client = CmsClient(client: MockClient((request) async {
      requests.add(request.url);
      if (request.url.host == 'plugin-source.invalid') {
        return http.Response('missing', 404);
      }
      return http.Response(_detail(), 200);
    }));
    await expectLater(client.fetchDetail(source, _staleVideo), throwsException);
    expect(requests, isNotEmpty);
    expect(requests.every((u) => u.host == 'plugin-source.invalid'), isTrue);
  });

  test('empty cloud detail does not silently select another imported source', () async {
    const source = CmsSite(key: 'one', name: '玩偶哥哥', type: 1,
        api: 'https://one.invalid/vod');
    const other = CmsSite(key: 'two', name: '另一个源', type: 1,
        api: 'https://two.invalid/vod');
    final requests = <Uri>[];
    final client = CmsClient(client: MockClient((request) async {
      requests.add(request.url);
      return http.Response(request.url.host == 'one.invalid' ? '{"list":[]}' : _detail(), 200);
    }));
    final (owner, video) = await client.playableDetail(source,
        const CmsVideo(id: '178', title: '测试剧集'), [other]);
    expect(owner.key, source.key);
    expect(video.lines, isEmpty);
    expect(requests.every((u) => u.host == 'one.invalid'), isTrue);
  });

  test('catalogue matching returns the actual imported owner', () async {
    const catalogue = CmsSite(key: 'douban', name: '豆瓣', type: 3, api: 'csp_DouDou');
    const source = CmsSite(key: 'owner', name: '真实来源', type: 1,
        api: 'https://owner.invalid/vod');
    final requests = <Uri>[];
    final client = CmsClient(client: MockClient((request) async {
      requests.add(request.url);
      return http.Response(_detail(), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }));
    final (owner, video) = await client.playableDetail(
        catalogue, _staleVideo, [source]);
    expect(owner.key, 'owner');
    expect(video.lines.map((l) => l.name), ['优汐智1', '嘟嘟无限2']);
    expect(requests.every((u) => u.host == 'owner.invalid'), isTrue);
  });

  test('cloud configuration shows account cards without fabricated 4K videos', () async {
    const source = CmsSite(key: 'mydrive', name: '我的云盘', type: 3,
        api: 'csp_MyDriveGuard');
    var requests = 0;
    final listing = await CspBridge.fetchCategory(source, 'uc', 1,
      (url, {headers = const {}, requestTimeout}) async {
        requests++;
        return _detail();
      });
    expect(listing.videos.single.id, 'netdisk_qr:uc');
    expect(requests, 0);
  });
}
