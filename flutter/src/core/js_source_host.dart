import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'js_source_syntax.dart';
import 'script_proxy_protocol.dart';
import 'script_proxy_server.dart';

import 'package:flutter/services.dart';
import 'package:quickjs_engine/quickjs_engine.dart';

/// Source-scoped ES module / Cat / Python host. Each retained source owns one
/// isolated runtime; no host filesystem, process, Android, or account APIs are exposed.
class JsSourceHost {
  static const maxBytes = 6 * 1024 * 1024;

  static bool isCommonJs(String source) =>
      JsSourceSyntax(source).hasCommonJsExports;

  static bool isEsModule(String source) => JsSourceSyntax(source).isModule;

  static bool hasSpiderExports(String source) =>
      JsSourceSyntax(source).hasSpiderExports;

  static bool hasDrpyRule(String source) => JsSourceSyntax(source).hasDrpyRule;

  static bool isCatSpider(String source) => JsSourceSyntax(source).hasCatSpider;

  /// Static dependencies only: dynamic import() needs a separately loaded module.
  static Iterable<String> esModuleReferences(String source) =>
      JsSourceSyntax(source).references;

  /// Preload bare require('literal') calls, including template expressions.
  /// Template text and computed module names are not static dependencies.
  static Iterable<String> commonJsReferences(String source) =>
      _CommonJsReferenceScanner(source).scan();

  static final _sessions = <String, _SourceWorker>{};
  static Future<List<String>>? _catvodAssets;
  static final _playbackPins = <String, Set<Object>>{};
  static ScriptProxyServer? _proxyServer;
  static int _generation = 0;
  static int get generation => _generation;
  static const _maxSessions = 6;
  static Completer<void> _capacityChanged = Completer<void>();

  static void _notifyCapacity() {
    final changed = _capacityChanged;
    _capacityChanged = Completer<void>();
    changed.complete();
  }

  /// A paused player still owns its source's state and proxy callbacks. An
  /// identity token makes a late release harmless after removal/re-import.
  static void Function() pinForPlayback(String sessionKey) {
    final pins = _playbackPins.putIfAbsent(sessionKey, () => <Object>{});
    final token = Object();
    pins.add(token);
    return () {
      if (!pins.remove(token)) return;
      if (pins.isEmpty && identical(_playbackPins[sessionKey], pins)) {
        _playbackPins.remove(sessionKey);
      }
      _notifyCapacity();
    };
  }

  /// Only this live source's capability route may receive local-player header
  /// adaptation. An unrelated loopback service or stale URL is never included.
  static bool ownsProxyUrl(String sessionKey, Uri uri) {
    final worker = _sessions[sessionKey];
    final proxy = worker?._proxy;
    if (worker == null ||
        worker._closed ||
        proxy == null ||
        !proxy.isActive ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.scheme != proxy.url.scheme ||
        uri.host != proxy.url.host ||
        uri.port != proxy.url.port) {
      return false;
    }
    final path = uri.pathSegments;
    final expected = proxy.url.pathSegments;
    return path.length >= 3 &&
        path[0] == expected[0] &&
        path[1] == expected[1] &&
        !path.any(
          (part) =>
              part == '.' ||
              part == '..' ||
              RegExp(
                r'[/\\\x00-\x1f\x7f]|%(?:2e|2f|5c|00)',
                caseSensitive: false,
              ).hasMatch(part),
        );
  }

  /// Removal is synchronous; teardown follows on each runtime's owning isolate.
  /// A loader started before this boundary cannot recreate a deleted session.
  static Future<void> retainSessions(Set<String> keys) {
    _generation++;
    _playbackPins.removeWhere((key, _) => !keys.contains(key));
    final removed = _sessions.keys.where((key) => !keys.contains(key)).toList();
    final closing = <Future<void>>[];
    for (final key in removed) {
      closing.add(_sessions.remove(key)!.close());
    }
    _notifyCapacity();
    return Future.wait(closing);
  }

  static Future<void> closeAll() async {
    final server = _proxyServer;
    _proxyServer = null;
    await retainSessions({});
    await server?.close();
  }

  static Future<String?> callCached({
    required String sessionKey,
    required String method,
    required List<Object?> arguments,
    Duration budget = const Duration(seconds: 12),
    Completer<void>? cancellation,
  }) async {
    final worker = _sessions.remove(sessionKey);
    if (worker == null || worker._closed) return null;
    _sessions[sessionKey] = worker; // LRU: active workers are never evicted.
    return worker.invoke(method, arguments, budget, cancellation);
  }

  static Future<String> invoke({
    required String entry,
    required Map<String, String> modules,
    required String method,
    required List<Object?> arguments,
    Object? extension,
    String? rawExtension,
    Map<String, String> headers = const {},
    Duration budget = const Duration(seconds: 12),
    List<String> pythonPrelude = const [],
    Map<String, Object?> pythonPackage = const {},
    String? sessionKey,
    int? expectedGeneration,
    bool catDetails = false,
    Completer<void>? cancellation,
  }) async {
    if (cancellation?.isCompleted == true) throw StateError('脚本操作已取消');
    final startedGeneration = expectedGeneration ?? _generation;
    final interop = await rootBundle.loadString(
      'assets/js-host/module-interop.js',
    );
    final ownedModules = Map<String, String>.from(modules);
    var catvod = false;
    if (pythonPrelude.isEmpty) {
      for (final item in modules.entries) {
        if (item.key == 'catvod' ||
            item.key.startsWith('catvod:') ||
            item.key.startsWith('marco:')) {
          throw const FormatException('脚本不能覆盖内置宿主模块');
        }
        for (final ref in esModuleReferences(item.value)) {
          if (ref == 'catvod') {
            catvod = true;
          } else if (ref.startsWith('catvod:') || ref.startsWith('marco:')) {
            throw const FormatException('当前脚本需要 CatVod 宿主模块，该接口尚未适配');
          }
        }
      }
      if (catvod) {
        final assets = await (_catvodAssets ??= Future.wait([
          rootBundle.loadString('assets/js-host/catvod.mjs'),
          rootBundle.loadString('assets/js-host/crypto-js.js'),
        ]));
        ownedModules['catvod'] = assets[0];
        ownedModules['marco:catvod-crypto'] =
            'const module={exports:{}};let exports=module.exports;\n'
            '${assets[1]}\nexport default module.exports;';
      }
    }
    void check() {
      if (cancellation?.isCompleted == true ||
          startedGeneration != _generation) {
        throw StateError('脚本会话已失效');
      }
    }

    check();
    if (sessionKey != null) {
      final waiting = Stopwatch()..start();
      if (_sessions[sessionKey]?._closed == true) _sessions.remove(sessionKey);
      while (!_sessions.containsKey(sessionKey) &&
          _sessions.length >= _maxSessions) {
        final idle = _sessions.entries.where(
          (item) => !item.value.busy && !_playbackPins.containsKey(item.key),
        );
        if (idle.isEmpty) {
          final remaining = budget - waiting.elapsed;
          if (remaining <= Duration.zero) throw TimeoutException('等待脚本运行环境超时');
          await Future.any([
            _capacityChanged.future,
            if (cancellation != null) cancellation.future,
          ]).timeout(remaining);
          check();
          continue;
        }
        await _sessions.remove(idle.first.key)!.close();
        check();
      }
    }
    final worker = sessionKey == null ? null : _sessions[sessionKey];
    final selected =
        worker ??
        _SourceWorker([
          entry,
          ownedModules,
          extension,
          Map<String, String>.from(headers),
          List<String>.from(pythonPrelude),
          interop,
          Map<String, Object?>.from(pythonPackage),
          rawExtension,
        ], catDetails: catDetails);
    if (sessionKey != null) _sessions[sessionKey] = selected;
    try {
      return await selected.invoke(method, arguments, budget, cancellation);
    } finally {
      if (sessionKey == null) await selected.close();
    }
  }

  static String _resolveCommonJsModule(
    String parent,
    String ref,
    Map<String, String> modules,
  ) {
    if (!ref.startsWith('.') &&
        !ref.startsWith('http://') &&
        !ref.startsWith('https://') &&
        !ref.startsWith('pkg://') &&
        !ref.startsWith('file://')) {
      throw StateError('CommonJS 不提供 Node 内置模块：$ref');
    }
    final uri = Uri.parse(parent).resolve(ref);
    final resolved = uri.toString();
    for (final candidate in [
      resolved,
      uri.replace(path: '${uri.path}.js').toString(),
      uri.replace(path: '${uri.path}.json').toString(),
      uri.replace(path: '${uri.path}/index.js').toString(),
    ]) {
      if (modules.containsKey(candidate)) return candidate;
    }
    throw StateError('脚本依赖未加载：$ref');
  }
}

/// All commands for one source are serialized. Different sources run independently.
class _SourceWorker {
  final List<Object?> configuration;
  final bool catDetails;
  Future<SendPort>? _ready;
  Future<void> _tail = Future.value();
  Future<void>? _closing;
  final _exited = Completer<void>();
  final _exitEvents = StreamController<void>.broadcast(sync: true);
  bool _closed = false;
  int _pending = 0;
  int _nextId = 0;
  ScriptProxyRegistration? _proxy;
  bool get busy => _pending > 0;

  _SourceWorker(this.configuration, {required this.catDetails});

  Future<SendPort> _start() => _ready ??= () async {
    final ready = ReceivePort();
    final lifecycle = ReceivePort();
    lifecycle.listen((_) {
      _closed = true;
      unawaited(_proxy?.unregister());
      if (!_exited.isCompleted) _exited.complete();
      _exitEvents.add(null);
      unawaited(_exitEvents.close());
      JsSourceHost._notifyCapacity();
      lifecycle.close();
    });
    try {
      final proxy = await (JsSourceHost._proxyServer ??= ScriptProxyServer())
          .register((request) async {
            final params = <String, String>{
              for (final entry in request.queryParametersAll.entries)
                entry.key: entry.value.last,
              ...request.headers,
            };
            final upstreamOrigin = params.remove('x-marcomovie-proxy-origin');
            if (upstreamOrigin != null) params['origin'] = upstreamOrigin;
            if (request.path != '/proxy') {
              params.putIfAbsent('path', () => request.path);
            }
            final result = await invoke(
              'proxy',
              [params],
              const Duration(seconds: 18),
              request.cancellation,
            );
            return ScriptProxyProtocol.decode(result);
          });
      _proxy = proxy;
      if (_closed) {
        await proxy.unregister();
        throw StateError('脚本会话已关闭');
      }
      final base = proxy.url.replace(
        queryParameters: {
          'do': (configuration[4] as List).isNotEmpty ? 'py' : 'js',
          'siteKey': proxy.url.pathSegments[1],
        },
      );
      await Isolate.spawn(
        _sourceWorkerMain,
        [
          ready.sendPort,
          [...configuration, base.toString()],
        ],
        onExit: lifecycle.sendPort,
        onError: lifecycle.sendPort,
      );
      return await _whileAlive(ready.first) as SendPort;
    } catch (_) {
      _closed = true;
      await _proxy?.unregister();
      if (!_exited.isCompleted) {
        _exited.complete();
        unawaited(_exitEvents.close());
      }
      lifecycle.close();
      JsSourceHost._notifyCapacity();
      rethrow;
    } finally {
      ready.close();
    }
  }();

  Future<dynamic> _whileAlive(Future<dynamic> result) async {
    if (_exited.isCompleted) throw StateError('脚本运行环境已退出');
    final ended = Completer<dynamic>();
    final listener = _exitEvents.stream.listen((_) {
      ended.completeError(StateError('脚本运行环境已退出'));
    });
    try {
      return await Future.any([result, ended.future]);
    } finally {
      // A Future listener cannot be detached. Keeping one on the worker's exit
      // future per call would retain completed results for the session's life.
      await listener.cancel();
    }
  }

  Future<String> invoke(
    String method,
    List<Object?> arguments,
    Duration budget,
    Completer<void>? cancellation,
  ) {
    if (_closed) return Future.error(StateError('脚本会话已关闭'));
    if (budget <= Duration.zero) return Future.error(ArgumentError('budget'));
    _pending++;
    final task = _tail.then((_) async {
      if (_closed || cancellation?.isCompleted == true) {
        throw StateError('脚本操作已取消');
      }
      final port = await _start();
      if (_closed || cancellation?.isCompleted == true) {
        throw StateError('脚本操作已取消');
      }
      final reply = ReceivePort();
      final id = ++_nextId;
      bool finished = false;
      cancellation?.future.then((_) {
        if (!finished) port.send(['cancel', id]);
      });
      try {
        port.send([
          'call',
          id,
          reply.sendPort,
          method,
          catDetails && method == 'detail' ? [arguments] : arguments,
          budget.inMilliseconds,
        ]);
        final result = await _whileAlive(reply.first) as List;
        final fatal = result.length > 2 && result[2] == true;
        if (fatal) {
          // Revoke synchronously when the reply arrives. Waiting for onExit
          // leaves a gap where a following call can target a closed port.
          _closed = true;
          unawaited(_proxy?.unregister());
          JsSourceHost._notifyCapacity();
        }
        if (cancellation?.isCompleted == true || (_closed && !fatal)) {
          throw StateError('脚本操作已取消');
        }
        if (result[0] != true) throw StateError(result[1].toString());
        return result[1] as String;
      } finally {
        finished = true;
        reply.close();
      }
    });
    _tail = task.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
      _pending--;
      if (!busy) JsSourceHost._notifyCapacity();
    });
    return task;
  }

  Future<void> close() {
    _closed = true;
    final revoke = _proxy?.unregister();
    return _closing ??= () async {
      await revoke;
      final ready = _ready;
      if (ready == null) {
        if (!_exited.isCompleted) _exited.complete();
        await _exitEvents.close();
        return;
      }
      final reply = ReceivePort();
      try {
        SendPort port;
        try {
          port = await ready;
        } catch (_) {
          return;
        }
        if (_exited.isCompleted) return;
        port.send(['close', reply.sendPort]);
        await Future.any([reply.first, _exited.future]);
      } finally {
        reply.close();
      }
    }();
  }
}

void _sourceWorkerMain(List<Object?> startup) {
  final messages = ReceivePort();
  final configuration = startup[1] as List;
  (startup[0] as SendPort).send(messages.sendPort);
  _JsRuntimeSession? session;
  int? activeId;
  bool closing = false;
  Future<void> tail = Future.value();
  messages.listen((dynamic value) {
    final command = value as List;
    if (command[0] == 'cancel') {
      if (activeId == command[1]) session?.cancel();
    } else if (command[0] == 'close') {
      closing = true;
      if (activeId != null) session?.cancel();
      tail.then((_) async {
        try {
          await session?.closeCatvod();
        } finally {
          try {
            session?.dispose();
          } finally {
            session = null;
            messages.close();
            (command[1] as SendPort).send(true);
          }
        }
      });
    } else if (command[0] == 'call') {
      tail = tail.then((_) async {
        final reply = command[2] as SendPort;
        try {
          if (closing) throw StateError('脚本会话已关闭');
          activeId = command[1] as int;
          session ??= _JsRuntimeSession(configuration);
          final result = await session!.invoke(
            command[3] as String,
            command[4] as List<Object?>,
            Duration(milliseconds: command[5] as int),
          );
          reply.send([true, result]);
        } catch (error) {
          final recovered =
              error is _ProxyCallCancelled && error.reusable && !closing;
          if (!recovered) {
            // Any runtime reset invalidates its proxy state, including a
            // catalogue/detail failure while a player still holds the URL.
            try {
              session?.dispose();
            } catch (_) {
              // Preserve the original failure and still revoke the worker.
            } finally {
              session = null;
            }
            closing = true;
            messages.close();
          }
          reply.send([false, error.toString(), !recovered]);
        } finally {
          activeId = null;
        }
      });
    }
  });
}

class _ProxyCallCancelled implements Exception {
  final bool reusable;
  const _ProxyCallCancelled(this.reusable);
  @override
  String toString() => '脚本代理请求已取消';
}

class _JsRuntimeSession {
  static const maxBytes = JsSourceHost.maxBytes;
  final String entry;
  final Map<String, String> modules;
  final Object? extension;
  final Map<String, String> headers;
  final List<String> pythonPrelude;
  final String interop;
  final Map<String, Object?> pythonPackage;
  final String? rawExtension;
  final String proxyBase;
  late final QuickJsRuntime2 runtime;
  late HttpClient client;
  final _catvodClients = <HttpClient>{};
  final watch = Stopwatch();
  late Duration budget;
  final requests = <Future<dynamic>>[];
  final _timers = <String, Timer>{};
  final _pythonMissingModules = <String>{};
  int _pythonModuleBytes = 0;
  int _networkRequestCount = 0;
  bool _initialized = false;
  bool _cancelled = false;
  bool _active = false;
  bool _recoverableProxyCall = false;

  _JsRuntimeSession(List configuration)
    : entry = configuration[0] as String,
      modules = configuration[1] as Map<String, String>,
      extension = configuration[2],
      headers = configuration[3] as Map<String, String>,
      pythonPrelude = configuration[4] as List<String>,
      interop = configuration[5] as String,
      pythonPackage = configuration[6] as Map<String, Object?>,
      rawExtension = configuration[7] as String?,
      proxyBase = configuration[8] as String {
    runtime = QuickJsRuntime2(
      memoryLimit: 48 * 1024 * 1024,
      stackSize: 512 * 1024,
      timeout: 12000,
      moduleHandler: (name) {
        final module = modules[name];
        if (module == null) throw StateError('脚本依赖未加载：$name');
        return module;
      },
    );
    runtime.onMessage('request', (args) {
      if (!_active || _cancelled) throw StateError('脚本操作已取消');
      if (++_networkRequestCount > 32) throw StateError('单次脚本操作的网络请求过多');
      final pending = request(args);
      requests.add(pending.then<void>((_) {}, onError: (Object _) {}));
      return pending;
    });
    runtime.onMessage('catvodRequest', (args) {
      if (!_active || _cancelled) throw StateError('脚本操作已取消');
      if (++_networkRequestCount > 32) throw StateError('单次脚本操作的网络请求过多');
      final pending = request(args, catvod: true);
      requests.add(pending.then<void>((_) {}, onError: (Object _) {}));
      return pending;
    });
    runtime.onMessage('pythonModule', (args) {
      // A cancelled import may probe its alternative filename while draining.
      // Complete that probe without starting transport or retaining any source.
      if (!_active || _cancelled) return 'null';
      final pending = pythonModule(args.toString());
      requests.add(pending.then<void>((_) {}, onError: (Object _) {}));
      return pending;
    });
    // Override the runtime's untracked timers. No callback survives an operation.
    runtime.onMessage('SetTimeout', (args) {
      if (!_active || _cancelled) return;
      final id = args['timeoutIndex'].toString();
      if (_timers.length >= 128) throw StateError('脚本定时任务过多');
      _timers[id] = Timer(
        Duration(milliseconds: (args['timeout'] as num?)?.toInt() ?? 0),
        () {
          _timers.remove(id);
          if (!_active || _cancelled) return;
          runtime.evaluate("""(() => {
          const callbacks = __NATIVE_FLUTTER_JS__setTimeoutCallbacks;
          const fn = callbacks[${jsonEncode(id)}];
          delete callbacks[${jsonEncode(id)}];
          if (typeof fn === 'function') fn();
        })()""");
        },
      );
    });
  }

  void cancel() {
    _cancelled = true;
    if (_active) client.close(force: true);
    for (final owned in _catvodClients) {
      owned.close(force: true);
    }
  }

  void dispose() {
    cancel();
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    runtime.dispose();
  }

  Future<void> closeCatvod() async {
    if (!_initialized || !modules.containsKey('catvod') || _cancelled) return;
    budget = const Duration(milliseconds: 500);
    watch
      ..reset()
      ..start();
    _active = false; // Cleanup cannot initiate network requests or timers.
    runtime.setOperationTimeout(budget);
    try {
      await checked(
        '__movieCatvodClose(); Promise.resolve(__movieSpider.destroy?.()).then(() => null)',
      );
    } catch (_) {
      // A throwing or non-settling hook never prevents unconditional VM release.
    }
  }

  Future<String> invoke(
    String method,
    List<Object?> arguments,
    Duration limit,
  ) async {
    budget = limit;
    watch
      ..reset()
      ..start();
    _cancelled = false;
    _active = true;
    _recoverableProxyCall = false;
    requests.clear();
    _networkRequestCount = 0;
    client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    runtime.setOperationTimeout(budget);
    try {
      if (!_initialized) {
        await initialize();
        _initialized = true;
      }
      _recoverableProxyCall = method == 'proxy';
      final output = await checked(
        'Promise.resolve().then(() => { '
        'const fn = __movieSpider[${jsonEncode(method)}]; '
        'if (typeof fn !== "function") throw new Error("脚本缺少 $method 接口"); '
        'return fn.apply(__movieSpider, ${jsonEncode(arguments)}); '
        '}).then(v => { ${method == 'proxy' ? 'v = __movieEncodeProxyResult(v);' : ''} '
        'return typeof v === "string" ? v : JSON.stringify(v); })',
      );
      final text = output?.toString() ?? '';
      final resultLimit = method == 'proxy'
          ? 8 * 1024 * 1024 + 32 * 1024
          : maxBytes;
      if (utf8.encode(text).length > resultLimit) {
        throw const FormatException('脚本结果过大');
      }
      return text;
    } finally {
      _active = false;
      for (final timer in _timers.values) {
        timer.cancel();
      }
      _timers.clear();
      client.close(force: true);
      for (final owned in _catvodClients) {
        owned.close(force: true);
      }
      await Future.wait(requests);
      // Settle transport completions on the same isolate before the next call.
      runtime.executePendingJob();
      final cleanup = runtime.evaluate(
        '__NATIVE_FLUTTER_JS__setTimeoutCallbacks = {};',
      );
      if (_recoverableProxyCall && cleanup.isError) {
        throw StateError('脚本代理清理失败');
      }
    }
  }

  Future<void> initialize() async {
    await checked('globalThis.__movieProxyBase = ${jsonEncode(proxyBase)};');
    await checked(r'''
        globalThis.global = globalThis;
        globalThis.window = globalThis;
        globalThis.self = globalThis;
        globalThis.req = async (url, options = {}) =>
          JSON.parse(await sendMessage('request', JSON.stringify([url, options])));
        globalThis.console = {log(){}, info(){}, warn(){}, error(){}};
        globalThis.log = () => {};
        globalThis.print = log;
        globalThis.getProxy = function(local = true) {
          if (typeof local !== 'boolean') throw new TypeError('local must be boolean');
          return __movieProxyBase;
        };
        globalThis.proxyUrl = function(params = {}) {
          if (params === null) params = {};
          if (typeof params !== 'object' || Array.isArray(params)) throw new TypeError('proxy params must be an object');
          let url = __movieProxyBase;
          for (const key of Object.keys(params)) {
            if (key === 'do' || key === 'siteKey') throw new TypeError('reserved proxy parameter');
            if (!['string', 'number', 'boolean'].includes(typeof params[key])) throw new TypeError('proxy values must be scalar');
            url += '&' + encodeURIComponent(key) + '=' + encodeURIComponent(params[key]);
          }
          return url;
        };
        globalThis.__movieEncodeProxyResult = function(value) {
          if (!Array.isArray(value) || value.length < 3 || value.length > 5) return value;
          if (value.length === 5 && value[4] !== 0 && value[4] !== 1)
            throw new TypeError('invalid proxy encoding flag');
          if (value.length > 3 && value[3] != null &&
              (typeof value[3] !== 'object' || Array.isArray(value[3])))
            throw new TypeError('invalid proxy response headers');
          const body = value[2];
          const bytes = body instanceof ArrayBuffer ? new Uint8Array(body) :
            ArrayBuffer.isView(body) ? new Uint8Array(body.buffer, body.byteOffset, body.byteLength) :
            Array.isArray(body) && body.every(v => Number.isInteger(v) && v >= 0 && v <= 255) ? new Uint8Array(body) : null;
          if (!bytes) return value;
          if (bytes.length > 6 * 1024 * 1024) throw new Error('proxy body too large');
          const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
          const chunks = []; let part = '';
          for (let i = 0; i < bytes.length; i += 3) {
            const a=bytes[i], b=bytes[i+1] || 0, c=bytes[i+2] || 0;
            part += alphabet[a >> 2] + alphabet[((a & 3) << 4) | (b >> 4)] +
              (i+1 < bytes.length ? alphabet[((b & 15) << 2) | (c >> 6)] : '=') +
              (i+2 < bytes.length ? alphabet[c & 63] : '=');
            if (part.length >= 4096) { chunks.push(part); part = ''; }
          }
          chunks.push(part);
          return [value[0], value[1], chunks.join(''), value[3] ?? {}, 1];
        };
      ''');
    if (modules.containsKey('catvod')) {
      await checked('''(() => { let closed = false;
        const base = ${jsonEncode(proxyBase)}, encode = encodeURIComponent;
        globalThis.__movieCatvodClose = () => { closed = true; };
        globalThis.__movieCatvodBridge = Object.freeze({
        siteKey: ${jsonEncode(Uri.parse(proxyBase).queryParameters['siteKey'])},
        request: (url, options) => {
          if (closed) throw new Error('CatVod source is closed');
          return sendMessage('catvodRequest', JSON.stringify([url, options])).then(JSON.parse);
        },
        proxyUrl: params => base + Object.entries(params).map(([key,value]) =>
          '&' + encode(key) + '=' + encode(value)).join('')
      }); })();''');
    }
    final source = modules[entry]!;
    await checked(interop);
    final selectorOptions = jsonEncode({
      if (rawExtension != null) 'rawExtension': rawExtension,
    });
    if (pythonPrelude.isNotEmpty) {
      _pythonModuleBytes = modules.values.fold(
        0,
        (total, text) => total + utf8.encode(text).length,
      );
      if (modules.length > 32 || _pythonModuleBytes > maxBytes) {
        throw const FormatException('Python 模块数量或总大小超过限制');
      }
      for (final text in pythonPrelude) {
        await checked('$text\n;void 0;');
      }
      final directory = Uri.parse(entry).resolve('.').toString();
      final siblings = {
        for (final item in modules.entries)
          if (item.key != entry &&
              item.key.startsWith(directory) &&
              item.key.endsWith('.py'))
            item.key.substring(directory.length): item.value,
      };
      await checked(
        'globalThis.__movieSpider = createPythonSpider(${jsonEncode(source)},${jsonEncode(siblings)}, '
        'async path => JSON.parse(await sendMessage("pythonModule", JSON.stringify(path))), '
        '${pythonPackage.isEmpty ? 'null' : jsonEncode(pythonPackage)}); void 0;',
      );
    } else if (JsSourceHost.isCatSpider(source) &&
        !JsSourceHost.isEsModule(source)) {
      await checked(source);
      await checked(
        'globalThis.__movieSpider = __movieSelectSpider(__jsEvalReturn(), {preserveInit:true});',
      );
    } else if (JsSourceHost.isEsModule(source)) {
      await checked(
        'import * as spider from ${jsonEncode(entry)}; '
        'globalThis.__movieSpider = __movieSelectSpider(spider, $selectorOptions);',
        module: true,
      );
    } else if (JsSourceHost.isCommonJs(source)) {
      final resolution = <String, Map<String, String>>{};
      for (final module in modules.entries) {
        final references = {
          module.key,
          ...JsSourceHost.commonJsReferences(module.value),
        };
        resolution[module.key] = {
          for (final ref in references)
            ref: JsSourceHost._resolveCommonJsModule(module.key, ref, modules),
        };
      }
      await checked('''
          globalThis.__movieModules = ${jsonEncode(modules)};
          globalThis.__movieResolution = ${jsonEncode(resolution)};
          globalThis.__movieSpider = __movieSelectSpider(__movieLoadCommonJS(${jsonEncode(entry)}, (ref, parent) => {
            const name = __movieResolution[parent]?.[ref];
            if (!name || !Object.prototype.hasOwnProperty.call(__movieModules, name))
              throw new Error('Script dependency is unavailable: ' + ref);
            return {name, source: __movieModules[name]};
          }), $selectorOptions); void 0;
        ''');
    } else {
      throw const FormatException(
        '当前脚本宿主支持 ES module / CommonJS / __jsEvalReturn；DRPY rule 需要对应宿主适配',
      );
    }
    await checked(
      'Promise.resolve(__movieSpider.init?.(${jsonEncode(extension)}))',
    );
  }

  Future<String> pythonModule(String path) async {
    if (!RegExp(r'^(?:[A-Za-z_]\w*/)*[A-Za-z_]\w*\.py$').hasMatch(path)) {
      throw const FormatException('Python 模块路径无效');
    }
    final uri = Uri.parse(entry).resolve(path);
    final name = uri.toString();
    if (name == entry) return 'null';
    if (modules.containsKey(name)) return jsonEncode(modules[name]);
    if (_pythonMissingModules.contains(name)) return 'null';
    if (uri.scheme != 'http' && uri.scheme != 'https') return 'null';
    if (modules.length >= 32 || _pythonMissingModules.length >= 64) {
      throw const FormatException('Python 模块数量超过限制');
    }
    if (++_networkRequestCount > 32) throw StateError('单次脚本操作的网络请求过多');
    final response =
        jsonDecode(
              await request([
                name,
                {'buffer': 2},
              ]),
            )
            as Map;
    if (response['code'] == 404 || response['code'] == 410) {
      _pythonMissingModules.add(name);
      return 'null';
    }
    if (response['code'] != 200) throw const HttpException('Python 模块无法读取');
    final bytes = base64Decode(response['content'] as String);
    if (_pythonModuleBytes + bytes.length > maxBytes) {
      throw const FormatException('Python 模块总大小超过 6 MB');
    }
    final source = utf8.decode(bytes);
    if (!_active || _cancelled) throw StateError('脚本操作已取消');
    _pythonModuleBytes += bytes.length;
    modules[name] = source;
    return jsonEncode(source);
  }

  Future<String> request(dynamic raw, {bool catvod = false}) async {
    if (!_active || _cancelled) throw StateError('脚本操作已取消');
    final args = raw as List;
    final uri = Uri.parse(args[0].toString());
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw const FormatException('脚本网络请求只支持 HTTP/HTTPS');
    }
    final options = args[1] is Map ? args[1] as Map : const {};
    var remaining = budget - watch.elapsed;
    if (remaining <= Duration.zero) throw TimeoutException('脚本请求超时');
    final requestedTimeout = num.tryParse(
      (options['timeout'] ?? '').toString(),
    );
    if (requestedTimeout != null &&
        requestedTimeout.isFinite &&
        requestedTimeout > 0) {
      final requested = Duration(milliseconds: requestedTimeout.ceil());
      if (requested < remaining) remaining = requested;
    }
    if (catvod && options['callTimeout'] is num) {
      final requested = Duration(
        milliseconds: (options['callTimeout'] as num).toInt(),
      );
      if (requested < remaining) remaining = requested;
    }
    // CatVod req returns a recoverable error object. Its timeout must not close
    // siblings or a fallback request made by the same Spider method.
    final transport = catvod
        ? (HttpClient()..connectionTimeout = const Duration(seconds: 4))
        : client;
    if (catvod) _catvodClients.add(transport);
    HttpClientRequest? active;
    final timer = Timer(remaining, () {
      active?.abort(TimeoutException('脚本请求超时'));
      transport.close(force: true);
    });
    try {
      var verb = (options['method'] ?? 'GET').toString().toUpperCase();
      if (![
        'GET',
        'POST',
        'HEAD',
        'PUT',
        'PATCH',
        'DELETE',
        if (catvod) 'OPTIONS',
      ].contains(verb)) {
        throw const FormatException('脚本请求方法暂不支持');
      }
      final requestHeaders = <String, String>{'user-agent': 'okhttp/3.15'};
      final origin = Uri.tryParse(entry);
      bool sameOrigin(Uri a, Uri b) =>
          a.scheme == b.scheme &&
          a.host.toLowerCase() == b.host.toLowerCase() &&
          a.port == b.port;
      if (origin != null && sameOrigin(origin, uri)) {
        headers.forEach(
          (key, value) => requestHeaders[key.toLowerCase()] = value,
        );
      }
      if (options['headers'] is Map) {
        (options['headers'] as Map).forEach((k, v) {
          requestHeaders[k.toString().toLowerCase()] = v.toString();
        });
      }
      if (uri.userInfo.isNotEmpty) {
        requestHeaders.putIfAbsent(
          'authorization',
          () =>
              'Basic ${base64Encode(utf8.encode(Uri.decodeComponent(uri.userInfo)))}',
        );
      }
      final body = options['data'] ?? options['body'];
      List<int>? payload;
      if (options.containsKey('bodyBase64')) {
        final encoded = options['bodyBase64'];
        if (options.containsKey('data') ||
            options.containsKey('body') ||
            encoded is! String) {
          throw const FormatException('脚本二进制请求体参数无效');
        }
        if (encoded.length > ((maxBytes + 2) ~/ 3) * 4) {
          throw const FormatException('脚本请求体过大');
        }
        if (encoded.length % 4 != 0 ||
            RegExp(r'[^A-Za-z0-9+/=]').hasMatch(encoded)) {
          throw const FormatException('脚本二进制请求体 Base64 无效');
        }
        payload = base64Decode(encoded);
        if (base64Encode(payload) != encoded) {
          throw const FormatException('脚本二进制请求体 Base64 无效');
        }
      } else {
        payload = body == null
            ? null
            : utf8.encode(body is String ? body : jsonEncode(body));
      }
      if (payload != null && payload.length > maxBytes) {
        throw const FormatException('脚本请求体过大');
      }
      var current = uri.replace(userInfo: '').removeFragment();
      for (var hop = 0; hop <= 8; hop++) {
        final req = active = await transport.openUrl(verb, current);
        req.followRedirects = false;
        requestHeaders.forEach(req.headers.set);
        if (payload != null) req.add(payload);
        final response = await req.close();
        if (response.contentLength > maxBytes) {
          throw const FormatException('脚本响应超过 6 MB');
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > maxBytes) {
            throw const FormatException('脚本响应超过 6 MB');
          }
          bytes.addAll(chunk);
        }
        final code = response.statusCode;
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (options['redirect'] != 0 &&
            location != null &&
            const [301, 302, 303, 307, 308].contains(code)) {
          if (hop == 8) throw const HttpException('脚本请求重定向过多');
          final next = current
              .resolve(location)
              .replace(userInfo: '')
              .removeFragment();
          if (next.scheme != 'http' && next.scheme != 'https') {
            throw const FormatException('脚本重定向只支持 HTTP/HTTPS');
          }
          if (!sameOrigin(current, next)) {
            for (final key in [
              'authorization',
              'cookie',
              'cookie2',
              'proxy-authorization',
              'host',
            ]) {
              requestHeaders.remove(key);
            }
          }
          if ((code == 303 && verb != 'HEAD') ||
              ((code == 301 || code == 302) && verb == 'POST')) {
            verb = 'GET';
            payload = null;
            for (final key in [
              'content-type',
              'content-length',
              'transfer-encoding',
            ]) {
              requestHeaders.remove(key);
            }
          }
          current = next;
          continue;
        }
        final responseHeaders = <String, String>{};
        response.headers.forEach((k, v) => responseHeaders[k] = v.join(', '));
        return jsonEncode({
          'code': code,
          'url': current.toString(),
          'headers': responseHeaders,
          'content': options['buffer'] == 2
              ? base64Encode(bytes)
              : utf8.decode(bytes, allowMalformed: true),
        });
      }
      throw const HttpException('脚本请求重定向过多');
    } finally {
      timer.cancel();
      if (catvod) {
        transport.close(force: true);
        _catvodClients.remove(transport);
      }
    }
  }

  Future<dynamic> checked(String code, {bool module = false}) async {
    if (_cancelled) {
      if (_recoverableProxyCall && requests.isEmpty && watch.elapsed < budget) {
        throw const _ProxyCallCancelled(true);
      }
      throw StateError('脚本操作已取消');
    }
    final evaluated = runtime.evaluate(
      code,
      name: '$entry.host.mjs',
      evalFlags: module ? JSEvalFlag.MODULE : JSEvalFlag.GLOBAL,
    );
    if (evaluated.isError) throw StateError(evaluated.stringResult);
    final result = evaluated.rawResult;
    if (result is! Future) return result;
    Object? value;
    Object? failure;
    bool done = false;
    result.then(
      (v) {
        value = v;
        done = true;
      },
      onError: (Object e) {
        failure = e;
        done = true;
      },
    );
    while (!done) {
      if (_cancelled) {
        if (_recoverableProxyCall) {
          throw _ProxyCallCancelled(await _settleCancelledProxy(() => done));
        }
        throw StateError('脚本操作已取消');
      }
      if (watch.elapsed >= budget) throw TimeoutException('脚本请求超时');
      runtime.executePendingJob();
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    if (_cancelled && _recoverableProxyCall) {
      throw _ProxyCallCancelled(await _settleCancelledProxy(() => done));
    }
    if (failure != null) throw StateError(failure.toString());
    return value;
  }

  Future<bool> _settleCancelledProxy(bool Function() settled) async {
    final remaining = budget - watch.elapsed;
    if (remaining <= Duration.zero) return false;
    final limit = remaining < const Duration(milliseconds: 500)
        ? remaining
        : const Duration(milliseconds: 500);
    final recovery = Stopwatch()..start();
    client.close(force: true);
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    var transportSettled = false;
    Future.wait(requests).then(
      (_) => transportSettled = true,
      onError: (Object _) => transportSettled = true,
    );
    // Never extend the original execution budget for a cancellation handler.
    runtime.setOperationTimeout(limit);
    try {
      while (recovery.elapsed < limit) {
        runtime.executePendingJob();
        await Future<void>.delayed(const Duration(milliseconds: 5));
        if (settled() && transportSettled) {
          // Let bridge completions and their chained microtasks finish before
          // the next queued segment touches the same source state.
          runtime.executePendingJob();
          await Future<void>.delayed(Duration.zero);
          runtime.executePendingJob();
          return recovery.elapsed < limit;
        }
      }
    } catch (_) {
      /* Interrupted or unsettled work requires source teardown. */
    }
    return false;
  }
}

/// Lexical dependency discovery only; execution and module scope stay in JS.
/// Keep a five-token window rather than copying all tokens of a large source.
class _CommonJsReferenceScanner {
  _CommonJsReferenceScanner(this.source);
  final String source;
  final _references = <String>[];
  final _recent = <({String text, bool literal})>[];
  var _at = 0;

  String _char([int offset = 0]) =>
      _at + offset < source.length ? source[_at + offset] : '';
  bool _word(String c) {
    if (c.isEmpty) return false;
    final unit = c.codeUnitAt(0);
    return unit >= 0x80 ||
        unit >= 65 && unit <= 90 ||
        unit >= 97 && unit <= 122 ||
        unit >= 48 && unit <= 57 ||
        c == '_' ||
        c == r'$';
  }

  void _token(String text, {bool literal = false}) {
    _recent.add((text: text, literal: literal));
    if (_recent.length > 5) _recent.removeAt(0);
    if (text != ')' || _recent.length < 4) return;
    final start = _recent.length - 4;
    if (_recent[start].text == 'require' &&
        !_recent[start].literal &&
        _recent[start + 1].text == '(' &&
        _recent[start + 2].literal &&
        (start == 0 || !const {'.', '?.'}.contains(_recent[start - 1].text))) {
      _references.add(_recent[start + 2].text);
    }
  }

  List<String> scan() {
    _code();
    return _references;
  }

  void _code({bool interpolation = false}) {
    var previous = '';
    var expression = true, statement = !interpolation;
    bool? functionValue, closedFunctionValue;
    var asyncStatement = false;
    final parens = <({bool control, bool? functionValue})>[];
    final blockBraces = <bool>[];
    final classes = <({bool value, int parens, int braces})>[];
    while (_at < source.length) {
      if (_trivia()) continue;
      final c = _char();
      if (interpolation && c == '}' && blockBraces.isEmpty) {
        _at++;
        return;
      }
      if (c == '"' || c == "'") {
        final value = _quoted();
        _token(value ?? '<invalid-string>', literal: value != null);
        previous = '<string>';
        expression = statement = false;
      } else if (c == '`') {
        _token('<template>');
        _template();
        _token('<template>');
        previous = '<template>';
        expression = statement = false;
      } else if (c == '/' && expression && _regex()) {
        _token('<regex>');
        previous = '<regex>';
        expression = statement = false;
      } else if (_word(c)) {
        final start = _at++;
        while (_word(_char())) {
          _at++;
        }
        final wasStatement = statement;
        final before = previous;
        previous = source.substring(start, _at);
        if (previous == 'function') {
          functionValue =
              !(wasStatement || before == 'async' && asyncStatement);
        }
        if (previous == 'async') asyncStatement = wasStatement;
        if (previous == 'class' && !const {'.', '?.'}.contains(before)) {
          classes.add((
            value: !wasStatement,
            parens: parens.length,
            braces: blockBraces.length,
          ));
        }
        _token(previous);
        expression = const {
          'return',
          'throw',
          'case',
          'delete',
          'void',
          'typeof',
          'yield',
          'await',
          'new',
          'in',
          'of',
          'instanceof',
          'else',
          'do',
        }.contains(previous);
        statement = const {
          'else',
          'do',
          'try',
          'catch',
          'finally',
        }.contains(previous);
      } else {
        var punct = c;
        final pair = c + _char(1);
        if (const {'?.', '=>', '++', '--'}.contains(pair)) punct = pair;
        _at += punct.length;
        if (punct == '(') {
          final property =
              _recent.length >= 2 &&
              const {'.', '?.'}.contains(_recent[_recent.length - 2].text);
          parens.add((
            control:
                !property &&
                const {
                  'if',
                  'while',
                  'for',
                  'with',
                  'switch',
                  'catch',
                }.contains(previous),
            functionValue: functionValue,
          ));
          functionValue = null;
          expression = true;
          statement = false;
        } else if (punct == ')') {
          // A slash after if/while/... starts a statement, unlike division
          // after an ordinary call or parenthesized expression.
          final header = parens.isEmpty ? null : parens.removeLast();
          expression = header?.control ?? false;
          closedFunctionValue = header?.functionValue;
          statement = expression;
        } else if (punct == '{') {
          // A class declaration ends a statement; a class expression remains
          // an operand. Parenthesis/brace depth excludes an extends argument.
          final classBody =
              classes.isNotEmpty &&
                  classes.last.parens == parens.length &&
                  classes.last.braces == blockBraces.length
              ? classes.removeLast()
              : null;
          final valueBody =
              classBody?.value == true ||
              previous == '=>' ||
              previous == ')' && closedFunctionValue == true;
          blockBraces.add(
            !valueBody &&
                (classBody != null ||
                    statement ||
                    previous == ')' ||
                    previous == '=>'),
          );
          closedFunctionValue = null;
          expression = statement = true;
        } else if (punct == '}') {
          expression = blockBraces.isEmpty || blockBraces.removeLast();
          statement = expression;
        } else {
          expression = !const {']', '.', '?.', '++', '--'}.contains(punct);
          statement = punct == ';';
        }
        _token(punct);
        previous = punct;
      }
    }
  }

  bool _trivia() {
    final c = _char();
    if (c.isNotEmpty && (c.trim().isEmpty || c == '\ufeff')) {
      _at++;
      return true;
    }
    if ((c == '/' && _char(1) == '/') ||
        (_at == 0 && c == '#' && _char(1) == '!')) {
      while (_at < source.length &&
          !const {'\n', '\r', '\u2028', '\u2029'}.contains(_char())) {
        _at++;
      }
      return true;
    }
    if (c == '/' && _char(1) == '*') {
      final end = source.indexOf('*/', _at + 2);
      _at = end < 0 ? source.length : end + 2;
      return true;
    }
    return false;
  }

  String? _quoted() {
    final quote = _char();
    _at++;
    final value = StringBuffer();
    while (_at < source.length) {
      final c = _char();
      _at++;
      if (c == quote) return value.toString();
      if (c != r'\') {
        value.write(c);
        continue;
      }
      if (_at >= source.length) break;
      final escaped = _char();
      _at++;
      if (escaped == '\n' || escaped == '\r') {
        if (escaped == '\r' && _char() == '\n') _at++;
        continue;
      }
      if (escaped == 'x' || escaped == 'u') {
        final brace = escaped == 'u' && _char() == '{';
        if (brace) _at++;
        final end = brace
            ? source.indexOf('}', _at)
            : _at + (escaped == 'x' ? 2 : 4);
        if (end >= _at && end <= source.length) {
          final code = int.tryParse(source.substring(_at, end), radix: 16);
          if (code != null && code <= 0x10ffff) {
            value.writeCharCode(code);
            _at = end + (brace ? 1 : 0);
            continue;
          }
        }
      }
      value.write(
        const {
              'n': '\n',
              'r': '\r',
              't': '\t',
              'b': '\b',
              'f': '\f',
              'v': '\u000b',
              '0': '\u0000',
            }[escaped] ??
            escaped,
      );
    }
    return null;
  }

  bool _regex() {
    var cursor = _at + 1, inClass = false;
    while (cursor < source.length) {
      final c = source[cursor++];
      if (const {'\n', '\r', '\u2028', '\u2029'}.contains(c)) return false;
      if (c == r'\') {
        cursor++;
        continue;
      }
      if (c == '[') inClass = true;
      if (c == ']') inClass = false;
      if (c == '/' && !inClass) {
        _at = cursor;
        while (_word(_char())) {
          _at++;
        }
        return true;
      }
    }
    return false;
  }

  void _template() {
    _at++;
    while (_at < source.length) {
      final c = _char();
      _at++;
      if (c == r'\') {
        if (_at < source.length) _at++;
      } else if (c == '`') {
        return;
      } else if (c == r'$' && _char() == '{') {
        _at++;
        _token('<interpolation>');
        _code(interpolation: true);
        _token('<interpolation>');
      }
    }
  }
}
