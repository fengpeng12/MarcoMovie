import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'quark_account.dart';

class GuardBootstrapException extends FormatException {
  final String code;
  const GuardBootstrapException(this.code, String message) : super(message);
}

class DrpySourceException extends FormatException {
  final String code;
  const DrpySourceException(this.code, String message) : super(message);
}

/// Stable subscriptions reference verified local bytes, never an ephemeral port.
class CatPawHost {
  static CatPawHost instance = CatPawHost();
  final Future<Directory> Function()? directory;
  final String? executable;
  final String? bootstrap;
  CatPawHost({this.directory, this.executable, this.bootstrap});
  Process? _process;
  Future<Uri>? _starting;
  Uri? _base;
  Future<void>? _closing;
  bool _needsReset = false;
  Directory? _root;
  String? _lastSyncedPanJson;
  final _activeDrpy = <String, int>{};
  final _releasingDrpy = <String, Future<void>>{};
  int _generation = 0;
  static const drpyRuntime = 'drpy2-ca23ffdb-1';
  static const _maxBundleBytes = 16 * 1024 * 1024;
  static bool matches(String value) => value.startsWith('catpaw://');
  static bool isBundle(String code) =>
      code.contains('catServerFactory') && code.contains('catDartServerPort');

  Future<Directory> _storage() async {
    if (_root != null) return _root!;
    final folder = directory == null
        ? Directory('${(await getApplicationSupportDirectory()).path}/catpaw')
        : await directory!();
    await folder.create(recursive: true);
    // Node's permission checks use real paths (macOS /var is a symlink).
    return _root = Directory(await folder.resolveSymbolicLinks());
  }

  Future<Uri> _ensure() async {
    final closing = _closing;
    if (closing != null) await closing;
    if (_needsReset) {
      final base =
          _base ??
          await (_starting ??= _start().whenComplete(() => _starting = null));
      await _resetEmbedded(base);
    }
    if (_base != null) return _base!;
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  Future<Uri> _start() async {
    final epoch = _generation;
    final root = await _storage();
    await root.create(recursive: true);
    final script = File('${root.path}/host.cjs');
    if (bootstrap != null) {
      await File(bootstrap!).copy(script.path);
      final fetch = File('${File(bootstrap!).parent.path}/fetch.cjs');
      if (await fetch.exists()) await fetch.copy('${root.path}/fetch.cjs');
    } else {
      await script.writeAsString(
        await rootBundle.loadString('assets/catpaw/host.cjs'),
        flush: true,
      );
      await File('${root.path}/fetch.cjs').writeAsString(
        await rootBundle.loadString('assets/catpaw/fetch.cjs'),
        flush: true,
      );
    }
    await _stageDrpyAssets(root);
    await _syncNetdiskConfig(root);
    final ready = File('${root.path}/ready.json');
    if (Platform.isIOS) {
      await const MethodChannel('marco_movie/catpaw').invokeMethod('start', {
        'root': root.path,
        'script': script.path,
        'ready': ready.path,
      });
    } else {
      if (await ready.exists()) await ready.delete();
      final app = File(Platform.resolvedExecutable).parent;
      final node =
          executable ??
          (Platform.isWindows
              ? '${app.path}/data/node/node.exe'
              : '${app.parent.path}/Frameworks/node/bin/node');
      if (!await File(node).exists())
        throw StateError('安装包缺少 CatPaw 本机运行组件，请安装完整版本');
      // Do not inherit developer credentials or NODE_OPTIONS into imported user code.
      final environment = <String, String>{
        if (Platform.environment['SystemRoot'] case final String value)
          'SystemRoot': value,
        'HOME': root.path,
        'USERPROFILE': root.path,
        'TMPDIR': root.path,
        'TEMP': root.path,
        'TMP': root.path,
      };
      final process = await Process.start(
        node,
        [
          if (Platform.isMacOS) '--jitless',
          '--experimental-permission',
          '--allow-worker',
          '--allow-fs-read=${root.path}',
          '--allow-fs-write=${root.path}',
          script.path,
          root.path,
          ready.path,
        ],
        workingDirectory: root.path,
        environment: environment,
        includeParentEnvironment: false,
      );
      _process = process;
      process.stdout.drain<void>();
      process.stderr.drain<void>();
      process.exitCode.then((_) {
        if (_process == process) {
          _process = null;
          _base = null;
        }
      });
    }
    final deadline = DateTime.now().add(const Duration(seconds: 12));
    while (DateTime.now().isBefore(deadline) && epoch == _generation) {
      if (await ready.exists()) {
        final state = jsonDecode(await ready.readAsString());
        final port = state['port'], secret = state['secret'];
        if (port is int &&
            port > 0 &&
            port < 65536 &&
            secret is String &&
            RegExp(r'^[a-f0-9]{64}$').hasMatch(secret)) {
          final base = Uri.parse('http://127.0.0.1:$port/$secret');
          if (epoch != _generation) break;
          _base = base;
          return base;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    await close();
    throw StateError('CatPaw 本机服务启动失败');
  }

  /// Stage only pinned flat runtime files, using the same path in packaged and
  /// explicitly supplied bootstrap modes. Never accept source-provided assets.
  Future<void> _stageDrpyAssets(Directory root) async {
    Future<List<int>> asset(String name) async {
      if (bootstrap != null) {
        return File('${File(bootstrap!).parent.path}/$name').readAsBytes();
      }
      final data = await rootBundle.load('assets/catpaw/$name');
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    }

    final manifestBytes = await asset('drpy-assets.json');
    final manifest = jsonDecode(utf8.decode(manifestBytes));
    if (manifest is! Map ||
        manifest['version'] != 1 ||
        manifest['runtime'] != drpyRuntime ||
        manifest['files'] is! List) {
      throw const FormatException('DRPY 本机运行组件清单无效');
    }
    final entries = manifest['files'] as List;
    if (entries.isEmpty || entries.length > 32) {
      throw const FormatException('DRPY 本机运行组件数量无效');
    }
    final seen = <String>{};
    final verified = <String, List<int>>{};
    var total = 0;
    for (final entry in entries) {
      if (entry is! Map ||
          entry['name'] is! String ||
          entry['sha256'] is! String ||
          entry['bytes'] is! int) {
        throw const FormatException('DRPY 本机运行组件条目无效');
      }
      final name = entry['name'] as String;
      final size = entry['bytes'] as int;
      if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]*$').hasMatch(name) ||
          name == 'host.cjs' ||
          name == 'fetch.cjs' ||
          name == 'ready.json' ||
          name == 'drpy-assets.json' ||
          !seen.add(name) ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(entry['sha256']) ||
          size < 0 ||
          size > _maxBundleBytes ||
          (total += size) > _maxBundleBytes) {
        throw const FormatException('DRPY 本机运行组件路径或大小无效');
      }
      final bytes = await asset(name);
      if (bytes.length != size ||
          sha256.convert(bytes).toString() != entry['sha256']) {
        throw const FormatException('DRPY 本机运行组件校验失败');
      }
      verified[name] = bytes;
    }
    if (!seen.containsAll(const [
      'drpy-worker.cjs',
      'drpy-http.cjs',
      'drpy-schema.cjs',
      'drpy-core.js',
      'drpy-dependencies.js',
    ])) {
      throw const FormatException('DRPY 本机运行组件不完整');
    }
    for (final entry in verified.entries) {
      await _writeAtomic(File('${root.path}/${entry.key}'), entry.value);
    }
    await _writeAtomic(File('${root.path}/drpy-assets.json'), manifestBytes);
  }

  Future<void> _syncNetdiskConfig(Directory root) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final quarkRaw = (prefs.getString('mm_netdisk_cred_quark_v1') ?? '').trim();
      final quarkCookie = QuarkAccountSession.tryParseCredential(quarkRaw)?.cookie ?? quarkRaw;
      final ucCookie = (prefs.getString('mm_netdisk_cred_uc_v1') ?? '').trim();
      final baiduCookie = (prefs.getString('mm_netdisk_cred_baidu_v1') ?? '').trim();
      final cfgFile = File('${root.path}/wexfnwconfig.json');
      if (quarkCookie.isEmpty && ucCookie.isEmpty && baiduCookie.isEmpty && !await cfgFile.exists()) {
        return;
      }
      final payload = jsonEncode({
        'pan': {
          'quark': {'cookie': quarkCookie},
          'uc': {'cookie': ucCookie},
          'baidu': {'cookie': baiduCookie},
        },
      });
      if (_lastSyncedPanJson == payload && await cfgFile.exists()) return;
      await _writeAtomic(cfgFile, utf8.encode('$payload\n'));
      _lastSyncedPanJson = payload;
    } catch (_) {}
  }

  static Future<void> _writeAtomic(File file, List<int> bytes) async {
    final staging = File(
      '${file.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await staging.writeAsBytes(bytes, flush: true);
      await staging.rename(file.path);
    } finally {
      if (await staging.exists()) await staging.delete();
    }
  }

  static Map<String, dynamic> _drpyManifest(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > _maxBundleBytes) {
      throw const FormatException('DRPY 规则包超过大小限制');
    }
    final value = jsonDecode(utf8.decode(bytes));
    const fields = [
      'version',
      'kind',
      'runtime',
      'sourceId',
      'origin',
      'rule',
      'headers',
      'requestTimeoutMs',
      'modules',
    ];
    if (value is! Map<String, dynamic> ||
        value['version'] != 1 ||
        value.keys.any((key) => !fields.contains(key)) ||
        value['kind'] != 'drpy' ||
        value['runtime'] != drpyRuntime ||
        value['sourceId'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['sourceId']) ||
        value['origin'] is! String ||
        value['rule'] is! String ||
        (value['rule'] as String).trim().isEmpty ||
        value['headers'] is! Map ||
        (value['requestTimeoutMs'] ?? 10000) is! int ||
        (value['requestTimeoutMs'] ?? 10000) < 100 ||
        (value['requestTimeoutMs'] ?? 10000) > 15000) {
      throw const FormatException('DRPY 规则包格式无效');
    }
    final origin = Uri.tryParse(value['origin']);
    if (origin == null ||
        !const ['http', 'https', 'pkg'].contains(origin.scheme) ||
        origin.host.isEmpty ||
        origin.userInfo.isNotEmpty ||
        origin.hasFragment ||
        (value['origin'] as String).length > 8192 ||
        utf8.encode(value['rule']).length > 6 * 1024 * 1024) {
      throw const FormatException('DRPY 规则来源无效');
    }
    final headers = value['headers'] as Map;
    final modules = value['modules'] ?? <String, String>{};
    if (modules is! Map || modules.length > 32) {
      throw const FormatException('DRPY 本地模块格式或数量无效');
    }
    var moduleBytes = 0;
    for (final module in modules.entries) {
      final uri = module.key is String ? Uri.tryParse(module.key) : null;
      if (origin.scheme != 'pkg' ||
          uri == null ||
          uri.scheme != 'pkg' ||
          uri.authority != origin.authority ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          uri.normalizePath().toString() != module.key ||
          (module.key as String).length > 8192 ||
          module.value is! String ||
          (moduleBytes += utf8.encode(module.value).length) > 6 * 1024 * 1024) {
        throw const FormatException('DRPY 本地模块路径或大小无效');
      }
    }
    if (headers.length > 64) throw const FormatException('DRPY 请求头数量过多');
    for (final header in headers.entries) {
      if (header.key is! String ||
          header.value is! String ||
          !RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$").hasMatch(header.key) ||
          (header.value as String).length > 8192 ||
          const [
            'host',
            'content-length',
            'connection',
            'transfer-encoding',
          ].contains((header.key as String).toLowerCase()) ||
          RegExp(r'[\r\n\x00]').hasMatch(header.value)) {
        throw const FormatException('DRPY 请求头格式无效');
      }
    }
    return value;
  }

  /// The address commits to the exact UTF-8 manifest bytes, including whitespace.
  Future<String> installDrpy(Object manifest) async {
    final List<int> bytes;
    if (manifest is List<int>) {
      bytes = List<int>.of(manifest);
    } else if (manifest is Map<String, dynamic>) {
      bytes = utf8.encode(jsonEncode(manifest));
    } else {
      throw const FormatException('DRPY 规则包需要 JSON 对象或 UTF-8 字节');
    }
    _drpyManifest(bytes);
    final hash = sha256.convert(bytes).toString();
    final root = await _storage();
    final folder = Directory('${root.path}/$hash');
    await folder.create(recursive: true);
    final file = File('${folder.path}/drpy.json');
    if (await file.exists()) {
      if (await file.length() > _maxBundleBytes ||
          sha256.convert(await file.readAsBytes()).toString() != hash) {
        throw const FormatException('DRPY 本机规则包已改变，请重新导入');
      }
    } else {
      await _writeAtomic(file, bytes);
    }
    return 'catpaw://$hash/api/drpy';
  }

  /// Extract data from one explicitly supported plugin artifact. Download and
  /// declared MD5 validation belong to the caller; this boundary never receives
  /// the remote address, request headers, or credentials used to acquire it.
  Future<Map<String, dynamic>> bootstrapGuard(
    List<int> bytes, {
    String adapter = 'dm84-v1',
    String? extension,
    Completer<void>? cancellation,
  }) async {
    _checkCancellation(cancellation);
    if (!const [
          'dm84-v1',
          'auete-v1',
          'bttwoo-v1',
          't4-v1',
          'fy-v1',
        ].contains(adapter) ||
        bytes.isEmpty ||
        bytes.length > _maxBundleBytes ||
        bytes.any((b) => b < 0 || b > 255)) {
      throw const FormatException('插件适配器或文件大小无效');
    }
    if (adapter == 't4-v1'
        ? extension == null ||
              extension.trim().isEmpty ||
              utf8.encode(extension).length > 16 * 1024
        : extension != null) {
      throw const FormatException('插件扩展配置无效');
    }
    final artifact = Uint8List.fromList(bytes);
    final hash = sha256.convert(artifact).toString();
    final root = await _withCancellation(_storage(), cancellation);
    _checkCancellation(cancellation);
    final folder = Directory('${root.path}/imports');
    await _withCancellation(folder.create(recursive: true), cancellation);
    _checkCancellation(cancellation);
    final file = File('${folder.path}/$hash.jar');
    if (await file.exists()) {
      if (await file.length() > _maxBundleBytes ||
          sha256.convert(await file.readAsBytes()).toString() != hash) {
        throw const FormatException('本机插件文件校验失败');
      }
    } else {
      await _withCancellation(_writeAtomic(file, artifact), cancellation);
    }
    _checkCancellation(cancellation);
    final base = await _withCancellation(_ensure(), cancellation);
    _checkCancellation(cancellation);
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    var backoffMs = 80;
    while (true) {
      try {
        return await _requestGuardBootstrap(
          base,
          hash,
          adapter,
          extension,
          cancellation,
        );
      } on GuardBootstrapException catch (error) {
        if (error.code != 'bootstrap_busy' ||
            !DateTime.now().isBefore(deadline)) {
          rethrow;
        }
        final remaining = deadline.difference(DateTime.now()).inMilliseconds;
        if (remaining <= 0) rethrow;
        await _withCancellation(
          Future<void>.delayed(
            Duration(
              milliseconds: remaining < backoffMs ? remaining : backoffMs,
            ),
          ),
          cancellation,
        );
        backoffMs = (backoffMs * 2).clamp(80, 250);
      }
    }
  }

  Future<Map<String, dynamic>> _requestGuardBootstrap(
    Uri base,
    String hash,
    String adapter,
    String? extension,
    Completer<void>? cancellation,
  ) async {
    _checkCancellation(cancellation);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    var finished = false;
    cancellation?.future.then((_) {
      if (!finished) client.close(force: true);
    });
    final timer = Timer(
      const Duration(seconds: 10),
      () => client.close(force: true),
    );
    try {
      final request = await _withCancellation(
        client.postUrl(base.replace(path: '${base.path}/_port-bootstrap')),
        cancellation,
      );
      _checkCancellation(cancellation);
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      final body = utf8.encode(
        jsonEncode({
          'version': 1,
          'adapter': adapter,
          'artifactHash': hash,
          if (extension != null) 'extension': extension,
        }),
      );
      request.contentLength = body.length;
      request.add(body);
      final response = await _withCancellation(request.close(), cancellation);
      final output = BytesBuilder(copy: false);
      await for (final chunk in response) {
        _checkCancellation(cancellation);
        if (output.length + chunk.length > _maxBundleBytes) {
          throw const FormatException('插件解析响应过大');
        }
        output.add(chunk);
      }
      _checkCancellation(cancellation);
      final decoded = jsonDecode(utf8.decode(output.takeBytes()));
      if (response.statusCode != 200) {
        const errors = {
          'guard_artifact_unsupported': '当前插件版本尚未完成本机移植',
          'guard_artifact_integrity': '插件文件校验失败',
          'guard_artifact_invalid': '插件包格式无效',
          'bootstrap_busy': '插件解析正在进行，请稍后重试',
          'bootstrap_timeout': '插件解析超时',
          'bootstrap_request': '插件解析请求无效',
        };
        final code = decoded is Map ? decoded['error'] : null;
        throw GuardBootstrapException(
          errors.containsKey(code) ? code as String : 'bootstrap_http',
          errors.containsKey(code)
              ? '${errors[code]}（$code）'
              : '插件解析失败（HTTP ${response.statusCode}）',
        );
      }
      if (decoded is! Map<String, dynamic> ||
          decoded['version'] != 1 ||
          decoded.keys.any(
            (key) => !const ['version', 'rule', 'origin'].contains(key),
          ) ||
          decoded['rule'] is! String ||
          decoded['origin'] is! String) {
        throw const FormatException('插件解析结果格式无效');
      }
      final rule = decoded['rule'] as String;
      final origin = decoded['origin'] as String;
      final uri = Uri.tryParse(origin);
      if (rule.trim().isEmpty ||
          utf8.encode(rule).length > 6 * 1024 * 1024 ||
          origin.length > 8192 ||
          uri == null ||
          !const ['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasFragment) {
        throw const FormatException('插件解析规则或来源无效');
      }
      return decoded;
    } catch (_) {
      _checkCancellation(cancellation);
      rethrow;
    } finally {
      finished = true;
      timer.cancel();
      client.close(force: true);
    }
  }

  static Uri _drpyAddress(String address) {
    final uri = Uri.parse(address);
    if (uri.scheme != 'catpaw' ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(uri.host) ||
        uri.path != '/api/drpy' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('DRPY 本机地址无效');
    }
    return uri;
  }

  Future<String> callDrpy(
    String address,
    String method,
    List<Object?> args, {
    Completer<void>? cancellation,
  }) async {
    _checkCancellation(cancellation);
    _drpyAddress(address);
    if (!const [
      'home',
      'homeVod',
      'category',
      'search',
      'detail',
      'play',
    ].contains(method)) {
      throw const FormatException('DRPY 调用方法无效');
    }
    final body = utf8.encode(
      jsonEncode({'version': 1, 'method': method, 'args': args}),
    );
    if (body.length > 6 * 1024 * 1024)
      throw const FormatException('DRPY 调用参数过大');
    final releasing = _releasingDrpy[address];
    if (releasing != null) await _withCancellation(releasing, cancellation);
    _checkCancellation(cancellation);
    _activeDrpy[address] = (_activeDrpy[address] ?? 0) + 1;
    var opened = false;
    try {
      final raw = await _request(
        address,
        method: 'POST',
        body: body,
        rewriteUrls: true,
        requestTimeout: const Duration(seconds: 45),
        cancellation: cancellation,
        onRequestOpened: () => opened = true,
      );
      if (jsonDecode(raw) is! Map)
        throw const FormatException('DRPY 返回内容不是 JSON 对象');
      return raw;
    } finally {
      final remaining = (_activeDrpy[address] ?? 1) - 1;
      if (remaining > 0) {
        _activeDrpy[address] = remaining;
      } else {
        _activeDrpy.remove(address);
        if (opened && cancellation?.isCompleted == true) {
          // A new call must wait until the older cancelled call's cleanup ends.
          late final Future<void> release;
          release = releaseDrpy(address).catchError((Object _) {}).whenComplete(
            () {
              if (identical(_releasingDrpy[address], release))
                _releasingDrpy.remove(address);
            },
          );
          _releasingDrpy[address] = release;
        }
      }
    }
  }

  static void _checkCancellation(Completer<void>? cancellation) {
    if (cancellation?.isCompleted == true) throw const FormatException('搜索已取消');
  }

  static Future<T> _withCancellation<T>(
    Future<T> task,
    Completer<void>? cancellation,
  ) {
    if (cancellation?.isCompleted == true) {
      unawaited(task.then<void>((_) {}, onError: (Object _) {}));
    }
    _checkCancellation(cancellation);
    if (cancellation == null) return task;
    return Future.any([
      task,
      cancellation.future.then<T>((_) => throw const FormatException('搜索已取消')),
    ]);
  }

  Future<void> releaseDrpy(String address) async {
    final uri = _drpyAddress(address);
    await _request(
      uri.replace(path: '/_release').toString(),
      method: 'POST',
      rewriteUrls: false,
    );
  }

  Future<String> install(String code) async {
    if (!isBundle(code)) throw const FormatException('没有 CatPaw 服务入口');
    final bytes = utf8.encode(code);
    if (bytes.length > 16 * 1024 * 1024)
      throw const FormatException('CatPaw 服务包超过大小限制');
    final hash = sha256.convert(bytes).toString();
    final root = await _storage();
    final folder = Directory('${root.path}/$hash');
    await folder.create(recursive: true);
    final file = File('${folder.path}/index.cjs');
    if (!await file.exists()) {
      final staging = File('${folder.path}/index.tmp');
      await staging.writeAsBytes(bytes, flush: true);
      await staging.rename(file.path);
    }
    final raw = await read('catpaw://$hash/t4');
    final config = jsonDecode(raw);
    if (config is! Map || config['sites'] is! List)
      throw const FormatException('CatPaw 没有返回线路列表');
    final sites = <Map<String, dynamic>>[];
    for (final row in config['sites']) {
      if (row is! Map) continue;
      final api = Uri.tryParse('${row['api'] ?? ''}');
      if (api?.scheme != 'catpaw' ||
          api?.host != hash ||
          !api!.path.startsWith('/api/'))
        continue;
      sites.add({
        ...row.map((k, v) => MapEntry(k.toString(), v)),
        'key': 'paw_${row['key'] ?? api.path}',
        'type': 4,
      });
    }
    if (sites.isEmpty) throw const FormatException('CatPaw 没有可用的本机线路');
    return jsonEncode({'sites': sites});
  }

  Future<Uri> resolve(String address, {Completer<void>? cancellation}) async {
    _checkCancellation(cancellation);
    final generation = _generation;
    final logical = Uri.parse(address);
    if (logical.scheme != 'catpaw' ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(logical.host) ||
        logical.userInfo.isNotEmpty ||
        logical.hasPort ||
        logical.pathSegments.any(
          (p) => p == '..' || p == '.' || p.contains('/'),
        )) {
      throw const FormatException('CatPaw 本机地址无效');
    }
    final root = await _storage();
    _checkCancellation(cancellation);
    final drpy = File('${root.path}/${logical.host}/drpy.json');
    if (await drpy.exists()) {
      if (!const ['/api/drpy', '/_release', '/proxy'].contains(logical.path) ||
          (logical.hasQuery && logical.path != '/proxy') ||
          logical.hasFragment ||
          await drpy.length() > _maxBundleBytes) {
        throw const FormatException('DRPY 本机地址无效');
      }
      final bytes = await drpy.readAsBytes();
      _checkCancellation(cancellation);
      if (sha256.convert(bytes).toString() != logical.host) {
        throw const FormatException('DRPY 本机规则包校验失败');
      }
      _drpyManifest(bytes);
    } else if (!await File('${root.path}/${logical.host}/index.cjs').exists()) {
      throw StateError('此设备没有对应的 CatPaw 服务包，请重新导入原订阅');
    } else if (logical.path.startsWith('/api/spider/')) {
      await _syncNetdiskConfig(root);
    }
    _checkCancellation(cancellation);
    if (generation != _generation) throw StateError('CatPaw 本机服务已关闭');
    final base = await _withCancellation(_ensure(), cancellation);
    _checkCancellation(cancellation);
    if (generation != _generation) throw StateError('CatPaw 本机服务已关闭');
    return base.replace(
      path: '${base.path}/${logical.host}${logical.path}',
      query: logical.hasQuery ? logical.query : null,
    );
  }

  Future<Uri> settings(String address) async {
    final logical = Uri(
      scheme: 'catpaw',
      host: Uri.parse(address).host,
      path: '/_manage',
    );
    final result = jsonDecode(await read(logical.toString(), method: 'POST'));
    final url = Uri.tryParse('${result['url'] ?? ''}');
    if (url == null ||
        url.scheme != 'http' ||
        url.host != '127.0.0.1' ||
        !url.path.startsWith('/authorize/')) {
      throw StateError('CatPaw 配置页面启动失败');
    }
    return url;
  }

  Future<String> read(String address, {String method = 'GET'}) async {
    return _request(address, method: method);
  }

  Future<String> _request(
    String address, {
    String method = 'GET',
    List<int>? body,
    bool rewriteUrls = true,
    Duration requestTimeout = const Duration(seconds: 35),
    Completer<void>? cancellation,
    void Function()? onRequestOpened,
  }) async {
    _checkCancellation(cancellation);
    final logical = Uri.parse(address);
    final url = await _withCancellation(
      resolve(address, cancellation: cancellation),
      cancellation,
    );
    _checkCancellation(cancellation);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    var finished = false;
    cancellation?.future.then((_) {
      if (!finished) client.close(force: true);
    });
    final timer = Timer(requestTimeout, () => client.close(force: true));
    try {
      final request = await _withCancellation(
        client.openUrl(method, url),
        cancellation,
      );
      _checkCancellation(cancellation);
      onRequestOpened?.call();
      request.followRedirects = false;
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.contentLength = body.length;
        request.add(body);
      }
      final response = await request.close();
      _checkCancellation(cancellation);
      if (logical.path == '/api/drpy' && response.statusCode == 422) {
        final errorBytes = BytesBuilder(copy: false);
        await for (final chunk in response) {
          _checkCancellation(cancellation);
          if (errorBytes.length + chunk.length > 16 * 1024) {
            throw const FormatException('片源错误响应过大');
          }
          errorBytes.add(chunk);
        }
        _checkCancellation(cancellation);
        Object? error;
        try {
          error = jsonDecode(utf8.decode(errorBytes.takeBytes()));
        } catch (_) {}
        const messages = {
          'drpy_verification_required': '此片源需要完成网站验证码，暂时无法加载',
          'drpy_action_invalid': '验证码已失效或格式不正确，请刷新后重试',
          'drpy_verification_unavailable': '暂时无法获取验证码图片，请稍后重试',
          'drpy_unsupported_filter': '此片源不支持当前筛选条件',
          'drpy_invalid_id': '此片源的影片标识无效，请重新打开影片',
          'drpy_local_proxy_not_supported': '此片源需要的本地代理暂不支持',
          'drpy_media_protocol': '此片源返回的播放地址协议暂不支持',
          'drpy_media_unresolved': '此片源暂未解析出可播放地址',
          'drpy_source_origin': '此片源返回了不支持的跨站目录',
          'drpy_source_unavailable': '此片源暂时无法访问',
          'drpy_source_response': '此片源返回了无法识别的数据',
          'drpy_crypto_invalid': '此片源的加密响应暂不兼容',
          'drpy_authentication_required': '此片源的访问认证尚未通过',
          'drpy_filter_not_supported': '此片源不支持当前筛选条件',
          'drpy_local_module_missing': '本地规则包缺少依赖文件，请导入完整的规则包',
        };
        final code = error is Map ? error['error'] : null;
        if (code is String && messages.containsKey(code)) {
          throw DrpySourceException(code, messages[code]!);
        }
      }
      if (response.statusCode != 200)
        throw StateError('CatPaw 线路请求失败（HTTP ${response.statusCode}）');
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        _checkCancellation(cancellation);
        if (bytes.length + chunk.length > 16 * 1024 * 1024)
          throw const FormatException('CatPaw 响应过大');
        bytes.add(chunk);
      }
      final base = _base!;
      final raw = utf8.decode(bytes.takeBytes());
      _checkCancellation(cancellation);
      return rewriteUrls
          ? raw.replaceAll(
              '${base.toString()}/${logical.host}',
              'catpaw://${logical.host}',
            )
          : raw;
    } catch (_) {
      _checkCancellation(cancellation);
      rethrow;
    } finally {
      finished = true;
      timer.cancel();
      client.close(force: true);
    }
  }

  Future<void> _resetEmbedded(Uri base) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    final timer = Timer(
      const Duration(seconds: 5),
      () => client.close(force: true),
    );
    try {
      final request = await client.postUrl(
        base.replace(path: '${base.path}/_reset'),
      );
      final response = await request.close();
      await response.drain<void>();
      if (response.statusCode != 200) throw StateError('本机线路正在清理，请稍后重试');
      _needsReset = false;
    } finally {
      timer.cancel();
      client.close(force: true);
    }
  }

  Future<void> close() {
    if (_closing != null) return _closing!;
    late final Future<void> task;
    task = _close().whenComplete(() {
      if (identical(_closing, task)) _closing = null;
    });
    return _closing = task;
  }

  Future<void> _close() async {
    _generation++;
    final base = _base;
    _base = null;
    if (Platform.isIOS && base != null) {
      _needsReset = true;
      try {
        await _resetEmbedded(base);
      } catch (_) {
        // The next request must finish cleanup before loading any new sources.
      }
    }
    final process = _process;
    _process = null;
    if (process != null) {
      await process.stdin.close();
      try {
        await process.exitCode.timeout(const Duration(seconds: 3));
      } catch (_) {
        process.kill();
      }
    }
  }
}
