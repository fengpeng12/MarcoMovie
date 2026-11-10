import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/catpaw_host.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/cms_parser.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  test('only declarative rules select the pinned DRPY engine', () {
    expect(CmsParser.looksLikeDrpyRule('let rule = {title:"Demo"};'), isTrue);
    expect(CmsParser.looksLikeDrpyRule('var rule = {}; export default {home(){}};'), isFalse);
    expect(CmsParser.looksLikeDrpyRule('var rule = {}; module.exports = {home(){}};'), isFalse);
    final remoteEngine = CmsParser.parseConfig(jsonEncode({'sites': [
      {'key': 'engine', 'name': 'Engine', 'type': 3, 'api': 'https://fixture.invalid/drpy2.js', 'ext': './rule.js'},
    ]})).sites.single;
    expect(remoteEngine.isDrpySource, isFalse);
    final explicit = CmsParser.parseConfig(jsonEncode({'sites': [
      {'key': 'rule', 'name': 'Rule', 'type': 3, 'api': 'csp_Drpy', 'ext': './rules/main.php'},
    ]}), origin: 'https://fixture.invalid/config/tv.json').sites.single;
    expect(explicit.isDrpySource, isTrue);
    expect(explicit.ext, 'https://fixture.invalid/config/rules/main.php');
  });

  test('rule text, PHP, JSON and ZIP browse/search/detail/play through the actual local engine', () async {
    final directory = await Directory.systemTemp.createTemp('marco-rule-client-');
    final node = (await Process.run('node', ['-p', 'process.execPath'])).stdout.toString().trim();
    final host = CatPawHost(directory: () async => directory, executable: node,
        bootstrap: '${Directory.current.path}/assets/catpaw/host.cjs');
    addTearDown(() async { await host.close(); await directory.delete(recursive: true); });
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final base = 'http://127.0.0.1:${server.port}';
    final ruleObject = {
      'title': '本地规则', 'host': base, 'homeUrl': '/home',
      'url': '/category/fyclass?page=fypage&fyfilter',
      'filter_url': 'area={{fl.area}}',
      'class_name': '电影', 'class_url': 'films',
      'searchable': 2, 'double': false,
      '推荐': '.item;h3&&Text;img&&src;.remark&&Text;a&&href',
      '一级': '.item;h3&&Text;img&&src;.remark&&Text;a&&href',
      'searchUrl': '/search?wd=**&page=fypage', '搜索': '*',
      '二级': 'js:VOD=JSON.parse(request(input));',
      'play_parse': true, 'lazy': 'js:input=JSON.parse(request(input));',
    };
    final rule = 'var rule = ${jsonEncode(ruleObject)};';
    final requests = <String>[];
    server.listen((request) async {
      requests.add(request.uri.path);
      request.response.headers.contentType = ContentType.text;
      if (request.uri.path == '/rules/main.php' || request.uri.path == '/rules/main.js') {
        request.response.write(rule);
      } else if (request.uri.path == '/detail/one') {
        request.response.write(jsonEncode({'vod_id': '$base/detail/one', 'vod_name': '本地影片',
          'vod_play_from': '本地线路', 'vod_play_url': '第一集\$$base/resolve'}));
      } else if (request.uri.path == '/resolve') {
        request.response.write(jsonEncode({'parse': 0,
          'url': ['高清', '$base/stream.mp4', '标清', '$base/stream-low.mp4'],
          'header': {'X-Playback': 'fixture'}}));
      } else if (request.uri.path.startsWith('/stream')) {
        request.response.statusCode = 500; // Resolving a URL must not fetch the media.
      } else {
        request.response.write('<div class="item"><a href="/detail/one"><h3>本地影片</h3>'
            '<img src="/poster.jpg"><span class="remark">2026</span></a></div>');
      }
      await request.response.close();
    });
    final client = CmsClient(scriptHost: host);
    List<int> zip(Map<String, String> files) {
      final archive = Archive();
      files.forEach((name, value) => archive.addFile(ArchiveFile.string(name, value)));
      return ZipEncoder().encode(archive);
    }
    final sources = [
      rule,
      rule.replaceFirst('var rule', 'let rule'),
      '// export default rule; var rule is only a comment\n${rule.replaceFirst('var rule', 'const rule')}',
      jsonEncode({'sites': [{'key': 'json', 'name': 'JSON rule', 'type': 3, 'api': 'csp_Drpy', 'ext': ruleObject}]}),
      jsonEncode({'sites': [{'key': 'remote', 'name': 'Remote rule', 'type': 3, 'api': '$base/rules/main.js'}]}),
      jsonEncode({'sites': [{'key': 'php', 'name': 'PHP rule', 'type': 3, 'api': 'csp_Drpy', 'ext': './rules/main.php'}]}),
      CmsClient.readSubscriptionFile(zip({'index.js': rule}), 'rule.zip'),
      CmsClient.readSubscriptionFile(zip({'config.json': jsonEncode({'sites': [
        {'key': 'zip', 'name': 'ZIP rule', 'type': 3, 'api': 'csp_Drpy', 'ext': './rules/main.js'},
      ]}), 'rules/main.js': rule}), 'config.zip'),
    ];
    for (var i = 0; i < sources.length; i++) {
      final site = CmsParser.parseConfig(sources[i], origin: '$base/config.php',
          subscriptionId: 'fixture-$i').sites.single;
      expect(site.canBrowse, isTrue);
      final home = await client.fetchHome(site);
      expect(home.$1.single.name, '电影');
      expect(home.$2.videos.single.title, '本地影片');
      final found = await client.fetchSearch(site, '本地影片');
      expect(found.videos.single.title, '本地影片');
      final detail = await client.fetchDetail(site, found.videos.single);
      final episode = detail.lines.single.episodes.single;
      expect(episode.isScriptEpisode, isTrue);
      final resolved = await client.resolveEpisodeForPlayback(site, episode);
      expect(resolved.url, '$base/stream.mp4');
      expect(resolved.variants.length, 2);
      expect(resolved.headers['X-Playback'], 'fixture');
    }
    expect(requests.where((path) => path == '/rules/main.js').length, 1);
    expect(requests.where((path) => path == '/rules/main.php').length, 1);
    expect(requests.where((path) => path.startsWith('/stream')), isEmpty);
  }, timeout: const Timeout(Duration(seconds: 90)));
}
