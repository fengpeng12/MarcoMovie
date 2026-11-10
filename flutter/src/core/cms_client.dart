import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'cms_parser.dart';
import 'csp_bridge.dart';
import 'js_source_host.dart';
import 'python_source_assets.dart';
import 'emby_library.dart';
import 'checksum_source.dart';
import 'catpaw_host.dart';
import 'drpy_source.dart';
import 'guard_source.dart';
import 'source_playback.dart';
import 'source_verification.dart';
import 'models.dart';
import 'quark_drive.dart';
import 'storage_service.dart';
/// HTTP CMS client with TVBox `okhttp/3.15` User-Agent parity, system certificate validation for third-party
/// CMS hosts, multi-depot (`urls`/`storeHouse`) resolution, and bounded concurrent search.
class CmsClient {
  static const int maxResponseBytes = 6 * 1024 * 1024;
  static const int defaultSearchConcurrency = 6;
  static const String tvBoxUserAgent = 'okhttp/3.15';
  static const String safariUserAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.15';
  static final Object _cancelKey = Object();

  /// Bind a screen-owned operation to its actual CMS/script requests. Leaving
  /// the screen stops the UI wait and cancels supported I/O; a late result is
  /// discarded even for a backend that cannot interrupt its current work.
  Future<T> runSourceOperation<T>(Future<T> Function() operation,
      {required Completer<void> cancellation}) async {
    if (cancellation.isCompleted) throw StateError('片源加载已取消');
    final parent = Zone.current[_cancelKey] as Completer<void>?;
    if (parent?.isCompleted == true) throw StateError('片源加载已取消');
    final abort = Completer<void>();
    final interrupted = Completer<T>();
    void cancel() {
      if (!abort.isCompleted) abort.complete();
      if (!interrupted.isCompleted) interrupted.completeError(StateError('片源加载已取消'));
    }
    final listeners = <StreamSubscription<void>>[
      cancellation.future.asStream().listen((_) => cancel()),
      if (parent != null && !identical(parent, cancellation))
        parent.future.asStream().listen((_) => cancel()),
    ];
    try {
      // Register the error observer before beginning an operation which may
      // synchronously cancel itself or fail to create its backend.
      final work = Future<T>.sync(() => runZoned(operation,
          zoneValues: {_cancelKey: abort}));
      final value = await Future.any([work, interrupted.future]);
      if (abort.isCompleted || cancellation.isCompleted || parent?.isCompleted == true) {
        throw StateError('片源加载已取消');
      }
      return value;
    } finally {
      // Future-backed subscriptions stop delivering synchronously on cancel.
      // Their completion future may belong to another zone; it must not delay
      // a finished screen operation or its loading/error state update.
      for (final listener in listeners) { unawaited(listener.cancel()); }
    }
  }
  final http.Client? _http;
  final Duration timeout;
  final CatPawHost _scriptHost;
  final QuarkDriveClient? _quark;
  final Expando<Future<String>> _t4Extensions = Expando<Future<String>>();
  late final DrpySource _drpy = DrpySource(host: _scriptHost,
      read: (url, headers) => _getText(url, headers: headers));
  late final GuardSource _guard = GuardSource(host: _scriptHost, drpy: _drpy,
      read: (url, headers) => _getBytes(url, headers: headers, byteLimit: GuardSource.maxArtifactBytes));
  CmsClient({
    http.Client? client,
    CatPawHost? scriptHost,
    QuarkDriveClient? quark,
    this.timeout = const Duration(seconds: 15),
  }) : _http = client, _quark = quark, _scriptHost = scriptHost ?? CatPawHost.instance;
  static http.Client _createDefaultClient() {
    final ioHttp = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    return IOClient(ioHttp);
  }
  Map<String, String> _buildHeaders(
    Map<String, String> custom, {
    String defaultUa = tvBoxUserAgent,
  }) {
    final headers = <String, String>{
      'User-Agent': defaultUa,
      'Accept': 'application/json, text/plain, */*',
    };
    custom.forEach((k, v) {
      if (k.toLowerCase() == 'user-agent') {
        headers['User-Agent'] = v;
      } else {
        headers[k] = v;
      }
    });
    return headers;
  }
  Future<Uint8List> _getBytes(
    String url, {
    Map<String, String> headers = const {},
    Duration? requestTimeout,
    String defaultUa = tvBoxUserAgent,
    int byteLimit = maxResponseBytes,
    Map<String, String>? form,
    void Function(Uri, Map<String, String>)? onResponse,
  }) async {
    final normalized = CmsParser.normalizeUrl(url);
    final uri = Uri.parse(normalized);
    final transport = _http ?? _createDefaultClient();
    final abort = Completer<void>();
    void cancel() {
      if (!abort.isCompleted) abort.complete();
      if (_http == null) transport.close();
    }
    final sessionAbort = Zone.current[_cancelKey] as Completer<void>?;
    if (sessionAbort?.isCompleted == true) {
      cancel();
      throw http.RequestAbortedException(uri);
    }
    sessionAbort?.future.then((_) => cancel());
    final deadline = Timer(requestTimeout ?? timeout, cancel);
    try {
      final requestHeaders = _buildHeaders(headers, defaultUa: defaultUa);
      if (uri.userInfo.isNotEmpty &&
          !requestHeaders.keys.any((name) => name.toLowerCase() == 'authorization')) {
        requestHeaders['Authorization'] = 'Basic ${base64Encode(utf8.encode(Uri.decodeComponent(uri.userInfo)))}';
      }
      var current = uri.replace(userInfo: '').removeFragment();
      var requestForm = form;
      late http.StreamedResponse response;
      for (var redirects = 0; ; redirects++) {
        final request = http.AbortableRequest(requestForm == null ? 'GET' : 'POST', current, abortTrigger: abort.future)
          ..followRedirects = false
          ..headers.addAll(requestHeaders);
        if (requestForm != null) {
          request.headers.removeWhere((key, _) => const ['content-type', 'content-length', 'transfer-encoding'].contains(key.toLowerCase()));
          request.bodyFields = requestForm;
        }
        response = await transport.send(request);
        final location = response.headers['location'];
        if (![301, 302, 303, 307, 308].contains(response.statusCode) || location == null) break;
        await response.stream.listen(null).cancel();
        if (redirects >= 5) throw const FormatException('来源跳转次数过多');
        final next = Uri.parse(CmsParser.normalizeUrl(current.resolve(location).toString())).removeFragment();
        if (!['http', 'https'].contains(next.scheme) || next.host.isEmpty || next.userInfo.isNotEmpty) {
          throw const FormatException('来源返回了不支持的跳转地址');
        }
        if (current.scheme != next.scheme || current.host != next.host || current.port != next.port) {
          requestHeaders.removeWhere((name, _) => const [
            'authorization', 'proxy-authorization', 'cookie', 'cookie2',
          ].contains(name.toLowerCase()));
        }
        current = next;
        if ([301, 302, 303].contains(response.statusCode)) requestForm = null;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      if ((response.contentLength ?? 0) > byteLimit) {
        throw FormatException('响应体超过大小上限（${byteLimit ~/ (1024 * 1024)} MB）');
      }
      final data = BytesBuilder(copy: false);
      await for (final bytes in response.stream) {
        if (data.length + bytes.length > byteLimit) {
          throw FormatException('响应体超过大小上限（${byteLimit ~/ (1024 * 1024)} MB）');
        }
        data.add(bytes);
      }
      onResponse?.call(current, Map<String, String>.of(requestHeaders));
      return data.takeBytes();
    } finally {
      deadline.cancel();
      cancel();
    }
  }

  Future<String> _getText(
    String url, {
    Map<String, String> headers = const {},
    Duration? requestTimeout,
    Map<String, String>? form,
  }) async {
    if (CatPawHost.matches(url)) return CatPawHost.instance.read(url);
    final bytes = await _getBytes(
      url,
      headers: headers,
      requestTimeout: requestTimeout,
      defaultUa: tvBoxUserAgent,
      form: form,
    );
    return CmsParser.decodeTextDocument(bytes);
  }
  Uri _appendQuery(
    String baseUrl,
    Map<String, String> params, {
    String ext = '',
  }) {
    final normalized = CmsParser.normalizeUrl(baseUrl);
    final base = Uri.parse(normalized);
    final merged = <String, String>{...base.queryParameters};
    if (ext.isNotEmpty && !merged.containsKey('extend')) {
      merged['extend'] = ext;
    }
    merged.addAll(params);
    return base.replace(queryParameters: merged);
  }
  bool _isHttpT4(CmsSite site) => site.type == 4 && site.isHttpApi;

  Future<String> _t4Extension(CmsSite site) async {
    final existing = _t4Extensions[site];
    if (existing != null) return existing;
    Future<String> load() async {
      final value = site.ext.trim();
      final uri = Uri.tryParse(value);
      if (uri == null || !['http', 'https'].contains(uri.scheme) || uri.host.isEmpty) return value;
      final api = Uri.parse(site.api);
      final same = api.scheme == uri.scheme && api.host == uri.host && api.port == uri.port;
      final headers = Map<String, String>.of(site.headers);
      if (!same) headers.removeWhere((key, _) => const [
        'authorization', 'proxy-authorization', 'cookie', 'cookie2',
      ].contains(key.toLowerCase()));
      return (await _getText(value, headers: headers)).trim();
    }
    final pending = load();
    _t4Extensions[site] = pending;
    try { return await pending; }
    catch (_) { if (identical(_t4Extensions[site], pending)) _t4Extensions[site] = null; rethrow; }
  }

  Future<String> _callT4(CmsSite site, Map<String, String> params) async {
    final extension = await _t4Extension(site);
    final values = {...params, if (extension.isNotEmpty) 'extend': extension};
    final raw = await _getText(extension.length > 1000 ? site.api : _appendQuery(site.api, values).toString(),
      headers: site.headers, form: extension.length > 1000 ? values : null);
    if (jsonDecode(raw) is! Map) throw const FormatException('T4 来源没有返回有效的数据');
    return raw;
  }
  static String _archivePath(String name) {
    final path = name.replaceAll('\\', '/');
    if (path.startsWith('/') || path.contains(':') ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(path) || path.split('/').contains('..')) {
      throw const FormatException('ZIP 路径无效');
    }
    final normalized = path.split('/').where((part) => part.isNotEmpty && part != '.').join('/');
    if (normalized.isEmpty) throw const FormatException('ZIP 路径无效');
    return normalized;
  }

  static Map<String, Object> _pythonPackageData(Map<String, ArchiveFile> files, String entry) {
    if (files.length > 256) throw const FormatException('Python 本地包文件数量超过 256');
    final data = <String, String>{};
    var total = 0;
    for (final item in files.entries) {
      if (item.key.contains("'") || item.key.contains('"')) {
        throw const FormatException('Python 本地包路径不能包含引号');
      }
      if (item.value.size > 2 * 1024 * 1024) {
        throw const FormatException('Python 本地包单个文件超过 2 MB');
      }
      total += item.value.size;
      if (total > maxResponseBytes) throw const FormatException('Python 本地包内容超过 6 MB');
      data[item.key] = base64Encode(item.value.content);
    }
    return {'entry': entry, 'files': data};
  }

  static String readSubscriptionFile(List<int> bytes, String name) {
    if (bytes.length > maxResponseBytes) throw const FormatException('订阅文件超过 6 MB');
    if (bytes.length >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4b && bytes[2] == 3 && bytes[3] == 4) {
      final archive = ZipDecoder().decodeBytes(bytes);
      if (archive.files.length > 2048) throw const FormatException('ZIP 文件数量超过限制');
      final files = <String, ArchiveFile>{};
      var unpackedSize = 0;
      for (final item in archive.files.where((f) => f.isFile)) {
        // Check before any .content access: archive entries decompress lazily.
        unpackedSize += item.size;
        if (item.size < 0 || unpackedSize > maxResponseBytes) {
          throw const FormatException('ZIP 解压后的内容超过 6 MB');
        }
        final path = _archivePath(item.name);
        if (files.containsKey(path)) {
          throw const FormatException('ZIP 路径无效或重复');
        }
        files[path] = item;
      }
      final configs = files.values.where((f) {
        if (!f.name.toLowerCase().endsWith('.json')) return false;
        if (f.size > maxResponseBytes) return false;
        try {
          final doc = jsonDecode(CmsParser.stripJsonComments(CmsParser.decodeConfigDocument(f.content)));
          bool site(dynamic value) => value is Map && value['api'] is String &&
              (value['name'] != null || value['key'] != null);
          bool records(dynamic value, String field) => value is List &&
              value.any((entry) => entry is Map && entry.containsKey(field));
          return doc is List ? doc.any(site) : doc is Map &&
              (site(doc) || ['sites','lives','urls','depots','storeHouse'].any(doc.containsKey) ||
               records(doc['list'], 'vod_id') || records(doc['class'], 'type_id') ||
               doc['code'] != null && (doc['list'] is List || doc['class'] is List));
        } on FormatException { return false; }
      }).toList();
      int rank(ArchiveFile f) {
        const names = ['config.json', 'tv.json', 'api.json', 'index.json', 'main.json'];
        final i = names.indexOf(f.name.toLowerCase().replaceAll('\\', '/').split('/').last);
        return i < 0 ? names.length : i;
      }
      configs.sort((a, b) => rank(a).compareTo(rank(b)));
      final playlists = files.values.where((f) => RegExp(r'\.(m3u8?|txt)$', caseSensitive: false).hasMatch(f.name) &&
          f.size <= maxResponseBytes && CmsParser.parseLivePlaylist(CmsParser.decodeTextDocument(f.content)).isNotEmpty).toList();
      if (configs.isEmpty && playlists.length == 1) {
        final file = playlists.single;
        if (file.size > maxResponseBytes) throw const FormatException('ZIP 中的播放列表过大');
        final text = CmsParser.decodeTextDocument(file.content);
        if (CmsParser.parseLivePlaylist(text).isEmpty) throw const FormatException('播放列表没有可用频道');
        // Keep the playlist inline even after refreshing a remote ZIP subscription.
        return jsonEncode({'sites': [{'name': '播放列表', 'key': 'playlist', 'type': 1,
          'api': 'm3u_vod://playlist', 'ext': text}], 'lives': [{'name':'播放列表',
          'url': Uri.dataFromString(text, mimeType:'text/plain', encoding:utf8, base64:true).toString()}]});
      }
      if (configs.isEmpty) {
        final scripts = files.entries.where((e) => RegExp(r'\.(?:m?js|py)$', caseSensitive: false).hasMatch(e.key)).toList();
        final preferred = scripts.where((e) => RegExp(r'^(?:main|index|spider)\.(?:m?js|py)$', caseSensitive: false).hasMatch(e.key.split('/').last)).toList();
        final entry = scripts.length == 1 ? scripts.single : preferred.length == 1 ? preferred.single : null;
        if (entry == null || scripts.length > 32) {
          throw const FormatException('ZIP 需要明确的配置、播放列表或唯一的 main/index/spider 脚本入口');
        }
        final modules = <String, String>{};
        var size = 0;
        final python = entry.key.toLowerCase().endsWith('.py');
        final resources = files.entries.where((e) => RegExp(python ? r'\.py$' : r'\.(?:m?js|py|json)$', caseSensitive: false).hasMatch(e.key));
        for (final script in resources) {
          if (modules.length >= 32) throw const FormatException('ZIP 模块数量超过限制');
          size += script.value.size;
          if (size > maxResponseBytes) throw const FormatException('ZIP 脚本总大小超过 6 MB');
          modules[Uri(scheme: 'pkg', host: 'archive', path: '/${script.key}').toString()] = CmsParser.decodeTextDocument(script.value.content);
        }
        final origin = Uri(scheme: 'pkg', host: 'archive', path: '/${entry.key}').toString();
        final source = modules.remove(origin)!;
        if (!python && !CmsParser.isExecutableJs(source) && !CmsParser.looksLikeDrpyRule(source)) {
          throw const FormatException('ZIP 脚本需要兼容的 Spider 接口，当前不支持此规则宿主');
        }
        final result = jsonEncode({'sites': [{'key': 'local_script', 'name': '本地脚本', 'type': 3,
          'api': python ? 'csp_LocalScript.py' : CmsParser.looksLikeDrpyRule(source) ? 'csp_LocalRule.js' : 'csp_LocalScript.js',
          'ext': {'script': source, 'origin': origin, 'modules': modules,
            if (python) 'package': _pythonPackageData(files, entry.key)}}]});
        if (utf8.encode(result).length > maxResponseBytes) throw const FormatException('展开的订阅超过 6 MB');
        return result;
      }
      if (configs.length > 1 && rank(configs.first) == rank(configs[1])) {
        throw const FormatException('ZIP 需要一个明确的订阅入口，例如 config.json');
      }
      final file = configs.first;
      if (file.size > maxResponseBytes) throw const FormatException('ZIP 中的配置过大');
      var decoded = CmsParser.decodeConfigDocument(file.content);
      var doc = jsonDecode(CmsParser.stripJsonComments(decoded));
      if (doc is List) doc = <String, dynamic>{'sites': doc};
      if (doc is Map && doc['sites'] == null && doc['api'] != null &&
          (doc['name'] != null || doc['key'] != null)) {
        doc = <String, dynamic>{'sites': [doc]};
      }
      if (doc is Map) {
        final entryPath = _archivePath(file.name);
        final base = Uri(scheme: 'pkg', host: 'archive', path: '/$entryPath');
        var total = file.size;
        final liveEntries = doc['lives'];
        final sites = <dynamic>[
          if (doc['sites'] is List) ...doc['sites'] as List,
          if (liveEntries is List) ...liveEntries
          else if (liveEntries is Map) liveEntries,
        ];
        if (sites.isNotEmpty) {
          final scripts = <String, String>{};
          final scriptFile = RegExp(r'\.(?:m?js|py)$', caseSensitive: false);
          var expanded = file.size;
          for (final site in sites.whereType<Map>()) {
            final explicitRule = (site['api'] ?? '').toString().toLowerCase() == 'csp_drpy';
            final reference = explicitRule && site['ext'] is String ? site['ext'] : site['api'];
            final ref = Uri.tryParse((reference ?? '').toString());
            if (ref == null || ref.hasScheme || !scriptFile.hasMatch(ref.path)) continue;
            if (ref.hasAuthority || ref.path.startsWith('/')) throw const FormatException('ZIP 脚本路径无效');
            if (scripts.isEmpty) {
              for (final f in files.entries.where((e) => e.key != entryPath &&
                  (scriptFile.hasMatch(e.key) || e.key.toLowerCase().endsWith('.json')))) {
                if (scripts.length >= 32 || f.value.size > maxResponseBytes - total) {
                  throw const FormatException('ZIP 脚本数量或总大小超过限制');
                }
                total += f.value.size;
                scripts[Uri(scheme: 'pkg', host: 'archive', path: '/${f.key}').toString()] = CmsParser.decodeTextDocument(f.value.content);
              }
            }
            final origin = base.resolveUri(ref).toString();
            final source = scripts[origin];
            if (source == null) throw const FormatException('ZIP 中缺少入口脚本');
            expanded += total - file.size;
            if (expanded > maxResponseBytes) throw const FormatException('展开的订阅超过 6 MB');
            site['api'] = ref.path.toLowerCase().endsWith('.py') ? 'csp_LocalScript.py' : CmsParser.looksLikeDrpyRule(source) ? 'csp_LocalRule.js' : 'csp_LocalScript.js';
            site['ext'] = {'script': source, 'origin': origin,
              'modules': Map.of(scripts)..remove(origin), 'ext': explicitRule ? '' : site['ext'] ?? '',
              if (site['api'] == 'csp_LocalScript.py')
                'package': _pythonPackageData(files, base.resolveUri(ref).pathSegments.join('/'))};
          }
        }
        final lives = doc['lives'];
        for (final live in (lives is List ? lives : lives is Map ? [lives] : const []).whereType<Map>()) {
          // A script owns its opaque argument; it is not an archive filename.
          if ((live['api'] ?? '').toString().isNotEmpty) continue;
          final url = live['url'];
          if (url is! String || url.isEmpty || Uri.parse(url).hasScheme) continue;
          final ref = Uri.parse(url);
          if (ref.hasAuthority || ref.path.startsWith('/')) throw const FormatException('ZIP 播放列表路径无效');
          final target = files[base.resolveUri(ref).pathSegments.join('/')];
          if (target == null || target.size > maxResponseBytes - total) {
            throw const FormatException('ZIP 内的播放列表不存在或过大');
          }
          total += target.size;
          final text = CmsParser.decodeTextDocument(target.content);
          if (CmsParser.parseLivePlaylist(text).isEmpty) throw const FormatException('ZIP 播放列表没有可用频道');
          live['url'] = Uri.dataFromString(text, mimeType: 'text/plain', encoding: utf8, base64: true).toString();
        }
        decoded = jsonEncode(doc);
        if (utf8.encode(decoded).length > maxResponseBytes) throw const FormatException('展开的订阅超过 6 MB');
      }
      final config = CmsParser.parseConfig(decoded);
      if (config.sites.any((s) => !s.isHttpApi && !s.isM3uVodApi && !s.api.startsWith('csp_')) ||
          config.lives.any((s) => s.plugin == null && s.inlineContent.isEmpty &&
              !s.url.startsWith('http') && !s.url.startsWith('data:'))) {
        throw const FormatException('本地包包含相对路径的资源，当前客户端需要可访问的完整接口地址');
      }
      return decoded;
    }
    return CmsParser.decodeConfigDocument(bytes);
  }

  /// Fetches and unpacks a remote TVBox / Marco Movie config (supporting `okhttp/3.15` UA,
  /// Safari UA fallback, `**`+Base64 steganography, `$#...#$` AES-128-CBC, and Base64).
  Future<String> fetchRawConfig(String url) async {
    final normalized = CmsParser.extractAndNormalizeUrl(url);
    if (normalized.isEmpty) {
      throw const FormatException('请输入有效的 HTTP(S) 配置地址');
    }
    Exception? firstError;
    for (final ua in [tvBoxUserAgent, safariUserAgent]) {
      try {
        final bytes = await _getBytes(normalized, defaultUa: ua);
        final unpacked = readSubscriptionFile(bytes, normalized);
        final trimmed = unpacked.trimLeft();
        if (trimmed.startsWith('<!DOCTYPE') ||
            trimmed.toLowerCase().startsWith('<html')) {
          firstError = const FormatException('服务器返回了网页而非 JSON 配置');
          continue;
        }
        return unpacked;
      } catch (e) {
        firstError = e is Exception ? e : Exception(e.toString());
      }
    }
    throw firstError ?? Exception('无法连接配置地址');
  }
  /// Resolves either a remote URL, multi-depot URL, or pasted JSON/Base64/M3U/VOD config into
  /// a ready-to-use `(rawConfig, origin, activeDepotUrl, parsedConfig)` tuple.
  Future<({
    String rawConfig,
    String origin,
    String activeDepotName,
    List<CmsDepot> depots,
    CmsConfig config,
  })> resolveConfigInput({
    String urlInput = '',
    String rawTextInput = '',
    String defaultGroup = '默认分组',
    bool isPrivate = false,
    String subscriptionId = '',
    String defaultName = '',
  }) async {
    var trimmedText = rawTextInput.trim();
    var trimmedUrl = urlInput.trim();
    // If user pasted JSON/M3U/XML into the URL field or a URL into the JSON field, handle gracefully
    if (trimmedText.isEmpty && CmsParser.looksLikeScript(trimmedUrl)) {
      trimmedText = trimmedUrl;
      trimmedUrl = '';
    }
    final strippedUrl = CmsParser.stripJsonComments(trimmedUrl);
    final strippedText = CmsParser.stripJsonComments(trimmedText);
    if (trimmedText.isEmpty &&
        (trimmedUrl.startsWith('{') ||
            trimmedUrl.startsWith('[') ||
            strippedUrl.startsWith('{') ||
            strippedUrl.startsWith('[') ||
            trimmedUrl.startsWith('<') ||
            trimmedUrl.startsWith('#EXTM3U') ||
            trimmedUrl.contains('#EXTINF') ||
            trimmedUrl.contains(',#genre#'))) {
      trimmedText = trimmedUrl;
      trimmedUrl = '';
    } else if (trimmedUrl.isEmpty &&
        !CmsParser.looksLikeScript(trimmedText) &&
        !trimmedText.startsWith('{') &&
        !trimmedText.startsWith('[') &&
        !strippedText.startsWith('{') &&
        !strippedText.startsWith('[') &&
        !trimmedText.startsWith('<') &&
        !trimmedText.startsWith('#EXTM3U') &&
        !trimmedText.contains('#EXTINF') &&
        !trimmedText.contains(',#genre#') &&
        CmsParser.parseLivePlaylist(trimmedText).isEmpty &&
        (trimmedText.contains('http://') ||
            trimmedText.contains('https://') ||
            (trimmedText.contains('.') && !trimmedText.contains('\n')))) {
      trimmedUrl = trimmedText;
      trimmedText = '';
    }
    String origin = '';
    String rawConfig = '';
    if (trimmedText.isNotEmpty) {
      rawConfig = CmsParser.unpackConfigText(trimmedText);
      origin = CmsParser.extractAndNormalizeUrl(trimmedUrl);
    } else {
      origin = CmsParser.extractAndNormalizeUrl(trimmedUrl);
      if (origin.isEmpty) {
        throw const FormatException('请输入配置地址 (HTTP/HTTPS) 或粘贴配置内容');
      }
      final link = Uri.tryParse(origin);
      if (ChecksumSource.matches(link)) {
        final verified = await ChecksumSource.read(link!);
        if (CatPawHost.isBundle(verified.source)) {
          rawConfig = await CatPawHost.instance.install(verified.source);
        } else {
        if (!CmsParser.looksLikeScript(verified.source)) throw const FormatException('已校验的文件没有兼容的来源入口');
        // Keep only the verified body and credential-free module base in the subscription.
        final executable = CmsParser.isExecutableJs(verified.source);
        rawConfig = jsonEncode({'sites':[{'key':'verified_script','name': defaultName.isEmpty ? verified.script.host : defaultName,
          'type':3,'api':executable ? 'csp_LocalScript.js' : 'csp_LocalRule.js',
          'ext':{'script':verified.source,'origin':verified.script.toString()}}]});
        }
        origin = link.userInfo.isEmpty ? link.toString() : '';
      } else {
        rawConfig = await fetchRawConfig(origin);
      }
    }
    final initial = CmsParser.parseConfig(
      rawConfig,
      origin: origin,
      defaultGroup: defaultGroup,
      isPrivate: isPrivate,
      subscriptionId: subscriptionId,
      defaultName: defaultName,
    );
    if (!initial.isMultiDepotOnly) {
      return (
        rawConfig: rawConfig,
        origin: origin,
        activeDepotName: '',
        depots: initial.depots,
        config: initial,
      );
    }
    // Traverse nested catalogs with a shared cycle/size budget. Keep every discovered
    // branch so switching and restarting do not discard the warehouse directory.
    final visited = <String>{origin};
    final discovered = <String, CmsDepot>{};
    var requests = 0;
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    Future<({String raw, String origin, String name, CmsConfig config})> visit(
        CmsConfig catalog, int depth, String parent) async {
      if (depth >= 6) throw const FormatException('多仓嵌套超过 6 层');
      for (final d in catalog.depots) {
        discovered.putIfAbsent(d.url, () => CmsDepot(
          name: parent.isEmpty ? d.name : '$parent / ${d.name}',
          url: d.url, subscriptionId: subscriptionId));
      }
      Object? lastError;
      for (final depot in catalog.depots) {
        if (requests >= 32 || DateTime.now().isAfter(deadline)) break;
        if (!visited.add(depot.url)) continue;
        requests++;
        try {
          final remaining = deadline.difference(DateTime.now());
          final raw = await fetchRawConfig(depot.url).timeout(remaining);
          final parsed = CmsParser.parseConfig(raw, origin: depot.url,
            defaultGroup: defaultGroup, isPrivate: isPrivate,
            subscriptionId: subscriptionId,
            defaultName: defaultName.isEmpty ? depot.name : defaultName);
          if (parsed.isMultiDepotOnly) {
            return await visit(parsed, depth + 1, discovered[depot.url]!.name);
          }
          return (raw: raw, origin: depot.url, name: discovered[depot.url]!.name, config: parsed);
        } catch (e) { lastError = e; }
      }
      throw FormatException(lastError == null
        ? '多仓没有可读取的子仓库，或存在循环引用'
        : '子仓库读取失败，请稍后重试（${lastError.runtimeType}）');
    }
    final leaf = await visit(initial, 0, '');
    final depots = discovered.values.toList();
    return (rawConfig: leaf.raw, origin: leaf.origin, activeDepotName: leaf.name,
      depots: depots, config: CmsConfig(sites: leaf.config.sites,
        lives: leaf.config.lives, depots: depots, parses: leaf.config.parses,
        spider: leaf.config.spider));
  }

  Future<SubscriptionEntry> switchSubscriptionDepot(SubscriptionEntry owner, CmsDepot depot) async {
    final resolved = await resolveConfigInput(urlInput: depot.url,
      defaultGroup: owner.group, isPrivate: owner.isEffectivelyPrivate,
      subscriptionId: owner.id);
    final entries = <String, CmsDepot>{for (final d in owner.depots) d.url: d};
    for (final d in resolved.depots) { entries[d.url] = d; }
    return owner.copyWith(url: resolved.origin, rawContent: resolved.rawConfig,
      activeDepotName: resolved.activeDepotName.isEmpty ? depot.name : resolved.activeDepotName,
      depots: entries.values.toList(), siteCount: resolved.config.supportedSites.length,
      liveCount: resolved.config.lives.length, updatedAt: DateTime.now().millisecondsSinceEpoch);
  }

  /// Resolves one or multiple subscription URLs / raw content into [SubscriptionEntry] items.
  Future<List<SubscriptionEntry>> resolveBatchSubscriptions({
    String urlInput = '',
    String rawTextInput = '',
    String defaultGroup = '默认分组',
    bool isPrivate = false,
    String customName = '',
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final groupLabel =
        defaultGroup.trim().isEmpty ? '默认分组' : defaultGroup.trim();
    final batchLines = CmsParser.splitBatchSubscriptionUrls(
      urlInput.trim().isNotEmpty ? urlInput : rawTextInput,
      defaultGroup: groupLabel,
    );

    if (batchLines.length > 1) {
      final results = <SubscriptionEntry>[];
      Exception? lastErr;
      for (int i = 0; i < batchLines.length; i++) {
        final item = batchLines[i];
        final subId = 'sub_${now}_$i';
        try {
          final resolved = await resolveConfigInput(
            urlInput: item.url,
            defaultGroup: item.group,
            isPrivate: isPrivate,
            subscriptionId: subId,
            defaultName: item.name,
          );
          final fmt = CmsParser.detectSubscriptionFormat(
            resolved.rawConfig,
            origin: item.url,
          );
          final effectiveName = item.name.isNotEmpty
              ? item.name
              : (resolved.activeDepotName.isNotEmpty
                  ? resolved.activeDepotName
                  : (resolved.config.sites.length == 1
                      ? resolved.config.sites.first.name
                      : '订阅源 ${i + 1}'));
          results.add(
            SubscriptionEntry(
              id: subId,
              name: effectiveName,
              url: resolved.origin,
              warehouseUrl: resolved.depots.isEmpty ? '' : item.url,
              activeDepotName: resolved.activeDepotName,
              depots: resolved.depots,
              group: item.group,
              format: resolved.depots.isNotEmpty ? '多仓' : fmt,
              isPrivate: isPrivate,
              enabled: true,
              rawContent: resolved.rawConfig,
              siteCount: resolved.config.supportedSites.length,
              liveCount: resolved.config.lives.length,
              updatedAt: now + i,
            ),
          );
        } catch (e) {
          lastErr = e is Exception ? e : Exception(e.toString());
        }
      }
      if (results.isEmpty) {
        throw lastErr ?? const FormatException('未能成功导入任何订阅地址');
      }
      return results;
    }

    // Single subscription (either URL or pasted content)
    final singleLine = batchLines.length == 1 ? batchLines.first : null;
    final subId = 'sub_$now';
    final effectiveGroup = singleLine?.group ?? groupLabel;
    final effectiveHintName = customName.trim().isNotEmpty
        ? customName.trim()
        : (singleLine?.name ?? '');
    final resolved = await resolveConfigInput(
      urlInput: singleLine != null ? singleLine.url : urlInput,
      rawTextInput: singleLine != null ? '' : rawTextInput,
      defaultGroup: effectiveGroup,
      isPrivate: isPrivate,
      subscriptionId: subId,
      defaultName: effectiveHintName,
    );
    final fmt = CmsParser.detectSubscriptionFormat(
      resolved.rawConfig,
      origin: resolved.origin,
    );
    final displayName = effectiveHintName.isNotEmpty
        ? effectiveHintName
        : (resolved.activeDepotName.isNotEmpty
            ? resolved.activeDepotName
            : (resolved.config.sites.length == 1
                ? resolved.config.sites.first.name
                : (resolved.origin.isNotEmpty
                    ? Uri.tryParse(resolved.origin)?.host ?? '订阅资源'
                    : '$fmt 订阅')));
    return [
      SubscriptionEntry(
        id: subId,
        name: displayName,
        url: resolved.origin,
        warehouseUrl: resolved.depots.isEmpty ? '' : CmsParser.extractAndNormalizeUrl(singleLine?.url ?? urlInput),
        activeDepotName: resolved.activeDepotName,
        depots: resolved.depots,
        group: effectiveGroup,
        format: resolved.depots.isNotEmpty ? '多仓' : fmt,
        isPrivate: isPrivate,
        enabled: true,
        rawContent: resolved.rawConfig,
        siteCount: resolved.config.supportedSites.length,
        liveCount: resolved.config.lives.length,
        updatedAt: now,
      ),
    ];
  }

  Future<String> _resolveM3uVodPayload(CmsSite site) async {
    if (site.ext.trim().isNotEmpty) return site.ext;
    final rawTarget = site.api.substring('m3u_vod://'.length).trim();
    if (rawTarget.startsWith('http://') || rawTarget.startsWith('https://')) {
      return _getText(rawTarget, headers: site.headers);
    }
    return '';
  }

  bool _usesJs(CmsSite site) => GuardSource.supports(site) || site.isDrpySource || site.isPythonSource || (site.isJavaScriptSource || site.isRemoteScriptSource) &&
      !(CspBridge.isHuyaSite(site) || CspBridge.isDouyuSite(site) ||
        CspBridge.isTuxiaobeiSite(site) || CspBridge.isMyDriveSite(site));

  static String _scriptSessionKey(CmsSite site) => sha256.convert(utf8.encode(jsonEncode([
    site.subscriptionId, site.sourceKey, site.isEffectivelyPrivate,
    site.api, site.ext, site.pluginReference, site.headers,
    if (site.rawExtension != null) site.rawExtension,
  ]))).toString();

  /// Shared by catalogue, detail, and the player's separate CmsClient instance.
  static Future<void> retainScriptSessions(Iterable<CmsSite> sites) =>
      JsSourceHost.retainSessions(sites.map(_scriptSessionKey).toSet());

  static Future<void> closeScriptSessions() => JsSourceHost.closeAll();

  void Function() pinPlaybackSource(CmsSite site) =>
      _usesJs(site) ? JsSourceHost.pinForPlayback(_scriptSessionKey(site)) : () {};

  static bool canVerifySource(CmsSite site) =>
      GuardSource.supports(site) &&
      const {'fy-v1', 'auete-v1'}.contains(CspBridge.guardAdapterFor(site));

  static bool needsSourceVerification(CmsSite site, Object? error) =>
      canVerifySource(site) && error is DrpySourceException &&
      error.code == 'drpy_verification_required';

  bool _canFallbackToCspBridge(CmsSite site, [Object? error]) {
    if (error != null && needsSourceVerification(site, error)) return false;
    if (!GuardSource.supports(site)) return false;
    final ref = site.pluginReference.toLowerCase();
    if (ref.isEmpty ||
        ref.contains('.invalid') ||
        ref.contains('.test') ||
        ref.contains('.example')) {
      return false;
    }
    return true;
  }

  Future<Map<String, dynamic>> sourceVerificationAction(
    CmsSite site, Map<String, Object?> action, {Completer<void>? cancellation}
  ) async {
    if (!canVerifySource(site)) throw const FormatException('此片源暂不支持图片验证');
    if (cancellation?.isCompleted == true) throw const FormatException('验证已取消');
    final raw = await runZoned(() => _callJs(site, 'action', [jsonEncode(action)]),
        zoneValues: {_cancelKey: cancellation});
    if (cancellation?.isCompleted == true) throw const FormatException('验证已取消');
    final value = jsonDecode(raw);
    if (value is! Map<String, dynamic>) throw const FormatException('验证响应无效');
    return value;
  }

  Future<SourceImageChallenge> loadSourceChallenge(
    CmsSite site, {Completer<void>? cancellation}
  ) async => SourceImageChallenge.fromResponse(await sourceVerificationAction(site,
      {'type': 'verification', 'operation': 'challenge'}, cancellation: cancellation));

  Future<bool> submitSourceChallenge(CmsSite site, String id, String code,
      {Completer<void>? cancellation}) async {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(id) ||
        !RegExp(r'^[a-zA-Z0-9]{4,6}$').hasMatch(code)) {
      throw const FormatException('请输入图片中的 4 至 6 位字符');
    }
    final value = await sourceVerificationAction(site,
        {'type': 'verification', 'operation': 'submit', 'id': id, 'code': code},
        cancellation: cancellation);
    if (value['verified'] is! bool) throw const FormatException('验证响应无效');
    return value['verified'] as bool;
  }

  Future<String> _callJs(CmsSite site, String method, List<Object?> args) async {
    final cancellation = Zone.current[_cancelKey] as Completer<void>?;
    final generation = JsSourceHost.generation;
    if (GuardSource.supports(site)) return _guard.invoke(site, method, args, cancellation: cancellation);
    if (site.isDrpySource) return _drpy.invoke(site, method, args, cancellation: cancellation);
    final cachedRule = await _drpy.callCached(site, method, args, cancellation: cancellation);
    if (cachedRule != null) return cachedRule;
    final sessionKey = _scriptSessionKey(site);
    final cachedScript = await JsSourceHost.callCached(sessionKey: sessionKey,
        method: method, arguments: args, cancellation: cancellation);
    if (cachedScript != null) return cachedScript;
    var entry = site.api;
    if (site.ext.trim().isNotEmpty &&
        RegExp(r'(?:^|/)drpy2?(?:\.min)?\.m?js(?:[?#]|$)', caseSensitive: false)
            .hasMatch(entry)) {
      try {
        return await _drpy.invoke(site, method, args, cancellation: cancellation);
      } on FormatException catch (e) {
        if (!e.message.contains('没有可用的 DRPY 规则')) rethrow;
      }
    }
    Object? extension = site.ext;
    var rawExtension = site.rawExtension ?? site.ext;
    final modules = <String, String>{};
    var pythonPackage = <String, Object?>{};
    if (entry.startsWith('csp_LocalScript.')) {
      final local = jsonDecode(site.ext) as Map;
      entry = (local['origin'] as String?) ?? '';
      if (entry.isEmpty) entry = site.isPythonSource ? 'pkg://local/source.py' : 'pkg://local/source.js';
      modules[entry] = local['script'] as String;
      if (local['modules'] is Map) modules.addAll(Map<String, String>.from(local['modules'] as Map));
      if (local['package'] is Map) pythonPackage = Map<String, Object?>.from(local['package'] as Map);
      extension = local['ext'] ?? '';
      rawExtension = extension is String ? extension : jsonEncode(extension);
    } else {
      modules[entry] = await _getText(entry, headers: site.headers);
      try { extension = jsonDecode(site.ext); } on FormatException { /* Plain-text extension. */ }
    }
    if (site.isPythonSource || CmsParser.looksLikePythonScript(modules[entry]!)) {
      final prelude = await loadPythonSourcePrelude();
      return JsSourceHost.invoke(entry: entry, modules: modules, method: method, arguments: args,
          extension: extension, headers: site.headers, pythonPrelude: prelude,
          pythonPackage: pythonPackage,
          sessionKey: sessionKey, expectedGeneration: generation, cancellation: cancellation);
    }
    if (CmsParser.looksLikeDrpyRule(modules[entry]!)) {
      return _drpy.invoke(site, method, args, rule: modules[entry], origin: entry, cancellation: cancellation);
    }
    if (site.ext.trim().isNotEmpty &&
        modules[entry]!.contains('assets://js/lib/cheerio.min.js')) {
      try {
        return await _drpy.invoke(site, method, args, cancellation: cancellation);
      } on FormatException catch (e) {
        if (!e.message.contains('没有可用的 DRPY 规则')) rethrow;
      }
    }
    if (site.isRemoteScriptSource && !site.isJavaScriptSource &&
        !CmsParser.looksLikeScript(modules[entry]!)) {
      throw const FormatException('片源接口未返回可识别的脚本，请检查订阅中的接口类型');
    }
    // Preload static ES imports for the synchronous QuickJS module loader.
    var total = 0;
    final queue = [entry];
    final visited = <String>{};
    for (var index = 0; index < queue.length; index++) {
      final parent = queue[index];
      if (!visited.add(parent)) continue;
      if (visited.length > 32) throw const FormatException('脚本模块过多');
      final text = modules[parent]!;
      total += utf8.encode(text).length;
      if (total > maxResponseBytes) throw const FormatException('脚本模块总大小超过 6 MB');
      if (Uri.parse(parent).path.toLowerCase().endsWith('.json')) continue;
      final required = JsSourceHost.commonJsReferences(text).toSet();
      final references = {...JsSourceHost.esModuleReferences(text), ...required};
      for (final ref in references) {
        if (ref == 'catvod' && !required.contains(ref)) continue;
        if (ref == 'catvod' || ref.startsWith('catvod:') || ref.startsWith('marco:')) {
          throw const FormatException('当前脚本需要 CatVod 宿主模块，该接口尚未适配');
        }
        final common = required.contains(ref);
        if (common && !ref.startsWith('.') && !ref.startsWith('https://') && !ref.startsWith('http://') && !ref.startsWith('assets://')) {
          throw FormatException('不支持的 Node 模块：$ref');
        }
        var url = Uri.parse(parent).resolve(ref);
        if (url.scheme == 'assets') {
          final assetRef = url.toString();
          if (!modules.containsKey(assetRef)) {
            if (assetRef == 'assets://js/lib/cheerio.min.js') {
              final deps = await rootBundle.loadString(
                'assets/catpaw/drpy-dependencies.js',
              );
              modules[assetRef] =
                  '$deps\nglobalThis.DRPYDeps = DRPYDeps;\nexport const load = DRPYDeps.cheerio.load;\nexport const jp = DRPYDeps.cheerio.jp;\nexport const jpo = DRPYDeps.cheerio.jpo;\nexport const jinja2 = DRPYDeps.cheerio.jinja2;\nexport default DRPYDeps.cheerio;\n';
            } else if (assetRef == 'assets://js/lib/crypto-js.js') {
              final cryptoSrc = await rootBundle.loadString(
                'assets/js-host/crypto-js.js',
              );
              modules[assetRef] =
                  'const module={exports:{}};let exports=module.exports;\n$cryptoSrc\nglobalThis.CryptoJS = module.exports;\nexport default module.exports;\n';
            } else if (assetRef == 'assets://js/lib/cat.js') {
              modules[assetRef] = 'export * from "catvod";\n';
              queue.add(assetRef);
            } else if (assetRef.startsWith('assets://js/lib/')) {
              final relPath = assetRef.substring('assets://js/lib/'.length);
              final entryUri = Uri.parse(entry);
              if (entryUri.scheme == 'http' || entryUri.scheme == 'https') {
                final remoteLib = entryUri.resolve(relPath);
                modules[assetRef] = await _getText(
                  remoteLib.toString(),
                  headers: site.headers,
                );
                queue.add(assetRef);
              } else {
                throw FormatException('本地包缺少脚本模块：$ref');
              }
            } else {
              throw FormatException('本地包缺少脚本模块：$ref');
            }
          }
          continue;
        }
        final candidates = [url, if (common && !RegExp(r'\.(?:m?js|json)$', caseSensitive: false).hasMatch(url.path)) ...[
          url.replace(path: '${url.path}.js'), url.replace(path: '${url.path}.json'),
          url.replace(path: '${url.path}/index.js'),
        ]];
        for (final candidate in candidates) {
          if (modules.containsKey(candidate.toString())) { url = candidate; break; }
        }
        if (!modules.containsKey(url.toString())) {
          if (url.scheme != 'https' && url.scheme != 'http') {
            throw FormatException('本地包缺少脚本模块：$ref');
          }
          for (var i = 0; i < candidates.length; i++) {
            url = candidates[i];
            final sameOrigin = Uri.parse(parent).authority == url.authority && Uri.parse(parent).scheme == url.scheme;
            try {
              modules[url.toString()] = await _getText(url.toString(), headers: sameOrigin ? site.headers : {});
              break;
            } on HttpException catch (error) {
              if (error.message != 'HTTP 404' || i == candidates.length - 1) rethrow;
            }
          }
        }
        queue.add(url.toString());
      }
    }
    final cat = JsSourceHost.isCatSpider(modules[entry]!) && !JsSourceHost.isEsModule(modules[entry]!);
    return JsSourceHost.invoke(entry: entry, modules: modules, method: method,
      arguments: args, catDetails: cat,
      extension: cat ? {'stype': 3, 'skey': site.key, 'ext': extension} : extension,
      rawExtension: rawExtension,
      headers: site.headers, sessionKey: sessionKey, expectedGeneration: generation,
      cancellation: cancellation);
  }

  String _wrapJsEpisodeIds(String raw, {String scheme = 'mmjs'}) {
    final doc = jsonDecode(raw);
    if (doc is! Map || doc['list'] is! List) return raw;
    for (final item in (doc['list'] as List).whereType<Map>()) {
      final urls = item['vod_play_url'];
      if (urls is! String || urls.isEmpty) continue;
      final flags = (item['vod_play_from'] ?? '').toString().split(r'$$$');
      final groups = urls.split(r'$$$');
      for (var i = 0; i < groups.length; i++) {
        groups[i] = groups[i].split('#').where((s) => s.trim().isNotEmpty).map((s) {
          final sep = s.indexOf(r'$');
          final label = sep < 0 ? '正片' : s.substring(0, sep);
          final uri = Uri(scheme: scheme, host: 'play', queryParameters: {
            'flag': i < flags.length ? flags[i] : '',
            'id': sep < 0 ? s : s.substring(sep + 1),
          });
          return label + r'$' + uri.toString();
        }).join('#');
      }
      item['vod_play_url'] = groups.join(r'$$$');
    }
    return jsonEncode(doc);
  }

  String _detailAction(CmsSite site) => site.type == 0 ? 'videolist' : 'detail';

  bool _hasFastCspFallback(CmsSite site) {
    if (!_canFallbackToCspBridge(site)) return false;
    final ref = '${site.api} ${site.ext} ${site.pluginReference}'.toLowerCase();
    return !ref.contains('127.0.0.1') && !ref.contains('localhost');
  }

  Future<(List<CmsCategory>, CmsListing)> fetchHome(CmsSite site) async {
    if (_isHttpT4(site)) {
      final raw = await _callT4(site, {'filter': 'true'});
      final categories = CmsParser.parseCategories(raw);
      var listing = CmsParser.parseListing(_wrapJsEpisodeIds(raw, scheme: 'mmt4'));
      if (listing.videos.isEmpty && categories.isNotEmpty) listing = await fetchCategory(site, categories.first.id, 1);
      return (categories, listing);
    }
    if (site.isCatPaw) {
      final raw = await _getText(site.api);
      final categories = CmsParser.parseCategories(raw);
      var listing = CmsParser.parseListing(raw);
      if (listing.videos.isEmpty && categories.isNotEmpty) {
        listing = await fetchCategory(site, categories.first.id, 1);
      }
      return (categories, listing);
    }
    if (site.isEmby) return (await EmbyLibrary.open(site)).home();
    if (_usesJs(site)) {
      try {
        final homeCall = _callJs(site, 'home', [false]);
        final raw = await (_hasFastCspFallback(site)
            ? homeCall.timeout(const Duration(seconds: 6))
            : homeCall);
        final categories = CmsParser.parseCategories(raw);
        var listing = CmsParser.parseListing(raw);
        if (listing.videos.isEmpty) {
          try {
            final vodCall = _callJs(site, 'homeVod', []);
            listing = CmsParser.parseListing(await (_hasFastCspFallback(site)
                ? vodCall.timeout(const Duration(seconds: 6))
                : vodCall));
          } catch (error) {
            if (categories.isEmpty || needsSourceVerification(site, error)) rethrow;
          }
          if (listing.videos.isEmpty && categories.isNotEmpty) {
            listing = await fetchCategory(site, categories.first.id, 1);
          }
        }
        if (categories.isNotEmpty || listing.videos.isNotEmpty || !_canFallbackToCspBridge(site)) {
          return (categories, listing);
        }
      } catch (error) {
        if (!_canFallbackToCspBridge(site, error)) rethrow;
      }
      return CspBridge.fetchHome(site, _getText);
    }
    if (site.isM3uVodApi) {
      final content = await _resolveM3uVodPayload(site);
      return CmsParser.parseM3uVodHome(content, origin: site.api.substring('m3u_vod://'.length));
    }
    if (CspBridge.canHandleSite(site)) {
      return CspBridge.fetchHome(site, _getText);
    }
    List<CmsCategory> categories = const [];
    CmsListing listing = const CmsListing();
    // Step 1: Query `ac=list` first (standard MacCMS endpoint for categories)
    try {
      final listRaw = await _getText(
        _appendQuery(site.api, {'ac': 'list'}, ext: site.ext).toString(),
        headers: site.headers,
      );
      categories = CmsParser.parseCategories(listRaw);
      listing = CmsParser.parseListing(listRaw);
    } catch (_) {}
    // Step 2: Query `ac=detail` or `ac=videolist` for full video cards with posters
    if (listing.videos.isEmpty ||
        listing.videos.every((v) => v.poster.isEmpty)) {
      try {
        final detailRaw = await _getText(
          _appendQuery(site.api, {'ac': _detailAction(site)}, ext: site.ext).toString(),
          headers: site.headers,
        );
        if (categories.isEmpty) {
          categories = CmsParser.parseCategories(detailRaw);
        }
        final detailListing = CmsParser.parseListing(detailRaw);
        if (detailListing.videos.isNotEmpty) {
          listing = detailListing;
        }
      } catch (_) {
        if (categories.isEmpty && listing.videos.isEmpty) rethrow;
      }
    }
    if (listing.videos.isEmpty && categories.isNotEmpty) {
      listing = await fetchCategory(site, categories.first.id, 1);
    }
    return (categories, listing);
  }
  Future<CmsListing> fetchCategory(
    CmsSite site,
    String categoryId,
    int page, {
    List<String> childIds = const [],
    CmsFilter? filter,
  }) async {
    if (_isHttpT4(site)) {
      final filters = <String, String>{
        if (filter != null && filter.genreLabel.isNotEmpty && filter.genreLabel != '全部') 'class': filter.genreLabel,
        if (filter != null && filter.area.isNotEmpty && filter.area != '全部') 'area': filter.area,
        if (filter != null && filter.year.isNotEmpty && filter.year != '全部') 'year': filter.year,
      };
      final raw = await _callT4(site, {'ac': 'detail', 't': categoryId, 'pg': '$page',
        'ext': base64Url.encode(utf8.encode(jsonEncode(filters)))});
      final listing = CmsParser.parseListing(_wrapJsEpisodeIds(raw, scheme: 'mmt4'));
      return CmsListing(page: listing.page, pageCount: listing.pageCount,
        videos: listing.videos, sourceFiltered: filters.isNotEmpty);
    }
    if (site.isEmby) return (await EmbyLibrary.open(site)).list(categoryId, '', page);
    if (_usesJs(site)) {
      final extend = <String, String>{
        if (filter != null && filter.genreLabel.isNotEmpty) 'class': filter.genreLabel,
        if (GuardSource.supports(site) && filter != null && filter.genreLabel.isNotEmpty) 'type': filter.genreLabel,
        if (filter != null && filter.area.isNotEmpty) 'area': filter.area,
        if (filter != null && filter.year.isNotEmpty) 'year': filter.year,
      };
      try {
        final catCall = _callJs(site, 'category', [categoryId, page, extend.isNotEmpty, extend]);
        final listing = CmsParser.parseListing(await (_hasFastCspFallback(site)
            ? catCall.timeout(const Duration(seconds: 6))
            : catCall));
        if (listing.videos.isNotEmpty || !_canFallbackToCspBridge(site)) {
          if (filter == null || !filter.hasSubFilter || extend.isEmpty) return listing;
          return CmsListing(page: listing.page, pageCount: listing.pageCount,
              videos: listing.videos, sourceFiltered: true);
        }
      } catch (error) {
        if (!_canFallbackToCspBridge(site, error)) rethrow;
      }
      return CspBridge.fetchCategory(site, categoryId, page, _getText, childIds: childIds);
    }
    if (site.isM3uVodApi) {
      final content = await _resolveM3uVodPayload(site);
      final (_, homeListing) = CmsParser.parseM3uVodHome(content, origin: site.api.substring('m3u_vod://'.length));
      var videos = homeListing.videos;
      if (categoryId.isNotEmpty) {
        videos = videos
            .where((v) => v.remarks == categoryId || v.tag == categoryId)
            .toList();
      }
      if (filter != null && filter.hasSubFilter) {
        videos = CmsParser.filterVideos(videos, filter);
      }
      return CmsListing(page: 1, pageCount: 1, videos: videos);
    }
    if (CspBridge.canHandleSite(site)) {
      final listing = await CspBridge.fetchCategory(
        site,
        categoryId,
        page,
        _getText,
        childIds: childIds,
      );
      if (filter != null && filter.hasSubFilter) {
        final filtered = CmsParser.filterVideos(listing.videos, filter);
        if (filtered.isNotEmpty || page > 1) {
          return CmsListing(
            page: listing.page,
            pageCount: listing.pageCount,
            videos: filtered,
          );
        }
      }
      return listing;
    }
    Future<CmsListing> query(String id) async {
      final params = <String, String>{
        'ac': _detailAction(site),
        'pg': page.toString(),
      };
      if (id.isNotEmpty) {
        params['t'] = id;
      }
      if (filter != null) {
        if (filter.area.isNotEmpty && filter.area != '全部') {
          params['area'] = filter.area;
        }
        if (filter.year.isNotEmpty &&
            filter.year != '全部' &&
            filter.year != '2010年代' &&
            filter.year != '更早') {
          params['year'] = filter.year;
        }
        if (filter.genreLabel.isNotEmpty && filter.genreLabel != '全部') {
          params['class'] = filter.genreLabel;
        }
      }
      final raw = await _getText(
        _appendQuery(site.api, params, ext: site.ext).toString(),
        headers: site.headers,
      );
      final parsed = CmsParser.parseListing(raw);
      if (filter != null && filter.hasSubFilter) {
        final filtered = CmsParser.filterVideos(parsed.videos, filter);
        if (filtered.isNotEmpty) {
          return CmsListing(
            page: parsed.page,
            pageCount: parsed.pageCount,
            videos: filtered,
          );
        }
      }
      return parsed;
    }
    final direct = await query(categoryId);
    if (direct.videos.isNotEmpty || childIds.isEmpty) return direct;
    // Parent category returned nothing: merge its leaf categories instead.
    final children = await Future.wait(
      childIds.take(8).map(
            (id) => query(id).catchError((_) => const CmsListing()),
          ),
    );
    return CspBridge.mergeChildListings(children, page);
  }
  Future<CmsListing> fetchSearch(
    CmsSite site,
    String keyword, {
    int page = 1,
  }) async {
    if (_isHttpT4(site)) {
      final raw = await _callT4(site, {'wd': keyword.trim(), 'quick': 'false', 'pg': '$page'});
      return CmsParser.parseListing(_wrapJsEpisodeIds(raw, scheme: 'mmt4'));
    }
    if (site.isEmby) return (await EmbyLibrary.open(site)).list('', keyword, page);
    if (_usesJs(site)) {
      try {
        final searchCall = _callJs(site, 'search', [keyword, false, page]);
        final listing = CmsParser.parseListing(await (_hasFastCspFallback(site)
            ? searchCall.timeout(const Duration(seconds: 4))
            : searchCall));
        if (listing.videos.isNotEmpty || !_canFallbackToCspBridge(site)) return listing;
      } catch (error) {
        if (!_canFallbackToCspBridge(site, error)) rethrow;
      }
      return CspBridge.fetchSearch(site, keyword, page, _getText);
    }
    if (site.isM3uVodApi) {
      final content = await _resolveM3uVodPayload(site);
      final (_, homeListing) = CmsParser.parseM3uVodHome(content, origin: site.api.substring('m3u_vod://'.length));
      final kw = keyword.trim().toLowerCase();
      final matched = homeListing.videos
          .where((v) => v.title.toLowerCase().contains(kw))
          .toList(growable: false);
      return CmsListing(page: 1, pageCount: 1, videos: matched);
    }
    if (CspBridge.canHandleSite(site)) {
      return CspBridge.fetchSearch(site, keyword, page, _getText);
    }
    final raw = await _getText(
      _appendQuery(
        site.api,
        {
          'ac': _detailAction(site),
          'wd': keyword.trim(),
          'pg': page.toString(),
        },
        ext: site.ext,
      ).toString(),
      headers: site.headers,
    );
    return CmsParser.parseListing(raw);
  }
  /// Match a catalogue-only item to a playable item from the user's visible
  /// subscriptions. Keep the owning site so its resolver and headers follow it.
  Future<(CmsSite, CmsVideo)> playableDetail(
    CmsSite source, CmsVideo item, Iterable<CmsSite> candidates,
  ) async {
    final detail = await fetchDetail(source, item);
    if (detail.lines.any((l) => l.episodes.isNotEmpty)) return (source, detail);
    final title = detail.title.trim();
    if (title.isEmpty) return (source, detail);
    String normTitleOf(String raw) =>
        raw.trim().toLowerCase().replaceAll(RegExp(r'[\s·:：,，.。!！?？\-_—()（）\[\]【】《》]+'), '');
    final normTitle = normTitleOf(title);
    final filtered = candidates.where((s) => s.key != source.key &&
        s.isEffectivelyPrivate == source.isEffectivelyPrivate && s.searchable &&
        s.canBrowse && !CspBridge.isDoubanSite(s) && !CspBridge.isMyDriveSite(s) &&
        (_usesJs(s) || !CspBridge.canHandleSite(s) || CspBridge.backendsForSite(s).isNotEmpty ||
          CspBridge.isBiliSite(s) || CspBridge.isFirstAidSite(s) || CspBridge.isTuxiaobeiSite(s))).toList();
    int sitePriority(CmsSite s) {
      if (CspBridge.isBiliSite(s) || CspBridge.isFirstAidSite(s) || CspBridge.isTuxiaobeiSite(s)) {
        return 2;
      }
      if (s.isCatPaw && (CspBridge.isNetdiskSite(s) || s.name.toLowerCase().contains('4k'))) {
        return -1;
      }
      return 0;
    }
    final indexed = filtered.indexed.toList()
      ..sort((a, b) {
        final cmp = sitePriority(a.$2).compareTo(sitePriority(b.$2));
        return cmp != 0 ? cmp : a.$1.compareTo(b.$1);
      });
    final pool = indexed.map((e) => e.$2);
    Future<(CmsSite, CmsVideo)?> match(CmsSite site) async {
      try {
        final results = await fetchSearch(site, title);
        final exactMatches = results.videos.where((v) => v.title.trim() == title).toList();
        final normMatches = normTitle.isEmpty
            ? const <CmsVideo>[]
            : results.videos
                .where((v) =>
                    v.title.trim() != title &&
                    normTitleOf(v.title) == normTitle)
                .toList();
        for (final found in [...exactMatches, ...normMatches]) {
          if (detail.year.isNotEmpty && found.year.isNotEmpty && found.year != detail.year) continue;
          final video = await fetchDetail(site, found);
          if (detail.year.isNotEmpty && video.year.isNotEmpty && video.year != detail.year) continue;
          final videoTitle = video.title.trim();
          final titleMatches = videoTitle == title ||
              (normTitle.isNotEmpty && normTitleOf(videoTitle) == normTitle);
          if (titleMatches && video.lines.any((l) => l.episodes.any((e) => e.isDirectPlayable || e.needsSourceResolution))) {
            return (site, video);
          }
        }
      } catch (_) {
        // One failed source must not discard matches from other sources.
      }
      return null;
    }
    final sites = pool.take(12).toList();
    for (int i = 0; i < sites.length; i += 2) {
      final matches = await Future.wait(sites.skip(i).take(2).map(
        (s) => match(s).timeout(const Duration(seconds: 12), onTimeout: () => null)));
      for (final result in matches) {
        if (result != null) return result;
      }
    }
    return (source, detail);
  }

  Future<CmsVideo> fetchDetail(CmsSite site, CmsVideo fallback) async {
    if (fallback.id.startsWith('mmquark://owned?')) {
      return _mergeDetail(CmsVideo(id: fallback.id, title: fallback.title,
          lines: [CmsLine(name: '夸克网盘', episodes: [
            CmsEpisode(name: fallback.title, url: fallback.id),
          ])]), fallback);
    }
    if (_isHttpT4(site)) {
      final raw = await _callT4(site, {'ac': 'detail', 'ids': fallback.id});
      final listing = CmsParser.parseListing(_wrapJsEpisodeIds(raw, scheme: 'mmt4'));
      return listing.videos.isEmpty ? fallback : _mergeDetail(listing.videos.first, fallback);
    }
    if (site.isCatPaw) {
      if (CspBridge.isDoubanSite(site)) return fallback;
      final raw = await _getText(_appendQuery(site.api, {'ac':'detail','ids':fallback.id}).toString());
      final listing = CmsParser.parseListing(_wrapJsEpisodeIds(raw,scheme:'mmpaw'));
      return listing.videos.isEmpty ? fallback : _mergeDetail(listing.videos.first, fallback);
    }
    if (site.isEmby) return (await EmbyLibrary.open(site)).detail(fallback.id);
    if (_usesJs(site)) {
      try {
        final detailCall = _callJs(site, 'detail', [fallback.id]);
        final raw = await (_hasFastCspFallback(site)
            ? detailCall.timeout(const Duration(seconds: 6))
            : detailCall);
        final listing = CmsParser.parseListing(_wrapJsEpisodeIds(raw));
        if (listing.videos.isNotEmpty && listing.videos.first.lines.isNotEmpty) {
          return _mergeDetail(listing.videos.first, fallback);
        }
        if (!_canFallbackToCspBridge(site)) {
          return listing.videos.isEmpty ? fallback : _mergeDetail(listing.videos.first, fallback);
        }
      } catch (error) {
        if (!_canFallbackToCspBridge(site, error)) rethrow;
      }
      return CspBridge.fetchDetail(site, fallback, _getText);
    }
    if (site.isM3uVodApi) {
      return fallback;
    }
    if (CspBridge.canHandleSite(site)) {
      return CspBridge.fetchDetail(site, fallback, _getText);
    }
    if (fallback.lines.isNotEmpty) return fallback;
    final raw = await _getText(
      _appendQuery(
        site.api,
        {
          'ac': _detailAction(site),
          'ids': fallback.id,
        },
        ext: site.ext,
      ).toString(),
      headers: site.headers,
    );
    final listing = CmsParser.parseListing(raw);
    if (listing.videos.isEmpty) return fallback;
    return _mergeDetail(listing.videos.first, fallback);
  }
  CmsVideo _mergeDetail(CmsVideo detailed, CmsVideo fallback) => CmsVideo(
    id: detailed.id.isEmpty ? fallback.id : detailed.id,
    title: detailed.title.isEmpty ? fallback.title : detailed.title,
    poster: CmsParser.isBrokenPosterUrl(detailed.poster) ? fallback.poster : detailed.poster,
    remarks: detailed.remarks.isEmpty ? fallback.remarks : detailed.remarks,
    year: detailed.year.isEmpty ? fallback.year : detailed.year,
    area: detailed.area.isEmpty ? fallback.area : detailed.area,
    actor: detailed.actor.isEmpty ? fallback.actor : detailed.actor,
    description: detailed.description.isEmpty ? fallback.description : detailed.description,
    tag: detailed.tag.isEmpty ? fallback.tag : detailed.tag,
    lines: detailed.lines,
  );
  Uri? _sourceCredentialOrigin(CmsSite site) {
    if (site.isHttpApi) return Uri.tryParse(site.api);
    Object? extension = site.ext;
    try { extension = jsonDecode(site.ext); } on FormatException { /* Text URL. */ }
    final raw = extension is Map ? extension['origin'] : extension;
    final origin = raw is String ? Uri.tryParse(raw) : null;
    return origin != null && ['http', 'https'].contains(origin.scheme) ? origin : null;
  }
  static bool _isDirectStreamUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null) return false;
    if (const {'rtsp', 'rtmp', 'mms', 'udp', 'rtp'}.contains(uri.scheme.toLowerCase())) {
      return true;
    }
    if (!const {'http', 'https'}.contains(uri.scheme.toLowerCase())) return false;
    return RegExp(
      r'\.(?:m3u8?|mp4|flv|mkv|ts|webm|mpd|mov|avi)$',
      caseSensitive: false,
    ).hasMatch(uri.path);
  }

  Future<Map<String, dynamic>?> _tryResolveJsonParser(
    CmsSite site,
    String playPrefix,
    String targetUrl,
  ) async {
    final prefix = playPrefix.trim();
    final target = targetUrl.trim();
    if (prefix.isEmpty ||
        target.isEmpty ||
        (!prefix.startsWith('http://') && !prefix.startsWith('https://'))) {
      return null;
    }
    try {
      final parserUrl = '$prefix${Uri.encodeComponent(target)}';
      final resp = await _getText(
        parserUrl,
        headers: SourcePlayback.headersForOrigin(
            site.headers, _sourceCredentialOrigin(site), Uri.tryParse(parserUrl)),
      );
      final trimmed = resp.trim();
      if (!trimmed.startsWith('{')) return null;
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        final mediaUrl = (decoded['url'] ?? '').toString().trim();
        final mediaUri = Uri.tryParse(mediaUrl);
        if (mediaUri != null &&
            const {'http', 'https', 'rtsp', 'rtmp'}.contains(mediaUri.scheme) &&
            mediaUri.host.isNotEmpty) {
          return Map<String, dynamic>.from(decoded)..['parse'] = 0;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<CmsEpisode> resolveEpisodeForPlayback(
    CmsSite site,
    CmsEpisode episode,
  ) async {
    if (episode.url.startsWith('mmquark://')) {
      final drive = _quark ?? QuarkDriveClient(
          accounts: (await StorageService.init()).quarkAccounts, httpClient: _http);
      try { return await drive.resolve(episode); }
      finally { if (_quark == null) drive.close(); }
    }
    if (_isHttpT4(site) && episode.url.startsWith('mmt4://play?')) {
      final parameters = Uri.parse(episode.url).queryParameters;
      final raw = jsonDecode(await _callT4(site,
        {'play': parameters['id'] ?? '', 'flag': parameters['flag'] ?? ''}));
      return SourcePlayback.decode(raw as Map, episode, localUrl: _scriptHost.resolve,
        sourceHeaders: site.headers, sourceOrigin: _sourceCredentialOrigin(site));
    }
    if (site.isCatPaw && episode.url.startsWith('mmpaw://play?')) {
      final parameters = Uri.parse(episode.url).queryParameters;
      final raw = jsonDecode(await _getText(_appendQuery(site.api,
        {'play':parameters['id'] ?? '', 'flag':parameters['flag'] ?? ''}).toString()));
      if (raw is! Map) throw const FormatException('CatPaw 没有返回播放结果');
      return SourcePlayback.decode(raw,episode,localUrl:CatPawHost.instance.resolve,sourceHeaders:site.headers,sourceOrigin:_sourceCredentialOrigin(site));
    }
    if (site.isEmby && episode.url.startsWith('mmemby://play?')) {
      return (await EmbyLibrary.open(site)).resolve(episode);
    }
    if (_usesJs(site) && episode.isScriptEpisode) {
      final params = Uri.parse(episode.url).queryParameters;
      final raw = jsonDecode(await _callJs(site, 'play', [params['flag'], params['id'], []]));
      if (raw is! Map) throw const FormatException('脚本没有返回播放地址');
      final payload = Map.of(raw);
      final url = Uri.tryParse((raw['url'] ?? '').toString());
      if (url != null && ['http', 'https', 'rtsp', 'rtmp'].contains(url.scheme) &&
          RegExp(r'\.(mp4|m3u8|mpd|webm|flv|ts|mkv)$', caseSensitive: false).hasMatch(url.path)) {
        payload['parse'] = 0;
        payload['jx'] = 0;
      } else if ('${payload['parse'] ?? 0}' != '0' || '${payload['jx'] ?? 0}' != '0') {
        final parsed = await _tryResolveJsonParser(
          site,
          (payload['playUrl'] ?? site.playUrl).toString(),
          (payload['url'] ?? '').toString(),
        );
        if (parsed != null) {
          payload
            ..addAll(parsed)
            ..['parse'] = 0
            ..['jx'] = 0;
        }
      }
      final resolved = await SourcePlayback.decode(payload, episode,
          localUrl: _scriptHost.resolve,
          // A plugin's import headers are not the adapted media server's
          // credentials. The reviewed adapter returns explicit playback headers.
          sourceHeaders: GuardSource.supports(site) ? const {} : site.headers,
          sourceOrigin: GuardSource.supports(site) ? null : _sourceCredentialOrigin(site));
      return _localScriptPlaybackHeaders(site, resolved);
    }
    var resolved = await CspBridge.resolveEpisodeForPlayback(site, episode, _getText);
    if (site.playUrl.isNotEmpty && !_isDirectStreamUrl(resolved.url)) {
      final parsed = await _tryResolveJsonParser(site, site.playUrl, resolved.url);
      if (parsed != null) {
        resolved = await SourcePlayback.decode(
          parsed,
          resolved,
          localUrl: _scriptHost.resolve,
          sourceHeaders: site.headers,
          sourceOrigin: _sourceCredentialOrigin(site),
        );
      }
    }
    return SourcePlayback.inheritSourceHeaders(resolved,
        sourceHeaders: site.headers, sourceOrigin: _sourceCredentialOrigin(site));
  }

  CmsEpisode _localScriptPlaybackHeaders(CmsSite site, CmsEpisode episode) {
    final headers = Map<String, String>.of(episode.headers);
    final uri = Uri.tryParse(episode.url);
    if (uri != null && JsSourceHost.ownsProxyUrl(_scriptSessionKey(site), uri)) {
      String? origin;
      final connectionHeaders = <String>{};
      for (final entry in headers.entries) {
        if (entry.key.toLowerCase() == 'origin') origin = entry.value;
        if (entry.key.toLowerCase() == 'connection') {
          connectionHeaders.addAll(entry.value.toLowerCase().split(',').map((v) => v.trim()));
        }
      }
      headers.removeWhere((key, _) => const {
        'origin', 'host', 'content-length', 'connection', 'keep-alive',
        'proxy-connection', 'transfer-encoding', 'te', 'trailer', 'upgrade',
      }.contains(key.toLowerCase()) || connectionHeaders.contains(key.toLowerCase()));
      // The listener rejects browser Origin headers. Preserve the source's
      // upstream value as private transport metadata for its own callback.
      if (origin != null) {
        headers.removeWhere((key, _) => key.toLowerCase() == 'x-marcomovie-proxy-origin');
        headers['X-MarcoMovie-Proxy-Origin'] = origin;
      }
    }
    return CmsEpisode(name: episode.name, url: episode.url, headers: headers,
        playbackSession: episode.playbackSession, externalAudioUrl: episode.externalAudioUrl,
        variants: episode.variants.map((e) => _localScriptPlaybackHeaders(site, e)).toList());
  }
  CmsEpisode resolveLiveEpisodeForPlayback(CmsSite site, CmsEpisode episode) =>
      _localScriptPlaybackHeaders(site, SourcePlayback.inheritSourceHeaders(episode,
        sourceHeaders: site.headers, sourceOrigin: _sourceCredentialOrigin(site)));

  Future<List<LiveGroup>> fetchLiveGroups(LiveSource source) async {
    final u = source.url.trim();
    String raw;
    String origin = source.origin;
    var playbackHeaders = source.headers;
    if (source.inlineContent.isNotEmpty) {
      raw = source.inlineContent;
    } else if (source.plugin != null) {
      if (!_usesJs(source.playbackSite)) {
        throw const FormatException('这条直播线路的插件尚未适配当前设备，请选择其他直播来源');
      }
      raw = await _callJs(source.playbackSite, 'liveContent', [u]);
      origin = _sourceCredentialOrigin(source.playbackSite)?.toString() ?? origin;
    } else if (u.startsWith('data:')) {
      final b64Idx = u.indexOf('base64,');
      if (b64Idx < 0) throw const FormatException('内嵌直播列表格式无效');
      final b64 = u.substring(b64Idx + 7).trim();
      if (b64.length > maxResponseBytes * 4 ~/ 3 + 4) throw const FormatException('直播列表超过 6 MB');
      raw = utf8.decode(base64Decode(b64), allowMalformed: true);
    } else {
      raw = CmsParser.decodeConfigDocument(await _getBytes(u, headers: source.headers,
        onResponse: (uri, headers) {
          origin = uri.toString();
          playbackHeaders = headers..removeWhere((key, _) =>
              key.toLowerCase() == 'accept' && !source.headers.keys.any((k) => k.toLowerCase() == 'accept'));
        }));
    }
    final groups = CmsParser.parseLivePlaylist(raw, origin: origin, headers: playbackHeaders);
    if (groups.isEmpty) throw const FormatException('来源未返回可播放的直播频道，请重试或切换直播来源');
    return groups;
  }
  Stream<(CmsSite, List<CmsVideo>)> searchAcrossSites(
    List<CmsSite> sites,
    String keyword, {
    int maxConcurrency = defaultSearchConcurrency,
    void Function(CmsSite site, Object error)? onSourceError,
  }) {
    late final StreamController<(CmsSite, List<CmsVideo>)> controller;
    bool cancelled = false;
    final requests = <Completer<void>>{};
    controller = StreamController<(CmsSite, List<CmsVideo>)>(
      onCancel: () {
        cancelled = true;
        for (final request in requests) {
          if (!request.isCompleted) request.complete();
        }
      },
    );
    final seenBackends = <String>{};
    final runnableSites = <CmsSite>[];
    for (final s in sites) {
      if (!s.supported || !s.searchable) continue;
      if (CspBridge.isDoubanSite(s) ||
          CspBridge.isMyDriveSite(s) ||
          CspBridge.isHuyaSite(s) ||
          CspBridge.isDouyuSite(s)) {
        continue;
      }
      if (CspBridge.canHandleSite(s)) {
        final backends = CspBridge.backendsForSite(s);
        final nativeAdapter = _usesJs(s) || CspBridge.isBiliSite(s) || CspBridge.isFirstAidSite(s) || CspBridge.isTuxiaobeiSite(s);
        if (!nativeAdapter && backends.isEmpty) continue;
        final String sig;
        if (_usesJs(s)) {
          sig = s.key;
        } else if (CspBridge.isBiliSite(s)) {
          sig = 'csp_bili_search';
        } else if (CspBridge.isFirstAidSite(s)) {
          sig = 'csp_firstaid_search';
        } else if (CspBridge.isTuxiaobeiSite(s)) {
          sig = 'csp_tuxiaobei_search';
        } else {
          sig = backends.first.api;
        }
        if (!seenBackends.add(sig)) continue;
      } else {
        if (!seenBackends.add(s.api)) continue;
      }
      runnableSites.add(s);
    }
    if (runnableSites.isEmpty || keyword.trim().isEmpty) {
      controller.close();
      return controller.stream;
    }
    final concurrency = maxConcurrency.clamp(1, 12);
    int nextIndex = 0;
    int inFlight = 0;
    void pump() {
      if (cancelled || controller.isClosed) return;
      while (!cancelled &&
          !controller.isClosed &&
          inFlight < concurrency &&
          nextIndex < runnableSites.length) {
        final site = runnableSites[nextIndex++];
        inFlight++;
        final abort = Completer<void>();
        requests.add(abort);
        runZoned(() => fetchSearch(site, keyword), zoneValues: {_cancelKey: abort})
            .timeout(const Duration(seconds: 12))
            .then((listing) {
          if (!cancelled && !controller.isClosed && listing.videos.isNotEmpty) {
            controller.add((site, listing.videos));
          }
        }).catchError((Object error) {
          if (!cancelled && !controller.isClosed) onSourceError?.call(site, error);
        }).whenComplete(() {
          if (!abort.isCompleted) abort.complete();
          requests.remove(abort);
          inFlight--;
          if (cancelled || controller.isClosed) return;
          if (nextIndex < runnableSites.length) {
            pump();
          } else if (inFlight <= 0 && !controller.isClosed) {
            controller.close();
          }
        });
      }
    }
    pump();
    return controller.stream;
  }
}
