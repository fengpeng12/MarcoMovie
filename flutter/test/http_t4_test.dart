import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/models.dart';

void main() {
  late HttpServer server;
  late String origin;
  late CmsClient client;
  late List<Map<String, dynamic>> calls;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = 'http://127.0.0.1:${server.port}';
    client = CmsClient();
    calls = [];
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      final params = {...request.uri.queryParameters,
        if (body.isNotEmpty) ...Uri.splitQueryString(body)};
      final call = <String, dynamic>{'path': request.uri.path,
        'method': request.method, 'params': params,
        'auth': request.headers.value('authorization'),
        'cookie': request.headers.value('cookie'),
        'contentType': request.headers.value('content-type')};
      calls.add(call);
      if (request.uri.path.startsWith('/redirect')) {
        request.response.statusCode = request.uri.path == '/redirect307' ? 307 : 303;
        request.response.headers.set('location', '/echo');
      } else if (request.uri.path == '/ext') {
        request.response.write('{"remote":"ready"}');
      } else if (request.uri.path == '/bad') {
        request.response.write('<html>Unavailable</html>');
      } else {
        request.response.write(jsonEncode({
          'class': [{'type_id': '1', 'type_name': '电影'}],
          'page': 3, 'pagecount': 4,
          'list': [{'vod_id': params['ids'] ?? '1', 'vod_name': params['wd'] ?? 'Fixture',
            'vod_play_from': '线路&一', 'vod_play_url': r'全集$opaque$@@/?x=1&y=2'}],
          'parse': 0, 'url': '$origin/media.m3u8',
          'header': {'Referer': 'https://media.invalid/'},
        }));
      }
      await request.response.close();
    });
  });
  tearDown(() => server.close(force: true));
  CmsSite source({String path = '/api.php?token=fixture', String ext = '{"catalogue":"中文"}'}) => CmsSite(
    key: 'fixture', name: 'Local T4', type: 4, api: '$origin$path', ext: ext,
    headers: {'Authorization': 'Fixture token', 'Cookie': 'fixture=yes'},
  );

  test('T4 home uses filter, extension and configured credentials', () async {
    final site = source();
    final (categories, listing) = await client.fetchHome(site);
    expect(site.canBrowse, isTrue);
    expect(categories.single.name, '电影');
    expect(listing.videos.single.lines.single.episodes.single.needsSourceResolution, isTrue);
    expect(calls.single['params'], {'token': 'fixture', 'filter': 'true', 'extend': '{"catalogue":"中文"}'});
    expect(calls.single['auth'], 'Fixture token');
    expect(calls.single['cookie'], 'fixture=yes');
  });

  test('T4 UTF8 URL-safe base64 filters, pagination and sparse metadata', () async {
    final result = await client.fetchCategory(source(), '分类&?', 3,
      filter: const CmsFilter(genreLabel: '剧情&电影', area: '中国', year: '2026'));
    final params = calls.single['params'] as Map;
    expect(params['t'], '分类&?');
    expect(params['pg'], '3');
    expect(jsonDecode(utf8.decode(base64Url.decode(params['ext']))),
      {'class': '剧情&电影', 'area': '中国', 'year': '2026'});
    expect(result.sourceFiltered, isTrue);
    expect(result.videos, hasLength(1));
    expect(result.pageCount, 4);
  });

  test('T4 empty filters encode an object; no parameters are promoted from filters', () async {
    await client.fetchCategory(source(), '1', 1);
    expect(calls.single['params']['ext'], 'e30=');
    expect(calls.single['params']['ac'], 'detail');
  });

  test('T4 search and detail retain opaque IDs and require the source player', () async {
    final site = source();
    final found = await client.fetchSearch(site, '电影 & ?', page: 2);
    expect(calls.last['params']['wd'], '电影 & ?');
    expect(calls.last['params']['quick'], 'false');
    expect(calls.last['params']['pg'], '2');
    expect(calls.last['params'].containsKey('ac'), isFalse);
    final fallback = CmsVideo(id: r'中文$@@/?x=1&y=2', title: found.videos.single.title);
    final video = await client.fetchDetail(site, fallback);
    expect(calls.last['params']['ids'], fallback.id);
    final episode = video.lines.single.episodes.single;
    expect(episode.needsSourceResolution, isTrue);
    final playable = await client.resolveEpisodeForPlayback(site, episode);
    expect(calls.last['params']['play'], r'opaque$@@/?x=1&y=2');
    expect(calls.last['params']['flag'], '线路&一');
    expect(playable.url, '$origin/media.m3u8');
    expect(playable.headers['Referer'], 'https://media.invalid/');
    expect(playable.headers['Authorization'], 'Fixture token');
  });

  test('T4 large extension uses UTF8 form POST', () async {
    final ext = List.filled(1200, '中').join();
    await client.fetchSearch(source(ext: ext), '电影&');
    expect(calls.single['method'], 'POST');
    expect(calls.single['params']['extend'], ext);
    expect(calls.single['params']['wd'], '电影&');
    expect(calls.single['contentType'], startsWith('application/x-www-form-urlencoded'));
  });

  test('T4 remote extension fetched once per source instance', () async {
    final site = source(ext: '$origin/ext');
    await client.fetchHome(site);
    await client.fetchSearch(site, 'x');
    expect(calls.where((call) => call['path'] == '/ext'), hasLength(1));
    expect(calls.last['params']['extend'], '{"remote":"ready"}');
  });

  test('T4 POST 307 preserves form and 303 changes to GET', () async {
    final ext = List.filled(1200, '中').join();
    await client.fetchSearch(source(path: '/redirect307', ext: ext), '电影');
    expect(calls.last['method'], 'POST');
    expect(calls.last['params']['extend'], ext);
    await client.fetchSearch(source(path: '/redirect303', ext: ext), '电影');
    expect(calls.last['method'], 'GET');
    expect(calls.last['params'], isEmpty);
  });

  test('T4 malformed response is an error instead of successful empty results', () async {
    await expectLater(client.fetchHome(source(path: '/bad')), throwsFormatException);
  });
}
