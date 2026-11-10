import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/catpaw_host.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/cms_parser.dart';
import 'package:marco_movie/core/models.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  test(
    'DRPY delegates opaque filters without removing source results or paging',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'marco-filter-contract-',
      );
      final node = (await Process.run('node', [
        '-p',
        'process.execPath',
      ])).stdout.toString().trim();
      final host = CatPawHost(
        directory: () async => directory,
        executable: node,
        bootstrap: '${Directory.current.path}/assets/catpaw/host.cjs',
      );
      addTearDown(() async {
        await host.close();
        await directory.delete(recursive: true);
      });
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final origin = 'http://127.0.0.1:${server.port}';
      final requests = <Uri>[];
      server.listen((request) async {
        requests.add(request.uri);
        request.response.headers.contentType = ContentType.html;
        if (request.uri.queryParameters['class'] != 'missing') {
          request.response.write(
            '<div class="item"><a href="/detail/one">'
            '<h3>Fixture title</h3><img src="/poster.jpg">'
            '<span class="remark">Full episode</span></a></div>',
          );
        }
        await request.response.close();
      });
      final rule = {
        'title': 'Opaque filter fixture',
        'host': origin,
        'url': '/category/fyclass?page=fypage&fyfilter',
        'filter_url': 'class={{fl.class}}&area={{fl.area}}&year={{fl.year}}',
        'class_name': 'Film',
        'class_url': 'films',
        'limit': 1,
        '一级': '.item;h3&&Text;img&&src;.remark&&Text;a&&href',
      };
      final site = CmsParser.parseConfig(
        'var rule = ${jsonEncode(rule)};',
        origin: '$origin/source.js',
        subscriptionId: 'filter-fixture',
      ).sites.single;
      final client = CmsClient(scriptHost: host);
      final filtered = await client.fetchCategory(
        site,
        'films',
        2,
        filter: const CmsFilter(
          genreLabel: 'dzp',
          area: 'region-7',
          year: 'range-2',
        ),
      );
      expect(filtered.videos.single.title, 'Fixture title');
      expect(filtered.sourceFiltered, isTrue);
      expect(filtered.page, 2);
      expect(filtered.pageCount, greaterThan(1));
      expect(requests.single.queryParameters, {
        'page': '2',
        'class': 'dzp',
        'area': 'region-7',
        'year': 'range-2',
      });

      final empty = await client.fetchCategory(
        site,
        'films',
        1,
        filter: const CmsFilter(genreLabel: 'missing'),
      );
      expect(empty.sourceFiltered, isTrue);
      expect(empty.videos, isEmpty);
      expect(
        requests.length,
        2,
        reason:
            'An empty source result must not trigger an unfiltered fallback',
      );

      final unfiltered = await client.fetchCategory(site, 'films', 1);
      expect(unfiltered.sourceFiltered, isFalse);
      expect(unfiltered.videos, hasLength(1));
      final categoryOnly = await client.fetchCategory(
        site,
        'films',
        1,
        filter: const CmsFilter(categoryId: 'films'),
      );
      expect(categoryOnly.sourceFiltered, isFalse);
    },
  );

  test(
    'JavaScript category preserves explicit empty and paged filtered responses',
    () async {
      final site = CmsParser.parseConfig(r'''
export default { category(tid, page, filter, extend) {
  return JSON.stringify({page: page, pagecount: 13,
    list: extend.class === 'missing' ? [] : [{vod_id:'one',vod_name:'Fixture title'}]});
}};
''', origin: 'https://fixture.invalid/source.js').sites.single;
      final client = CmsClient();
      final filtered = await client.fetchCategory(
        site,
        'films',
        4,
        filter: const CmsFilter(genreLabel: 'dzp'),
      );
      expect(filtered.sourceFiltered, isTrue);
      expect(filtered.videos.single.title, 'Fixture title');
      expect(filtered.page, 4);
      expect(filtered.pageCount, 13);
      final empty = await client.fetchCategory(
        site,
        'films',
        4,
        filter: const CmsFilter(genreLabel: 'missing'),
      );
      expect(empty.sourceFiltered, isTrue);
      expect(empty.videos, isEmpty);
      expect(empty.page, 4);
      expect(empty.pageCount, 13);
    },
  );

  test(
    'local M3U still filters actual metadata instead of marking source delegation',
    () async {
      const playlist = '''
#EXTM3U
#EXTINF:-1 group-title="动作",2026 美国 影片A
https://media.invalid/a.mp4
#EXTINF:-1 group-title="喜剧",2025 日本 影片B
https://media.invalid/b.mp4
''';
      final site = CmsParser.parseConfig(playlist).sites.single;
      expect(site.isM3uVodApi, isTrue);
      final client = CmsClient();
      final filtered = await client.fetchCategory(
        site,
        '',
        1,
        filter: const CmsFilter(genreLabel: '动作', area: '美国', year: '2026'),
      );
      expect(filtered.videos.single.title, '2026 美国 影片A');
      expect(filtered.sourceFiltered, isFalse);
      expect(filtered.page, 1);
      expect(filtered.pageCount, 1);
      final empty = await client.fetchCategory(
        site,
        '',
        1,
        filter: const CmsFilter(genreLabel: 'dzp'),
      );
      expect(empty.videos, isEmpty);
      expect(empty.sourceFiltered, isFalse);
    },
  );
}
