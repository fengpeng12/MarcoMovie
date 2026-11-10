import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'cms_client.dart';
import 'cms_parser.dart';
import 'models.dart';
import 'source_playback.dart';

/// Lifecycle of one offline download.
enum DownloadStatus { queued, downloading, paused, completed, failed }

/// One downloadable episode, persisted across launches.
class DownloadTask {
  final String id;
  final String siteKey;
  final String siteName;
  final String siteApi;
  final int siteType;
  final String videoId;
  final String title;
  final String poster;
  final String lineName;
  final String episodeName;
  final int episodeIndex;
  final String sourceUrl;
  final Map<String, String> headers;
  final CmsSite? sourceSite;
  final int createdAt;
  Uri? _credentialOrigin;
  final Map<String, String> _redirectedUrls = {};
  DownloadStatus status;
  double progress;
  int receivedBytes;
  int totalBytes;
  String filePath;
  String error;
  double speed = 0;

  DownloadTask({
    required this.id,
    required this.siteKey,
    required this.siteName,
    required this.siteApi,
    required this.siteType,
    required this.videoId,
    required this.title,
    required this.poster,
    required this.lineName,
    required this.episodeName,
    required this.episodeIndex,
    required this.sourceUrl,
    required this.headers,
    required this.createdAt,
    this.sourceSite,
    this.status = DownloadStatus.queued,
    this.progress = 0,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.filePath = '',
    this.error = '',
  });

  bool get isActive =>
      status == DownloadStatus.queued || status == DownloadStatus.downloading;

  Map<String, dynamic> toJson() => {
        'id': id,
        'siteKey': siteKey,
        'siteName': siteName,
        'siteApi': siteApi,
        'siteType': siteType,
        'videoId': videoId,
        'title': title,
        'poster': poster,
        'lineName': lineName,
        'episodeName': episodeName,
        'episodeIndex': episodeIndex,
        'sourceUrl': sourceUrl,
        'headers': headers,
        if (sourceSite != null) 'sourceSite': {
          'key': sourceSite!.key, 'originalKey': sourceSite!.originalKey,
          'name': sourceSite!.name, 'type': sourceSite!.type, 'api': sourceSite!.api,
          'playUrl': sourceSite!.playUrl, 'ext': sourceSite!.ext,
          'rawExtension': sourceSite!.rawExtension, 'jar': sourceSite!.jar,
          'spider': sourceSite!.spider, 'headers': sourceSite!.headers,
          'searchable': sourceSite!.searchable, 'group': sourceSite!.group,
          'isPrivate': sourceSite!.isPrivate, 'subscriptionId': sourceSite!.subscriptionId,
        },
        'createdAt': createdAt,
        'status': status.name,
        'progress': progress,
        'receivedBytes': receivedBytes,
        'totalBytes': totalBytes,
        'filePath': filePath,
        'error': error,
      };

  factory DownloadTask.fromJson(Map<String, dynamic> j) {
    final statusName = (j['status'] ?? '').toString();
    var status = DownloadStatus.paused;
    for (final s in DownloadStatus.values) {
      if (s.name == statusName) status = s;
    }
    final rawHeaders = j['headers'];
    final headers = <String, String>{};
    if (rawHeaders is Map) {
      rawHeaders.forEach((k, v) => headers[k.toString()] = v.toString());
    }
    int asInt(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;
    final source = j['sourceSite'];
    final sourceSite = source is Map ? CmsSite(
      key: '${source['key'] ?? ''}', originalKey: source['originalKey'] as String?,
      name: '${source['name'] ?? ''}', type: asInt(source['type']),
      api: '${source['api'] ?? ''}', playUrl: '${source['playUrl'] ?? ''}',
      ext: '${source['ext'] ?? ''}', rawExtension: source['rawExtension'] as String?,
      jar: '${source['jar'] ?? ''}', spider: '${source['spider'] ?? ''}',
      headers: source['headers'] is Map
          ? (source['headers'] as Map).map((k, v) => MapEntry('$k', '$v')) : const {},
      searchable: source['searchable'] != false, group: '${source['group'] ?? '默认分组'}',
      isPrivate: source['isPrivate'] == true, subscriptionId: '${source['subscriptionId'] ?? ''}',
    ) : null;
    return DownloadTask(
      id: (j['id'] ?? '').toString(),
      siteKey: (j['siteKey'] ?? '').toString(),
      siteName: (j['siteName'] ?? '').toString(),
      siteApi: (j['siteApi'] ?? '').toString(),
      siteType: asInt(j['siteType']),
      videoId: (j['videoId'] ?? '').toString(),
      title: (j['title'] ?? '').toString(),
      poster: (j['poster'] ?? '').toString(),
      lineName: (j['lineName'] ?? '').toString(),
      episodeName: (j['episodeName'] ?? '').toString(),
      episodeIndex: asInt(j['episodeIndex']),
      sourceUrl: (j['sourceUrl'] ?? '').toString(),
      headers: headers,
      sourceSite: sourceSite,
      createdAt: asInt(j['createdAt']),
      status: status,
      progress: (j['progress'] is num) ? (j['progress'] as num).toDouble() : 0,
      receivedBytes: asInt(j['receivedBytes']),
      totalBytes: asInt(j['totalBytes']),
      filePath: (j['filePath'] ?? '').toString(),
      error: (j['error'] ?? '').toString(),
    );
  }
}

class _StopSignal implements Exception {
  const _StopSignal();
}

class _DownloadError implements Exception {
  final String message;
  const _DownloadError(this.message);
  @override
  String toString() => message;
}

class _Meter {
  int bytes;
  DateTime time;
  _Meter(this.bytes, this.time);
}

class _HlsSegment {
  final String uri;
  final String? keyMethod;
  final String? keyUri;
  final Uint8List? iv;
  final int sequence;
  const _HlsSegment({
    required this.uri,
    required this.keyMethod,
    required this.keyUri,
    required this.iv,
    required this.sequence,
  });
}

class _HlsPlaylist {
  final List<_HlsSegment> segments;
  final String? mapUri;
  const _HlsPlaylist(this.segments, this.mapUri);
}

/// Offline download manager for iPhone / iPad / Mac / Windows.
///
/// - Direct files (`.mp4` / `.mkv` / ...) stream to disk with HTTP Range resume.
/// - HLS (`.m3u8`) picks the highest-bandwidth variant, downloads segments with
///   bounded parallelism (resumable per segment), decrypts `AES-128`, then merges
///   them into one `.ts` (or fMP4 `.mp4`) playable offline.
class DownloadService extends ChangeNotifier {
  DownloadService._();
  static final DownloadService instance = DownloadService._();

  static const int maxConcurrentTasks = 2;
  static const int segmentConcurrency = 4;
  static const String _defaultUa = 'okhttp/3.15';
  static const int _maxSegmentBytes = 96 * 1024 * 1024;

  final List<DownloadTask> _tasks = [];
  final Set<String> _running = {};
  final Set<String> _stopRequested = {};
  final Set<String> _deleteRequested = {};
  final Map<String, _Meter> _meters = {};
  CmsClient? _client;
  Directory? _root;
  File? _indexFile;
  bool _ready = false;
  Timer? _saveTimer;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 30)
    ..maxConnectionsPerHost = 8
    ..userAgent = null
    ..autoUncompress = false;

  bool get isReady => _ready;
  String get rootPath => _root?.path ?? '';
  bool get canOpenFolder =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  /// Newest first for display.
  List<DownloadTask> get tasks {
    final list = List<DownloadTask>.of(_tasks);
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  int get activeCount => _tasks.where((t) => t.isActive).length;

  Future<void> init(CmsClient client) async {
    _client = client;
    try {
      _root = await _resolveRoot();
      final support = await getApplicationSupportDirectory();
      await support.create(recursive: true);
      _indexFile = File(_join(support.path, 'marco_downloads.json'));
      if (await _indexFile!.exists()) {
        final raw = await _indexFile!.readAsString();
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is! Map) continue;
            final task = DownloadTask.fromJson(Map<String, dynamic>.from(item));
            if (task.id.isEmpty) continue;
            if (task.status == DownloadStatus.downloading) {
              task.status = DownloadStatus.queued;
            }
            if (task.status == DownloadStatus.completed &&
                (task.filePath.isEmpty || !File(task.filePath).existsSync())) {
              task.status = DownloadStatus.failed;
              task.error = '本地文件已被移动或删除';
              task.progress = 0;
            }
            _tasks.add(task);
          }
        }
      }
    } catch (e) {
      debugPrint('DownloadService init: $e');
    }
    _ready = _root != null;
    notifyListeners();
    _pump();
  }

  Future<Directory> _resolveRoot() async {
    Directory? base;
    if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      try {
        base = await getDownloadsDirectory();
        if (base != null) {
          final probe = Directory(_join(base.path, 'Marco Movie'));
          await probe.create(recursive: true);
          return probe;
        }
      } catch (_) {
        base = null;
      }
    }
    base = await getApplicationDocumentsDirectory();
    final dir = Directory(_join(base.path, 'Marco Movie'));
    await dir.create(recursive: true);
    return dir;
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Adds episodes of [line] to the queue; returns how many were (re)queued.
  int enqueue({
    required CmsSite site,
    required CmsVideo video,
    required CmsLine line,
    required List<int> episodeIndexes,
  }) {
    var added = 0;
    for (final idx in episodeIndexes) {
      if (idx < 0 || idx >= line.episodes.length) continue;
      final ep = line.episodes[idx];
      final id = _taskId(site.key, video.id, line.name, idx, ep.url);
      final existing = _byId(id);
      if (existing != null) {
        if (existing.status == DownloadStatus.failed ||
            existing.status == DownloadStatus.paused) {
          existing.status = DownloadStatus.queued;
          existing.error = '';
          added++;
        }
        continue;
      }
      _tasks.add(
        DownloadTask(
          id: id,
          siteKey: site.key,
          siteName: site.name,
          siteApi: site.api,
          siteType: site.type,
          videoId: video.id,
          title: video.title.isEmpty ? '未命名影片' : video.title,
          poster: video.poster,
          lineName: line.name,
          episodeName: ep.name.isEmpty ? '第 ${idx + 1} 集' : ep.name,
          episodeIndex: idx,
          sourceUrl: ep.url,
          headers: Map.of(ep.headers),
          sourceSite: site,
          createdAt: DateTime.now().millisecondsSinceEpoch + added,
        ),
      );
      added++;
    }
    if (added > 0) {
      _scheduleSave(immediate: true);
      notifyListeners();
      _pump();
    }
    return added;
  }

  DownloadTask? taskFor(String siteKey, String videoId, String lineName, int index) {
    for (final t in _tasks) {
      if (t.siteKey == siteKey &&
          t.videoId == videoId &&
          t.lineName == lineName &&
          t.episodeIndex == index) {
        return t;
      }
    }
    return null;
  }

  /// Completed episodes of one video, ordered by episode index (for offline playback).
  List<DownloadTask> completedFor(String siteKey, String videoId) {
    final list = _tasks
        .where((t) =>
            t.siteKey == siteKey &&
            t.videoId == videoId &&
            t.status == DownloadStatus.completed)
        .toList();
    list.sort((a, b) => a.episodeIndex.compareTo(b.episodeIndex));
    return list;
  }

  void pause(String id) {
    final t = _byId(id);
    if (t == null) return;
    if (_running.contains(id)) {
      _stopRequested.add(id);
    } else if (t.status == DownloadStatus.queued) {
      t.status = DownloadStatus.paused;
    }
    _scheduleSave(immediate: true);
    notifyListeners();
  }

  void resume(String id) {
    final t = _byId(id);
    if (t == null) return;
    if (t.status == DownloadStatus.paused || t.status == DownloadStatus.failed) {
      t.status = DownloadStatus.queued;
      t.error = '';
      _scheduleSave(immediate: true);
      notifyListeners();
      _pump();
    }
  }

  void pauseAll() {
    for (final t in _tasks) {
      if (t.isActive) pause(t.id);
    }
  }

  void resumeAll() {
    for (final t in _tasks) {
      if (t.status == DownloadStatus.paused) t.status = DownloadStatus.queued;
    }
    _scheduleSave(immediate: true);
    notifyListeners();
    _pump();
  }

  Future<void> remove(String id) async {
    final t = _byId(id);
    if (t == null) return;
    _tasks.remove(t);
    if (_running.contains(id)) {
      _stopRequested.add(id);
      _deleteRequested.add(id);
    } else {
      await _deleteFiles(t);
    }
    _scheduleSave(immediate: true);
    notifyListeners();
  }

  Future<void> openFolder() async {
    final path = rootPath;
    if (path.isEmpty || !canOpenFolder) return;
    try {
      if (Platform.isWindows) {
        await Process.run('explorer', [path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else {
        await Process.run('xdg-open', [path]);
      }
    } catch (_) {}
  }

  static String formatBytes(num bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 100 || unit == 0 ? 0 : 1)} ${units[unit]}';
  }

  static String statusLabel(DownloadTask t) {
    switch (t.status) {
      case DownloadStatus.queued:
        return '等待中';
      case DownloadStatus.downloading:
        final pct = (t.progress * 100).clamp(0, 100).toStringAsFixed(0);
        final speed = t.speed > 0 ? ' · ${formatBytes(t.speed)}/s' : '';
        return '下载中 $pct%$speed';
      case DownloadStatus.paused:
        return '已暂停 ${(t.progress * 100).clamp(0, 100).toStringAsFixed(0)}%';
      case DownloadStatus.completed:
        return '已完成 · ${formatBytes(t.totalBytes)}';
      case DownloadStatus.failed:
        return t.error.isEmpty ? '下载失败' : '失败：${t.error}';
    }
  }

  // ---------------------------------------------------------------------------
  // Scheduling
  // ---------------------------------------------------------------------------

  DownloadTask? _byId(String id) {
    for (final t in _tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  void _pump() {
    if (!_ready) return;
    for (final t in List<DownloadTask>.of(_tasks)) {
      if (_running.length >= maxConcurrentTasks) break;
      if (t.status == DownloadStatus.queued && !_running.contains(t.id)) {
        _running.add(t.id);
        unawaited(_run(t));
      }
    }
  }

  bool _shouldStop(DownloadTask t) => _stopRequested.contains(t.id);

  Future<void> _run(DownloadTask t) async {
    t.status = DownloadStatus.downloading;
    t.error = '';
    t.speed = 0;
    _meters[t.id] = _Meter(t.receivedBytes, DateTime.now());
    notifyListeners();
    try {
      final client = _client ?? CmsClient();
      final site = t.sourceSite ?? CmsSite(
        key: t.siteKey,
        name: t.siteName,
        type: t.siteType,
        api: t.siteApi,
      );
      // Legacy tasks mixed source credentials into media headers. They may only
      // inherit those credentials within the original source origin.
      final mediaHeaders = t.sourceSite == null
          ? headersForOrigin(t.headers, Uri.tryParse(t.siteApi), Uri.tryParse(t.sourceUrl))
          : t.headers;
      final episode = await client.resolveEpisodeForPlayback(site,
          CmsEpisode(name: t.episodeName, url: t.sourceUrl, headers: mediaHeaders));
      final headers = Map<String, String>.of(episode.headers);
      final url = episode.url.trim();
      t._credentialOrigin = Uri.tryParse(url);
      t._redirectedUrls.clear();
      final lower = url.toLowerCase();
      if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
        throw const _DownloadError('该剧集不是可下载的视频直链');
      }
      final dir = _taskDirectory(t);
      await dir.create(recursive: true);
      final baseName = _join(dir.path, _safeName('${t.episodeName}_${t.lineName}'));
      if (_looksLikeHls(url)) {
        await _downloadHls(t, url, headers, baseName, null);
      } else {
        await _downloadDirect(t, url, headers, baseName);
      }
      if (_shouldStop(t)) {
        t.status = DownloadStatus.paused;
      } else {
        t.status = DownloadStatus.completed;
        t.progress = 1;
      }
    } on _StopSignal {
      t.status = DownloadStatus.paused;
    } catch (e) {
      if (_shouldStop(t)) {
        t.status = DownloadStatus.paused;
      } else {
        t.status = DownloadStatus.failed;
        t.error = _friendlyError(e);
      }
    } finally {
      t.speed = 0;
      _running.remove(t.id);
      _stopRequested.remove(t.id);
      _meters.remove(t.id);
      if (_deleteRequested.remove(t.id)) {
        await _deleteFiles(t);
      }
      _scheduleSave(immediate: true);
      notifyListeners();
      _pump();
    }
  }

  void _onProgress(DownloadTask t) {
    final now = DateTime.now();
    final meter = _meters.putIfAbsent(t.id, () => _Meter(t.receivedBytes, now));
    final elapsed = now.difference(meter.time).inMilliseconds;
    if (elapsed >= 800) {
      t.speed = (t.receivedBytes - meter.bytes) * 1000 / elapsed;
      if (t.speed < 0) t.speed = 0;
      meter.bytes = t.receivedBytes;
      meter.time = now;
    }
    if (now.difference(_lastNotify).inMilliseconds >= 250) {
      _lastNotify = now;
      notifyListeners();
      _scheduleSave();
    }
  }

  void _scheduleSave({bool immediate = false}) {
    if (immediate) {
      _saveTimer?.cancel();
      _saveTimer = null;
      unawaited(_save());
      return;
    }
    _saveTimer ??= Timer(const Duration(seconds: 3), () {
      _saveTimer = null;
      unawaited(_save());
    });
  }

  Future<void> _save() async {
    final file = _indexFile;
    if (file == null) return;
    try {
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(_tasks.map((t) => t.toJson()).toList()));
      await tmp.rename(file.path);
    } catch (_) {}
  }

  Future<void> _deleteFiles(DownloadTask t) async {
    final root = _root;
    if (root == null) return;
    // Keep legacy files still referenced by another task. Never infer ownership
    // of an old partial file from a display name shared by multiple tasks.
    final path = t.filePath;
    if (path.isNotEmpty && _underRoot(path) &&
        !_tasks.any((other) => _normalizedPath(other.filePath) == _normalizedPath(path))) {
      try { final file = File(path); if (await file.exists()) await file.delete(); } catch (_) {}
    }
    final dir = _taskDirectory(t);
    if (_underRoot(dir.path) && !_tasks.any((other) => other.id == t.id)) {
      try { if (await dir.exists()) await dir.delete(recursive: true); } catch (_) {}
    }
  }

  Directory _taskDirectory(DownloadTask t) =>
      Directory(_join(_join(_root!.path, '_tasks'), _safeName(t.id)));

  static String _normalizedPath(String path) {
    if (path.isEmpty) return '';
    final normalized = File(path).absolute.uri.normalizePath().toFilePath()
        .replaceAll('\\', '/');
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  bool _underRoot(String path) =>
      _normalizedPath(path).startsWith('${_normalizedPath(_root!.path)}/');

  // ---------------------------------------------------------------------------
  // Direct file download
  // ---------------------------------------------------------------------------

  Future<void> _downloadDirect(
    DownloadTask t,
    String url,
    Map<String, String> headers,
    String baseName,
  ) async {
    final ext = _extFromUrl(url, fallback: '.mp4');
    final finalFile = File('$baseName$ext');
    final part = File('$baseName$ext.part');
    var existing = await part.exists() ? await part.length() : 0;
    final response = await _open(url, headers, t,
        range: existing > 0 ? 'bytes=$existing-' : null);
    if (response.statusCode == 416 && existing > 0) {
      await response.drain<void>();
      await part.delete();
      return _downloadDirect(t, url, headers, baseName);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.drain<void>();
      throw _DownloadError('服务器返回 HTTP ${response.statusCode}');
    }
    final mime = response.headers.contentType?.mimeType.toLowerCase() ?? '';
    if (mime.contains('text/html')) {
      await response.drain<void>();
      throw const _DownloadError('该地址返回的是网页，无法直接下载');
    }
    final append = response.statusCode == 206 && existing > 0;
    if (append) {
      final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$')
          .firstMatch(response.headers.value(HttpHeaders.contentRangeHeader) ?? '');
      if (match == null || int.parse(match[1]!) != existing) {
        await response.drain<void>();
        throw const _DownloadError('续传范围不匹配，请重新下载');
      }
    }
    if (!append) existing = 0;
    final contentLength = response.contentLength;
    t.totalBytes = contentLength > 0 ? existing + contentLength : 0;
    t.receivedBytes = existing;
    BytesBuilder? playlistBuffer;
    var firstChunk = true;
    final sink = part.openWrite(mode: append ? FileMode.append : FileMode.write);
    try {
      await for (final chunk in response) {
        if (_shouldStop(t)) throw const _StopSignal();
        if (firstChunk) {
          firstChunk = false;
          if (!append && (mime.contains('mpegurl') || _startsWithM3u(chunk))) {
            playlistBuffer = BytesBuilder(copy: false);
          }
        }
        if (playlistBuffer != null) {
          playlistBuffer.add(chunk);
          if (playlistBuffer.length > 8 * 1024 * 1024) {
            throw const _DownloadError('播放列表过大');
          }
          continue;
        }
        sink.add(chunk);
        t.receivedBytes += chunk.length;
        if (t.totalBytes > 0) {
          t.progress = (t.receivedBytes / t.totalBytes).clamp(0.0, 1.0);
        }
        _onProgress(t);
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    if (playlistBuffer != null) {
      try {
        await part.delete();
      } catch (_) {}
      final text = utf8.decode(playlistBuffer.takeBytes(), allowMalformed: true);
      await _downloadHls(t, t._redirectedUrls[url] ?? url, headers, baseName, text);
      return;
    }
    if (t.totalBytes > 0 && t.receivedBytes < t.totalBytes) {
      throw const _DownloadError('连接中断，可点击继续下载');
    }
    if (t.receivedBytes <= 0) {
      throw const _DownloadError('服务器没有返回任何数据');
    }
    if (await finalFile.exists()) await finalFile.delete();
    await part.rename(finalFile.path);
    t.filePath = finalFile.path;
    t.totalBytes = t.receivedBytes;
  }

  // ---------------------------------------------------------------------------
  // HLS download
  // ---------------------------------------------------------------------------

  Future<void> _downloadHls(
    DownloadTask t,
    String url,
    Map<String, String> headers,
    String baseName,
    String? preloaded,
  ) async {
    var playlistUrl = url;
    var text = preloaded ?? await _getText(playlistUrl, headers, t);
    playlistUrl = t._redirectedUrls[playlistUrl] ?? playlistUrl;
    for (var depth = 0; depth < 4 && text.contains('#EXT-X-STREAM-INF'); depth++) {
      final variant = _pickVariant(text, playlistUrl);
      if (variant == null) break;
      playlistUrl = variant;
      text = await _getText(playlistUrl, headers, t);
      playlistUrl = t._redirectedUrls[playlistUrl] ?? playlistUrl;
    }
    if (!text.trimLeft().replaceFirst('\uFEFF', '').startsWith('#EXTM3U')) {
      throw const _DownloadError('不是有效的 m3u8 播放列表');
    }
    final playlist = _parseMediaPlaylist(text, playlistUrl);
    if (playlist.segments.isEmpty) {
      throw const _DownloadError('播放列表中没有视频分片');
    }
    for (final s in playlist.segments) {
      final method = s.keyMethod;
      if (method != null && method != 'NONE' && method != 'AES-128') {
        throw const _DownloadError('该视频使用 SAMPLE-AES 等专有加密，暂不支持下载');
      }
    }
    final ext = playlist.mapUri != null ? '.mp4' : '.ts';
    final finalFile = File('$baseName$ext');
    final segDir = Directory('$baseName.segments');
    await segDir.create(recursive: true);
    final total = playlist.segments.length;
    final segFiles = List<File>.generate(
      total,
      (i) => File(_join(segDir.path, '${i.toString().padLeft(6, '0')}.seg')),
    );
    var done = 0;
    var bytes = 0;
    for (final f in segFiles) {
      if (await f.exists()) {
        done++;
        bytes += await f.length();
      }
    }
    t.receivedBytes = bytes;
    t.progress = done / total * 0.98;
    notifyListeners();

    final keyCache = <String, Uint8List>{};
    var next = 0;
    Object? failure;
    Future<void> worker() async {
      while (failure == null) {
        if (_shouldStop(t)) throw const _StopSignal();
        final i = next++;
        if (i >= total) return;
        final file = segFiles[i];
        if (await file.exists()) continue;
        final seg = playlist.segments[i];
        try {
          var data = await _getBytesRetry(seg.uri, headers, t);
          if (seg.keyMethod == 'AES-128' && seg.keyUri != null) {
            final keyUri = seg.keyUri!;
            var key = keyCache[keyUri];
            if (key == null) {
              key = await _getBytesRetry(keyUri, headers, t);
              keyCache[keyUri] = key;
            }
            if (key.length != 16) {
              throw const _DownloadError('解密密钥格式异常');
            }
            data = _Aes128Cbc(key).decrypt(data, seg.iv ?? _ivFromSequence(seg.sequence));
          }
          final tmp = File('${file.path}.tmp');
          await tmp.writeAsBytes(data);
          await tmp.rename(file.path);
          done++;
          bytes += data.length;
          t.receivedBytes = bytes;
          t.progress = (done / total * 0.98).clamp(0.0, 0.98);
          t.totalBytes = (bytes / done * total).round();
          _onProgress(t);
        } on _StopSignal {
          rethrow;
        } catch (e) {
          failure ??= e;
          return;
        }
      }
    }

    await Future.wait(List.generate(segmentConcurrency, (_) => worker()));
    if (_shouldStop(t)) throw const _StopSignal();
    if (failure != null) throw failure!;

    final out = File('$baseName$ext.part');
    final sink = out.openWrite();
    try {
      final mapUri = playlist.mapUri;
      if (mapUri != null) {
        sink.add(await _getBytesRetry(mapUri, headers, t));
      }
      for (final f in segFiles) {
        if (_shouldStop(t)) throw const _StopSignal();
        await sink.addStream(f.openRead());
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (await finalFile.exists()) await finalFile.delete();
    await out.rename(finalFile.path);
    try {
      await segDir.delete(recursive: true);
    } catch (_) {}
    t.filePath = finalFile.path;
    t.totalBytes = await finalFile.length();
    t.receivedBytes = t.totalBytes;
  }

  String? _pickVariant(String text, String baseUrl) {
    final base = Uri.parse(baseUrl);
    final lines = const LineSplitter().convert(text);
    String? best;
    var bestBandwidth = -1;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (!line.startsWith('#EXT-X-STREAM-INF')) continue;
      final attrs = _parseAttributes(line.substring(line.indexOf(':') + 1));
      final bandwidth = int.tryParse(attrs['BANDWIDTH'] ?? '') ?? 0;
      for (var j = i + 1; j < lines.length; j++) {
        final candidate = lines[j].trim();
        if (candidate.isEmpty || candidate.startsWith('#')) continue;
        if (bandwidth > bestBandwidth) {
          bestBandwidth = bandwidth;
          best = base.resolve(candidate).toString();
        }
        break;
      }
    }
    return best;
  }

  _HlsPlaylist _parseMediaPlaylist(String text, String baseUrl) {
    final base = Uri.parse(baseUrl);
    var sequence = 0;
    String? method;
    String? keyUri;
    Uint8List? iv;
    String? mapUri;
    final segments = <_HlsSegment>[];
    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXT-X-MEDIA-SEQUENCE')) {
        sequence = int.tryParse(line.substring(line.indexOf(':') + 1).trim()) ?? 0;
        continue;
      }
      if (line.startsWith('#EXT-X-KEY')) {
        final attrs = _parseAttributes(line.substring(line.indexOf(':') + 1));
        method = (attrs['METHOD'] ?? 'NONE').toUpperCase();
        final uri = attrs['URI'];
        keyUri = (uri != null && uri.isNotEmpty) ? base.resolve(uri).toString() : null;
        final ivHex = attrs['IV'];
        iv = (ivHex != null && ivHex.isNotEmpty) ? _parseIv(ivHex) : null;
        if (method == 'NONE') {
          keyUri = null;
          iv = null;
        }
        continue;
      }
      if (line.startsWith('#EXT-X-MAP')) {
        final attrs = _parseAttributes(line.substring(line.indexOf(':') + 1));
        final uri = attrs['URI'];
        if (uri != null && uri.isNotEmpty && mapUri == null) {
          mapUri = base.resolve(uri).toString();
        }
        continue;
      }
      if (line.startsWith('#')) continue;
      segments.add(
        _HlsSegment(
          uri: base.resolve(line).toString(),
          keyMethod: method,
          keyUri: keyUri,
          iv: iv,
          sequence: sequence,
        ),
      );
      sequence++;
    }
    return _HlsPlaylist(segments, mapUri);
  }

  static Map<String, String> _parseAttributes(String input) {
    final out = <String, String>{};
    final pattern = RegExp(r'([A-Za-z0-9-]+)=("[^"]*"|[^,]*)');
    for (final m in pattern.allMatches(input)) {
      var value = m.group(2) ?? '';
      if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
        value = value.substring(1, value.length - 1);
      }
      out[m.group(1)!.toUpperCase()] = value.trim();
    }
    return out;
  }

  static Uint8List _parseIv(String hex) {
    var h = hex.trim();
    if (h.startsWith('0x') || h.startsWith('0X')) h = h.substring(2);
    if (h.length > 32) h = h.substring(h.length - 32);
    h = h.padLeft(32, '0');
    final out = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      out[i] = int.tryParse(h.substring(i * 2, i * 2 + 2), radix: 16) ?? 0;
    }
    return out;
  }

  static Uint8List _ivFromSequence(int sequence) {
    final iv = Uint8List(16);
    var value = sequence;
    for (var i = 15; i >= 8 && value > 0; i--) {
      iv[i] = value & 0xFF;
      value = value >> 8;
    }
    return iv;
  }

  // ---------------------------------------------------------------------------
  // HTTP helpers
  // ---------------------------------------------------------------------------

  @visibleForTesting
  static Map<String, String> headersForOrigin(Map<String, String> headers,
      Uri? origin, Uri? target) {
    return SourcePlayback.headersForOrigin(headers, origin, target);
  }

  Future<HttpClientResponse> _open(String url, Map<String, String> headers,
      DownloadTask task, {String? range}) async {
    var target = Uri.parse(url);
    if (task._credentialOrigin?.scheme == 'https' && target.scheme != 'https') {
      throw const _DownloadError('拒绝将安全下载降级为 HTTP');
    }
    var currentHeaders = headersForOrigin(headers, task._credentialOrigin, target);
    for (var hop = 0; hop <= 8; hop++) {
      if (_shouldStop(task)) throw const _StopSignal();
      if (!const {'http', 'https'}.contains(target.scheme)) {
        throw const _DownloadError('不支持的下载地址');
      }
      final request = await _http.getUrl(target);
      request.followRedirects = false;
      _applyHeaders(request, currentHeaders);
      if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
      final response = await request.close().timeout(const Duration(seconds: 30));
      if (!const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
        task._redirectedUrls[url] = target.toString();
        return response;
      }
      final location = response.headers.value(HttpHeaders.locationHeader);
      await response.drain<void>();
      if (location == null) throw const _DownloadError('重定向缺少目标地址');
      final next = target.resolve(location);
      if (target.scheme == 'https' && next.scheme != 'https') {
        throw const _DownloadError('拒绝将安全下载降级为 HTTP');
      }
      currentHeaders = headersForOrigin(currentHeaders, target, next);
      target = next;
    }
    throw const _DownloadError('下载重定向次数过多');
  }

  void _applyHeaders(HttpClientRequest request, Map<String, String> headers) {
    var hasUa = false;
    headers.forEach((k, v) {
      final lower = k.toLowerCase();
      if (lower == 'host' || lower == 'content-length' || lower == 'range') return;
      if (lower == 'user-agent') hasUa = true;
      try {
        request.headers.set(k, v);
      } catch (_) {}
    });
    if (!hasUa) request.headers.set(HttpHeaders.userAgentHeader, _defaultUa);
  }

  Future<Uint8List> _getBytesOnce(String url, Map<String, String> headers, DownloadTask t) async {
    final response = await _open(url, headers, t);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.drain<void>();
      throw _DownloadError('服务器返回 HTTP ${response.statusCode}');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 45))) {
      if (_shouldStop(t)) throw const _StopSignal();
      builder.add(chunk);
      if (builder.length > _maxSegmentBytes) {
        throw const _DownloadError('单个分片过大');
      }
    }
    return builder.takeBytes();
  }

  Future<Uint8List> _getBytesRetry(String url, Map<String, String> headers, DownloadTask t) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (_shouldStop(t)) throw const _StopSignal();
      try {
        return await _getBytesOnce(url, headers, t);
      } on _StopSignal {
        rethrow;
      } catch (e) {
        lastError = e;
        await Future<void>.delayed(Duration(milliseconds: 600 * (attempt + 1)));
      }
    }
    throw lastError ?? const _DownloadError('网络请求失败');
  }

  Future<String> _getText(String url, Map<String, String> headers, DownloadTask t) async {
    final bytes = await _getBytesRetry(url, headers, t);
    return utf8.decode(bytes, allowMalformed: true);
  }

  // ---------------------------------------------------------------------------
  // Misc helpers
  // ---------------------------------------------------------------------------

  static bool _looksLikeHls(String url) {
    final lower = url.toLowerCase();
    final path = lower.split('?').first.split('#').first;
    return path.endsWith('.m3u8') || path.contains('.m3u8') || lower.contains('m3u8?') ||
        lower.contains('type=m3u8') || lower.contains('format=m3u8');
  }

  static bool _startsWithM3u(List<int> chunk) {
    var i = 0;
    if (chunk.length >= 3 && chunk[0] == 0xEF && chunk[1] == 0xBB && chunk[2] == 0xBF) i = 3;
    while (i < chunk.length && (chunk[i] == 0x20 || chunk[i] == 0x0A || chunk[i] == 0x0D || chunk[i] == 0x09)) {
      i++;
    }
    const sig = [0x23, 0x45, 0x58, 0x54, 0x4D, 0x33, 0x55]; // #EXTM3U
    if (chunk.length - i < sig.length) return false;
    for (var k = 0; k < sig.length; k++) {
      if (chunk[i + k] != sig[k]) return false;
    }
    return true;
  }

  static String _extFromUrl(String url, {required String fallback}) {
    final path = url.toLowerCase().split('?').first.split('#').first;
    const known = ['.mp4', '.mkv', '.flv', '.mov', '.m4v', '.webm', '.avi', '.ts'];
    for (final ext in known) {
      if (path.endsWith(ext)) return ext;
    }
    return fallback;
  }

  static String _safeName(String input) {
    var s = input.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_').trim();
    s = s.replaceAll(RegExp(r'\s+'), ' ');
    while (s.endsWith('.')) {
      s = s.substring(0, s.length - 1);
    }
    if (s.length > 80) s = s.substring(0, 80);
    return s.isEmpty ? 'video' : s;
  }

  static String _join(String a, String b) {
    final sep = Platform.pathSeparator;
    if (a.endsWith(sep) || a.endsWith('/')) return '$a$b';
    return '$a$sep$b';
  }

  static String _taskId(String siteKey, String videoId, String line, int idx, String url) {
    final input = '$siteKey|$videoId|$line|$idx|$url';
    var h1 = 0x811C9DC5;
    var h2 = 0x050C5D1F;
    for (final unit in input.codeUnits) {
      h1 = ((h1 ^ unit) * 0x01000193) & 0xFFFFFFFF;
      h2 = ((h2 ^ (unit + 17)) * 0x01000193) & 0xFFFFFFFF;
    }
    return '${h1.toRadixString(16).padLeft(8, '0')}${h2.toRadixString(16).padLeft(8, '0')}';
  }

  static String _friendlyError(Object e) {
    if (e is _DownloadError) return e.message;
    if (e is TimeoutException) return '网络超时，请稍后重试';
    if (e is SocketException) return '网络连接失败';
    if (e is HandshakeException) return '安全连接失败';
    if (e is FileSystemException) return '写入文件失败（空间不足或无权限）';
    final text = e.toString();
    return text.length > 80 ? text.substring(0, 80) : text;
  }
}

/// Table-driven AES-128-CBC decryptor for HLS segments.
class _Aes128Cbc {
  static Uint8List? _inv;
  static Uint8List? _m9;
  static Uint8List? _m11;
  static Uint8List? _m13;
  static Uint8List? _m14;
  final Uint8List _w;

  _Aes128Cbc(Uint8List key) : _w = CmsParser.aesExpandKey(key) {
    _ensureTables();
  }

  static void _ensureTables() {
    if (_inv != null) return;
    _inv = Uint8List.fromList(CmsParser.aesInvSBox);
    _m9 = _table(0x09);
    _m11 = _table(0x0b);
    _m13 = _table(0x0d);
    _m14 = _table(0x0e);
  }

  static Uint8List _table(int factor) {
    final t = Uint8List(256);
    for (var a = 0; a < 256; a++) {
      var p = 0;
      var aa = a;
      var bb = factor;
      for (var i = 0; i < 8; i++) {
        if ((bb & 1) != 0) p ^= aa;
        final hi = aa & 0x80;
        aa = (aa << 1) & 0xFF;
        if (hi != 0) aa ^= 0x1b;
        bb >>= 1;
      }
      t[a] = p;
    }
    return t;
  }

  static void _invShiftSub(Uint8List s, Uint8List tmp, Uint8List inv) {
    for (var i = 0; i < 16; i++) {
      tmp[i] = s[i];
    }
    for (var c = 0; c < 4; c++) {
      for (var r = 0; r < 4; r++) {
        s[r + 4 * c] = inv[tmp[r + 4 * ((c - r) & 3)]];
      }
    }
  }

  void _decryptBlock(Uint8List s, Uint8List tmp) {
    final w = _w;
    final inv = _inv!;
    final m9 = _m9!;
    final m11 = _m11!;
    final m13 = _m13!;
    final m14 = _m14!;
    for (var i = 0; i < 16; i++) {
      s[i] ^= w[160 + i];
    }
    for (var round = 9; round >= 1; round--) {
      _invShiftSub(s, tmp, inv);
      final base = round * 16;
      for (var i = 0; i < 16; i++) {
        s[i] ^= w[base + i];
      }
      for (var c = 0; c < 4; c++) {
        final i = c * 4;
        final s0 = s[i];
        final s1 = s[i + 1];
        final s2 = s[i + 2];
        final s3 = s[i + 3];
        s[i] = m14[s0] ^ m11[s1] ^ m13[s2] ^ m9[s3];
        s[i + 1] = m9[s0] ^ m14[s1] ^ m11[s2] ^ m13[s3];
        s[i + 2] = m13[s0] ^ m9[s1] ^ m14[s2] ^ m11[s3];
        s[i + 3] = m11[s0] ^ m13[s1] ^ m9[s2] ^ m14[s3];
      }
    }
    _invShiftSub(s, tmp, inv);
    for (var i = 0; i < 16; i++) {
      s[i] ^= w[i];
    }
  }

  Uint8List decrypt(Uint8List data, Uint8List iv) {
    final usable = data.length - (data.length % 16);
    if (usable <= 0) return data;
    final out = Uint8List(usable);
    final prev = Uint8List.fromList(iv);
    final block = Uint8List(16);
    final cipher = Uint8List(16);
    final tmp = Uint8List(16);
    for (var off = 0; off < usable; off += 16) {
      for (var i = 0; i < 16; i++) {
        final b = data[off + i];
        cipher[i] = b;
        block[i] = b;
      }
      _decryptBlock(block, tmp);
      for (var i = 0; i < 16; i++) {
        out[off + i] = block[i] ^ prev[i];
        prev[i] = cipher[i];
      }
    }
    final pad = out[usable - 1];
    if (pad >= 1 && pad <= 16) {
      var valid = true;
      for (var i = usable - pad; i < usable; i++) {
        if (out[i] != pad) {
          valid = false;
          break;
        }
      }
      if (valid) return Uint8List.sublistView(out, 0, usable - pad);
    }
    return out;
  }
}
