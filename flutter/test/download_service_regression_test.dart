import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/download_service.dart';
import 'package:marco_movie/core/models.dart';

class ReviewPaths extends PathProviderPlatform {
  final Directory root;
  ReviewPaths(this.root);
  @override
  Future<String?> getDownloadsPath() async => '${root.path}/downloads';
  @override
  Future<String?> getApplicationSupportPath() async => '${root.path}/support';
  @override
  Future<String?> getApplicationDocumentsPath() async =>
      '${root.path}/documents';
}

void main() {
  final service = DownloadService.instance;
  late Directory fixtureRoot;
  late HttpServer server;
  late CmsClient client;
  final observedHeaders = <String, Map<String, String?>>{};
  String media(String path) => 'http://127.0.0.1:${server.port}/$path';
  CmsSite site(String key, {Map<String, String> headers = const {}}) => CmsSite(
      key: key,
      name: key,
      type: 1,
      api: 'http://localhost:${server.port}/cms',
      headers: headers);
  DownloadTask add(CmsSite source, String id, String title, String path) {
    final line = CmsLine(
        name: 'line', episodes: [CmsEpisode(name: 'ep1', url: media(path))]);
    service.enqueue(
        site: source,
        video: CmsVideo(id: id, title: title),
        line: line,
        episodeIndexes: [0]);
    return service.taskFor(source.key, id, line.name, 0)!;
  }

  Future<void> settled(DownloadTask task) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (task.isActive && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (task.isActive) throw StateError('Download did not settle: ${task.id}');
  }

  setUpAll(() async {
    // No binding override: real loopback HTTP, with all disk paths isolated.
    fixtureRoot =
        await Directory.systemTemp.createTemp('marco-download-check-');
    PathProviderPlatform.instance = ReviewPaths(fixtureRoot);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      observedHeaders[request.uri.path] = {
        'authorization': request.headers.value(HttpHeaders.authorizationHeader),
        'cookie': request.headers.value(HttpHeaders.cookieHeader),
        'range': request.headers.value(HttpHeaders.rangeHeader),
        'x-api-key': request.headers.value('x-api-key'),
      };
      if (request.uri.path == '/redirect.m3u8') {
        request.response.statusCode = 302;
        request.response.headers.set(
            'Location', 'http://localhost:${server.port}/nested/list.m3u8');
      } else if (request.uri.path == '/nested/list.m3u8') {
        request.response.headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl');
        request.response
            .write('#EXTM3U\n#EXTINF:1,\nsegment.ts\n#EXT-X-ENDLIST\n');
      } else if (request.uri.path == '/parse') {
        request.response.headers.contentType = ContentType.json;
        request.response
            .write(jsonEncode({'parse': 0, 'url': media('resolved.mp4')}));
      } else if (request.uri.path == '/watch.html') {
        request.response.headers.contentType = ContentType.html;
        request.response.write('<html>fixture player page</html>');
      } else if (request.uri.path == '/range.mp4') {
        request.response.statusCode = 416;
        request.response.headers.set('Content-Range', 'bytes */4');
      } else {
        final content = utf8.encode(
            request.uri.path == '/a.mp4' ? 'FIRST_MEDIA' : 'SECOND_MEDIA');
        request.response.headers.contentType = ContentType('video', 'mp4');
        request.response.contentLength = content.length;
        request.response.add(content);
      }
      await request.response.close();
    });
    client = CmsClient();
    await service.init(client);
    expect(service.isReady, isTrue);
  });

  tearDown(() async {
    for (final task in service.tasks) {
      await service.remove(task.id);
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
  tearDownAll(() async {
    await server.close(force: true);
  });

  test('different source downloads retain independent files', () async {
    final a = add(site('source-a'), 'video-a', 'Same title', 'a.mp4');
    await settled(a);
    expect(a.status, DownloadStatus.completed);
    final initial = await File(a.filePath).readAsString();
    final b = add(site('source-b'), 'video-b', 'Same title', 'b.mp4');
    await settled(b);
    expect(b.status, DownloadStatus.completed);
    final after = await File(a.filePath).readAsString();
    final samePath = a.filePath == b.filePath;
    await service.remove(a.id);
    final survivorExists = await File(b.filePath).exists();
    print(jsonEncode({
      'probe': 'file-collision',
      'distinctTaskIds': a.id != b.id,
      'samePath': samePath,
      'firstContent': initial,
      'firstContentAfterSecond': after,
      'secondFileSurvivesRemovingFirst': survivorExists
    }));
    expect(samePath, isFalse,
        reason:
            'Two independent downloads must not overwrite/delete each other.');
  });

  test('downloads preserve the normal playback credential origin boundary',
      () async {
    final source = site('credential-source', headers: {
      'Authorization': 'Bearer review-fixture-only',
      'Cookie': 'session=review-fixture-only'
    });
    final normal = await client.resolveEpisodeForPlayback(
        source, CmsEpisode(name: 'ep1', url: media('credential.mp4')));
    expect(normal.headers.keys.map((key) => key.toLowerCase()),
        isNot(contains('authorization')));
    final task =
        add(source, 'credential-video', 'Header probe', 'credential.mp4');
    await settled(task);
    expect(task.status, DownloadStatus.completed);
    final received = observedHeaders['/credential.mp4']!;
    print(jsonEncode({
      'probe': 'credential-origin',
      'normalPlaybackHeaders': normal.headers,
      'downloadReceived': received
    }));
    expect(received['authorization'], isNull,
        reason:
            'Source API credentials must not be sent to a different media origin.');
  });

  test(
      'HTTP 416 with a shorter new resource cannot complete an obsolete partial file',
      () async {
    final task =
        add(site('range-source'), 'range-video', 'Range probe', 'range.mp4');
    service.pause(task.id);
    await settled(task);
    final part =
        File('${service.rootPath}/_tasks/${task.id}/ep1_line.mp4.part');
    await part.parent.create(recursive: true);
    await part.writeAsString('OBSOLETE');
    service.resume(task.id);
    await settled(task);
    print(jsonEncode({
      'probe': 'range-416',
      'status': task.status.name,
      'totalBytes': task.totalBytes,
      'serverResourceBytes': 4,
      'receivedRange': observedHeaders['/range.mp4']?['range'],
      'completedContent':
          task.filePath.isEmpty ? '' : await File(task.filePath).readAsString()
    }));
    expect(task.status, isNot(DownloadStatus.completed),
        reason:
            'Server reports a different resource size; restart or report failure.');
  });

  test('downloads retain source parser configuration used by normal playback',
      () async {
    final source = site('parser-source', headers: {
      'Authorization': 'source-only',
      'Cookie': 'source-only',
      'X-API-Key': 'source-only'
    }).copyWith(playUrl: '${media('parse')}?url=');
    final normal = await client.resolveEpisodeForPlayback(
        source, CmsEpisode(name: 'ep1', url: media('watch.html')));
    expect(normal.url, media('resolved.mp4'));
    for (final key in ['authorization', 'cookie', 'x-api-key']) {
      expect(observedHeaders['/parse']![key], isNull);
    }
    final task = add(source, 'parser-video', 'Parser probe', 'watch.html');
    await settled(task);
    print(jsonEncode({
      'probe': 'parser-configuration',
      'normalPlaybackUrl': normal.url,
      'downloadState': task.status.name,
      'downloadError': task.error
    }));
    expect(task.status, DownloadStatus.completed,
        reason: 'The source parser must be retained by the download task.');
    for (final key in ['authorization', 'cookie', 'x-api-key']) {
      expect(observedHeaders['/resolved.mp4']![key], isNull);
    }
  });
  test('same-origin credentials survive but redirected HLS children are scoped',
      () async {
    final source = site('redirect-source');
    final episode =
        CmsEpisode(name: 'ep1', url: media('redirect.m3u8'), headers: {
      'Authorization': 'Bearer review-fixture-only',
      'Cookie': 'session=review-fixture-only'
    });
    const video = CmsVideo(id: 'redirect-video', title: 'Redirect probe');
    service.enqueue(
        site: source,
        video: video,
        line: CmsLine(name: 'line', episodes: [episode]),
        episodeIndexes: [0]);
    final task = service.taskFor(source.key, video.id, 'line', 0)!;
    await settled(task);
    expect(task.status, DownloadStatus.completed, reason: task.error);
    expect(observedHeaders['/redirect.m3u8']!['authorization'],
        'Bearer review-fixture-only');
    expect(observedHeaders['/nested/list.m3u8']!['authorization'], isNull);
    expect(observedHeaders['/nested/segment.ts']!['cookie'], isNull);
  });

  test(
      'persisted tasks retain source parser and source identity separately from media headers',
      () async {
    final source = CmsSite(
        key: 'persisted',
        originalKey: 'origin',
        name: 'fixture',
        type: 3,
        api: 'https://source.test/source.js',
        playUrl: 'https://source.test/parse?url=',
        ext: 'rule',
        rawExtension: 'raw',
        jar: 'plugin',
        spider: 'spider',
        headers: {'Authorization': 'source-only'},
        subscriptionId: 'subscription',
        isPrivate: false);
    final task = DownloadTask(
        id: 'persisted-task',
        siteKey: source.key,
        siteName: source.name,
        siteApi: source.api,
        siteType: source.type,
        videoId: 'video',
        title: 'title',
        poster: '',
        lineName: 'line',
        episodeName: 'ep',
        episodeIndex: 0,
        sourceUrl: 'https://media.test/movie.mp4',
        headers: {'Cookie': 'media-only'},
        createdAt: 0,
        sourceSite: source);
    final restored =
        DownloadTask.fromJson(jsonDecode(jsonEncode(task.toJson())));
    expect(restored.sourceSite!.playUrl, source.playUrl);
    expect(restored.sourceSite!.ext, 'rule');
    expect(restored.sourceSite!.rawExtension, 'raw');
    expect(restored.sourceSite!.pluginReference, 'plugin');
    expect(restored.sourceSite!.subscriptionId, 'subscription');
    expect(restored.sourceSite!.sourceKey, 'origin');
    expect(restored.sourceSite!.headers, {'Authorization': 'source-only'});
    expect(restored.headers, {'Cookie': 'media-only'});
  });
}
