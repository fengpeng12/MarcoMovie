import 'dart:convert';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/models.dart';

const site = CmsSite(
    key: 'original',
    name: '玩偶原源',
    api: 'csp_WoGGGuard',
    type: 3,
    headers: {'Cookie': 'subscription-secret'},
    ext: '{"siteUrl":"https://original.invalid"}');
const page = '''<title>玩偶共享站</title><div class="module-item">
<div class="module-item-pic"><a href="/voddetail/42.html" title="原始剧集"></a>
<img data-src="/poster.jpg"></div></div>''';
const detail = '''<title>玩偶共享站</title><div class="video-info"></div>
<div class="video-cover"><div class="module-item-pic"><img alt="原始剧集" data-src="/poster.jpg"></div></div>
<div class="module-tab-item downtab-item">优汐</div>
<div class="module-tab-item downtab-item">嘟嘟</div>
<div class="module-downlist"><div class="module-row-info"><a data-clipboard-text="https://drive.uc.cn/s/fixture"></a></div></div>
<div class="module-downlist"><div class="module-row-info"><a data-clipboard-text="https://pan.baidu.com/s/1expired"></a></div></div>''';

http.Response jsonResponse(Object value) =>
    http.Response.bytes(utf8.encode(jsonEncode(value)), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'source catalogue to stable share reference to original media remains under original owner',
      () async {
    final requests = <Uri>[];
    var tokenRequests = 0;
    final transport = MockClient((request) async {
      requests.add(request.url);
      expect(request.headers.values, isNot(contains('subscription-secret')));
      if (request.url.host == 'original.invalid') {
        return http.Response.bytes(
            utf8.encode(request.url.path.contains('voddetail') ? detail : page),
            200);
      }
      if (request.url.host == 'pan.baidu.com')
        return http.Response('expired', 404);
      expect(request.url.host, 'pc-api.uc.cn');
      if (request.url.path.endsWith('/token')) {
        tokenRequests++;
        return jsonResponse({
          'status': 200,
          'code': 0,
          'data': {'stoken': 'fresh-$tokenRequests'}
        });
      }
      if (request.url.path.endsWith('/detail')) {
        return jsonResponse({
          'status': 200,
          'code': 0,
          'metadata': {'_total': 1},
          'data': {
            'list': [
              {
                'fid': 'file-one',
                'file_name': 'E01.2160p.HDR.mkv',
                'size': 8589934592,
                'file_type': 1,
                'category': 1,
                'share_fid_token': 'fresh-file-$tokenRequests'
              }
            ]
          }
        });
      }
      expect(request.url.path, '/1/clouddrive/file/download');
      expect(jsonDecode(request.body)['stoken'], 'fresh-2');
      return jsonResponse({
        'status': 200,
        'code': 0,
        'data': [
          {'download_url': 'https://media.invalid/original.mkv'}
        ]
      });
    });
    final client = CmsClient(client: transport);
    final (_, home) = await client.fetchHome(site);
    expect(home.videos.single.id, '42');
    const old = CmsVideo(id: '42', title: '原始剧集', lines: [
      CmsLine(name: '360超清', episodes: [
        CmsEpisode(name: '1', url: 'https://foreign.invalid/movie.m3u8')
      ])
    ]);
    final (owner, video) = await client.playableDetail(site, old, const [site]);
    expect(owner.sourceKey, site.sourceKey);
    expect(video.lines, hasLength(1));
    expect(video.lines.single.name, contains('优汐'));
    final episode = video.lines.single.episodes.single;
    expect(episode.url, startsWith('mmcloud://uc?'));
    expect(episode.needsSourceResolution, isTrue);
    expect(episode.name, 'E01.2160p.HDR.mkv');
    expect(episode.url, isNot(contains('fresh-')));
    expect(video.sourceWarnings.single, contains('嘟嘟'));
    final resolved = await client.resolveEpisodeForPlayback(site, episode);
    expect(resolved.url, 'https://media.invalid/original.mkv');
    expect(resolved.variants.single.name, '原画');
    expect(resolved.headers.keys.map((s) => s.toLowerCase()),
        isNot(contains('cookie')));
    expect(tokenRequests, 2,
        reason: 'Refresh expired share credentials at playback');
    expect(requests.map((u) => u.host).toSet(),
        {'original.invalid', 'pc-api.uc.cn', 'pan.baidu.com'});
    await expectLater(
        client.resolveEpisodeForPlayback(
            site, old.lines.single.episodes.single),
        throwsFormatException);
  });

  test(
      'cloud errors show actionable causes without exposing server credentials',
      () {
    const episode = CmsEpisode(name: '原始文件', url: 'mmcloud://baidu?fid=123');
    expect(
        CmsClient.cloudPlaybackError(
            episode, const FormatException('百度登录已失效，请重新扫码')),
        '百度登录已失效，请重新扫码');
    expect(
        CmsClient.cloudPlaybackError(
            episode, const FormatException('BDUSS=secret')),
        isEmpty);
    expect(
        CmsClient.cloudPlaybackError(
            episode, const FormatException('https://private.invalid/token')),
        isEmpty);
    expect(episode.cloudProvider, 'baidu');
    expect(
        const CmsEpisode(name: '', url: 'mmcloud://user@ali?fid=1')
            .cloudProvider,
        isNull);
  });

  test('cancelling the source operation stops later cloud requests', () async {
    final cancellation = Completer<void>();
    var requests = 0;
    final client = CmsClient(client: MockClient((request) async {
      requests++;
      cancellation.complete();
      return jsonResponse({
        'status': 200,
        'code': 0,
        'data': {'stoken': 'temporary'}
      });
    }));
    const episode = CmsEpisode(
        name: '文件',
        url:
            'mmcloud://uc?share=https%3A%2F%2Fdrive.uc.cn%2Fs%2Ffixture&fid=one');
    await expectLater(
        client.runSourceOperation(
            () => client.resolveEpisodeForPlayback(site, episode),
            cancellation: cancellation),
        throwsA(anything));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(requests, 1);
  });

  test('app category filters map to original WoGG slots', () async {
    Uri? requested;
    final client = CmsClient(client: MockClient((request) async {
      requested = request.url;
      return http.Response.bytes(utf8.encode(page), 200);
    }));
    final result = await client.fetchCategory(site, '1', 2,
        filter: const CmsFilter(genreLabel: '科幻', area: '中国大陆', year: '2026'));
    expect(result.sourceFiltered, isTrue);
    final slots =
        requested!.pathSegments.last.replaceFirst('.html', '').split('-');
    expect(slots[1], '中国大陆');
    expect(slots[3], '科幻');
    expect(slots[8], '2');
    expect(slots[11], '2026');
  });
}
