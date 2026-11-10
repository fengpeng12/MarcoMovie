import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/wogg_source.dart';

const catalogue = '''<html><title>玩偶共享站</title><body>
<div class="module-item"><div class="module-item-pic">
<a href="/voddetail/42.html" title="原站片名"></a>
<img data-src="/poster.jpg"></div><div class="module-item-text">4K</div>
<div class="module-item-caption"><span>2026</span></div></div>
<div class="page"><a href="/vodshow/3--------8---.html">8</a></div>
</body></html>''';

CmsSite site(
        {String origin = 'https://catalogue.invalid/', String key = 'wogg'}) =>
    CmsSite(
        key: key,
        name: '原始玩偶',
        type: 3,
        api: 'csp_WoGGGuard',
        subscriptionId: 'subscription-one',
        headers: const {
          'Cookie': 'subscription-only',
          'Authorization': 'secret'
        },
        ext: jsonEncode({'siteUrl': origin}));

WoggSource adapter(Future<String> Function(String, Map<String, String>) read,
        {Future<List<CmsEpisode>> Function(String)? listShare}) =>
    WoggSource(
      read: read,
      readBytes: (_, __) async =>
          throw StateError('Explicit origin must not fetch plugin'),
      listShare: listShare ?? (_) async => const [],
    );

void main() {
  test('requires exact WoGG API and original configuration', () {
    expect(WoggSource.supports(site()), isTrue);
    expect(WoggSource.supports(site().copyWith(api: 'csp_WoGG')), isTrue);
    expect(
        WoggSource.supports(site().copyWith(api: 'csp_NotWoGGGuard')), isFalse);
    expect(WoggSource.supports(site().copyWith(ext: '')), isFalse);
    expect(
        WoggSource.supports(site()
            .copyWith(ext: '', spider: 'https://plugin.invalid/source.jar')),
        isTrue);
  });

  test(
      'home keeps original ids and resolves posters without leaking subscription headers',
      () async {
    final requests = <String>[];
    final source = adapter((url, headers) async {
      requests.add(url);
      expect(headers.keys, ['User-Agent']);
      return catalogue;
    });
    final result =
        jsonDecode(await source.invoke(site(), 'home', [false])) as Map;
    expect(requests, ['https://catalogue.invalid/']);
    expect((result['class'] as List).map((x) => x['type_id']),
        ['1', '2', '44', '6', '3', '4', '46', '5']);
    expect(result['list'][0]['vod_id'], '42');
    expect(result['list'][0]['vod_name'], '原站片名');
    expect(
        result['list'][0]['vod_pic'], 'https://catalogue.invalid/poster.jpg');
    expect(result['filters']['1'][0]['key'], '3');
  });

  test('category uses original 12-slot path with encoded filter values',
      () async {
    String? requested;
    final source = adapter((url, _) async {
      requested = url;
      return catalogue;
    });
    final result = jsonDecode(await source.invoke(site(), 'category', [
      '3',
      2,
      true,
      {'1': '中国大陆', '3': '科幻', '11': '2026'},
    ]));
    final rawPath = Uri.parse(requested!).pathSegments.last;
    final slots = rawPath.replaceFirst('.html', '').split('-');
    expect(slots.length, 12);
    expect(slots[0], '3');
    expect(slots[1], '中国大陆');
    expect(slots[3], '科幻');
    expect(slots[8], '2');
    expect(slots[11], '2026');
    expect(result['page'], 2);
    expect(result['pagecount'], 8);
    await expectLater(
        source.invoke(site(), 'category', [
          '3',
          1,
          true,
          {'12': 'x'}
        ]),
        throwsFormatException);
  });

  test('search encodes keyword and does not duplicate unsupported later pages',
      () async {
    final requests = <String>[];
    final source = adapter((url, _) async {
      requests.add(url);
      return '''<html><title>玩偶共享站</title><div class="module-search-item">
      <div class="video-info-header"><h3><a href="/voddetail/8.html">准确标题</a></h3>
      <a class="video-serial">4K</a></div><div class="module-item-pic">
      <img data-src="/8.jpg"></div></div></html>''';
    });
    final result =
        jsonDecode(await source.invoke(site(), 'search', ['剧 & 集', false, 1]));
    expect(Uri.parse(requests.single).queryParameters['wd'], '剧 & 集');
    expect(result['list'][0]['vod_name'], '准确标题');
    final next =
        jsonDecode(await source.invoke(site(), 'search', ['剧 & 集', false, 2]));
    expect(next['list'], isEmpty);
    expect(requests.length, 1);
  });

  test(
      'detail keeps real share lines, episode headers and safe partial warnings',
      () async {
    const detail = '''<html><title>玩偶共享站</title>
    <div class="video-cover"><div class="module-item-pic"><img alt="原片" data-src="/p.jpg"></div></div>
    <div class="video-info-items"><span class="video-info-itemtitle">年代：</span><div class="video-info-item">2026</div></div>
    <div class="module-tab-item downtab-item">优汐<span>1</span></div>
    <div class="module-tab-item downtab-item">嘟嘟<span>1</span></div>
    <div class="module-tab-item downtab-item">夸克<span>1</span></div>
    <div class="module-downlist"><div class="module-row-info"><a data-clipboard-text="https://drive.uc.cn/s/first"></a></div></div>
    <div class="module-downlist"><div class="module-row-info"><a data-clipboard-text="https://pan.baidu.com/s/second?pwd=abc"></a></div></div>
    <div class="module-downlist"><div class="module-row-info"><a data-clipboard-text="https://pan.quark.cn/s/third"></a></div></div>
    </html>''';
    final shares = <String>[];
    final source = adapter((_, __) async => detail, listShare: (url) async {
      shares.add(url);
      if (url.contains('quark')) throw StateError('secret_cookie raw_url');
      return [
        CmsEpisode(
            name: '第1集 4K',
            url: 'mmcloud://uc?id=${shares.length}',
            headers: const {'Referer': 'https://provider.invalid/'})
      ];
    });
    final result = jsonDecode(await source.invoke(site(), 'detail', ['42']));
    final video = result['list'][0];
    expect(video['vod_name'], '原片');
    expect(video['vod_year'], '2026');
    expect(video['lines'].length, 2);
    expect(video['lines'][0]['name'], '优汐 1');
    expect(video['lines'][1]['name'], '嘟嘟 2');
    expect(video['lines'][0]['episodes'][0]['url'], startsWith('mmcloud://'));
    expect(video['lines'][0]['episodes'][0]['headers']['Referer'],
        'https://provider.invalid/');
    expect(video['wogg_share_errors'][0]['line'], '夸克 3');
    expect(jsonEncode(video['wogg_share_errors']),
        isNot(contains('secret_cookie')));
    expect(shares.length, 3);
  });

  test('unavailable original shares never become replacement streams',
      () async {
    final source = adapter(
        (_, __) async => '''<title>玩偶共享站</title><div class="video-info"></div>
    <div class="module-row-info"><a data-clipboard-text="https://drive.uc.cn/s/first"></a></div>''');
    await expectLater(
        source.invoke(site(), 'detail', ['42']), throwsFormatException);
  });

  test(
      'explicit source origins remain isolated and never fail over to another site',
      () async {
    final requests = <String>[];
    final source = adapter((url, _) async {
      requests.add(url);
      return catalogue;
    });
    await source.invoke(site(), 'home', []);
    await source.invoke(site(origin: 'https://another.invalid/'), 'home', []);
    expect(
        requests, ['https://catalogue.invalid/', 'https://another.invalid/']);
    final failed = <String>[];
    final unavailable = adapter((url, _) async {
      failed.add(url);
      return '<title>Unrelated CMS</title>';
    });
    await expectLater(
        unavailable.invoke(site(), 'home', []), throwsFormatException);
    expect(failed, ['https://catalogue.invalid/']);
  });

  test('cancellation after network prevents further parsing or share requests',
      () async {
    final cancel = Completer<void>();
    final source = adapter((_, __) async {
      cancel.complete();
      return catalogue;
    });
    await expectLater(source.invoke(site(), 'home', [], cancellation: cancel),
        throwsFormatException);
  });

  test('unknown plugin bytes fail closed before archive parsing', () {
    expect(() => WoggPluginConfiguration.extract(Uint8List.fromList([1, 2, 3])),
        throwsFormatException);
  });

  test('malformed explicit origin is rejected before a request', () async {
    final source = adapter((_, __) async => throw StateError('Must not fetch'));
    await expectLater(
        source.invoke(site(origin: 'https://user:password@catalogue.invalid/'),
            'home', []),
        throwsFormatException);
  });
}
