import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

typedef ScriptProxyHandler =
    Future<ScriptProxyResponse> Function(ScriptProxyRequest request);

class ScriptProxyRequest {
  final String path;
  final Map<String, List<String>> queryParametersAll;
  final String method;
  final Map<String, String> headers;
  final Completer<void> cancellation;

  ScriptProxyRequest._(
    this.path,
    this.queryParametersAll,
    this.method,
    this.headers,
    this.cancellation,
  );
}

class ScriptProxyResponse {
  final int statusCode;
  final String contentType;
  final Uint8List body;
  final Map<String, String> headers;

  const ScriptProxyResponse({
    required this.statusCode,
    required this.contentType,
    required this.body,
    this.headers = const {},
  });
}

class ScriptProxyRegistration {
  final ScriptProxyServer _owner;
  final String _token;
  final ScriptProxyHandler _handler;
  final Uri url;
  final _requests = <_ProxyRequest>{};
  final _closed = Completer<void>();
  bool _active = true;

  ScriptProxyRegistration._(this._owner, this._token, this._handler, this.url);

  bool get isActive => _active;
  Future<void> get closed => _closed.future;

  /// Revokes the address synchronously, then waits for HTTP teardown. A source
  /// callback which ignores cancellation cannot keep this address alive.
  Future<void> unregister() => _owner._unregister(this);
  Future<void> close() => unregister();
}

class _ProxyRequest {
  final cancelled = Completer<void>();
  final done = Completer<void>();
  int failureStatus = 410;

  void cancel(int status) {
    if (cancelled.isCompleted) return;
    failureStatus = status;
    cancelled.complete();
  }
}

class _ProxySocket {
  final Socket socket;
  final bool head;
  bool _sent = false;

  _ProxySocket(this.socket, this.head, _ProxyRequest operation) {
    socket.listen(
      (data) {
        // GET/HEAD have no body here. Pipelining cannot escape this one response.
        if (data.isNotEmpty) operation.cancel(400);
      },
      onDone: () => operation.cancel(499),
      onError: (Object _) => operation.cancel(499),
    );
  }

  Future<void> send(
    int status,
    Map<String, String> headers,
    Uint8List body, {
    int? length,
  }) async {
    if (_sent) return;
    final fields = {
      ...headers,
      'content-length': '${length ?? body.length}',
      'connection': 'close',
    };
    final prefix = latin1.encode(
      'HTTP/1.1 $status Proxy Response\r\n'
      '${fields.entries.map((e) => '${e.key}: ${e.value}\r\n').join()}\r\n',
    );
    _sent = true;
    socket.add(prefix);
    if (!head && body.isNotEmpty) socket.add(body);
    await socket.flush().timeout(const Duration(seconds: 2));
    await socket.close().timeout(const Duration(seconds: 2));
  }

  void destroy() => socket.destroy();
}

/// One loopback listener for retained JS/Python source callbacks. It does not
/// fetch upstream URLs or reinterpret HLS bodies: relative paths remain inside
/// the originating capability route, and the Spider decides what they mean.
class ScriptProxyServer {
  static const maxResponseBytes = 6 * 1024 * 1024;
  static const _maxHeaderBytes = 16 * 1024;
  static const _maxRequests = 8;
  static const _maxSourceRequests = 4;
  static const _maxSources = 64;
  static const _prefix = '_spider';
  static final _headerName = RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$");
  static const _hopHeaders = {
    'connection',
    'keep-alive',
    'proxy-authenticate',
    'proxy-authorization',
    'te',
    'trailer',
    'transfer-encoding',
    'upgrade',
    'content-length',
  };

  final _random = Random.secure();
  final _sources = <String, ScriptProxyRegistration>{};
  final Duration requestTimeout;
  HttpServer? _server;
  Future<HttpServer>? _starting;
  Future<void>? _closing;
  bool _closed = false;
  int _activeRequests = 0;

  ScriptProxyServer({this.requestTimeout = const Duration(seconds: 20)}) {
    if (requestTimeout <= Duration.zero ||
        requestTimeout > const Duration(seconds: 60)) {
      throw ArgumentError.value(requestTimeout, 'requestTimeout');
    }
  }

  Future<HttpServer> _ensureServer() {
    if (_closed) {
      return Future.error(StateError('Script proxy server is closed'));
    }
    if (_server != null) return Future.value(_server!);
    return _starting ??= () async {
      final server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
        shared: false,
      );
      if (_closed) {
        await server.close(force: true);
        throw StateError('Script proxy server is closed');
      }
      _server = server;
      server.listen(
        (request) => unawaited(_serve(request)),
        onError: (Object _) {},
      );
      return server;
    }();
  }

  Future<ScriptProxyRegistration> register(ScriptProxyHandler handler) async {
    final server = await _ensureServer();
    if (_closed) throw StateError('Script proxy server is closed');
    if (_sources.length >= _maxSources) {
      throw StateError('Too many script proxies');
    }
    String token;
    do {
      token = base64Url
          .encode(List.generate(32, (_) => _random.nextInt(256)))
          .replaceAll('=', '');
    } while (_sources.containsKey(token));
    final registration = ScriptProxyRegistration._(
      this,
      token,
      handler,
      Uri.parse('http://127.0.0.1:${server.port}/$_prefix/$token/proxy'),
    );
    _sources[token] = registration;
    return registration;
  }

  Future<void> _unregister(ScriptProxyRegistration source) {
    if (!source._active) return source.closed;
    source._active = false;
    _sources.remove(source._token);
    final requests = source._requests.toList();
    for (final request in requests) {
      request.cancel(410);
    }
    Future.wait(requests.map((request) => request.done.future)).then((_) {
      if (!source._closed.isCompleted) source._closed.complete();
    });
    return source.closed;
  }

  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    final pending = _sources.values.toList().map(_unregister).toList();
    return _closing = () async {
      var server = _server;
      if (server == null && _starting != null) {
        try {
          server = await _starting;
        } catch (_) {
          /* Failed startup owns no socket. */
        }
      }
      await server?.close(force: true);
      await Future.wait(pending);
    }();
  }

  Map<String, String> _headers(HttpHeaders input) {
    final result = <String, String>{};
    var size = 0;
    input.forEach((name, values) {
      final value = values.join(', ');
      size += utf8.encode(name).length + utf8.encode(value).length;
      if (result.length >= 64 ||
          size > _maxHeaderBytes ||
          !_headerName.hasMatch(name) ||
          RegExp(r'[\r\n\x00]').hasMatch(value)) {
        throw const FormatException('Proxy headers too large or invalid');
      }
      result[name.toLowerCase()] = value;
    });
    return result;
  }

  Future<void> _serve(HttpRequest request) async {
    _ProxyRequest? active;
    ScriptProxyRegistration? source;
    Timer? timer;
    _ProxySocket? connection;
    Future<void> fail(int status) =>
        _error(request, status, connection: connection);
    try {
      if (_closed ||
          request.connectionInfo?.remoteAddress.isLoopback != true ||
          request.headers.value(HttpHeaders.hostHeader) !=
              '127.0.0.1:${_server!.port}' ||
          request.headers.value('origin') != null) {
        await fail(403);
        return;
      }
      if (request.method != 'GET' && request.method != 'HEAD') {
        request.response.headers.set('Allow', 'GET, HEAD');
        await fail(405);
        return;
      }
      if (request.contentLength > 0 ||
          request.headers.value('transfer-encoding') != null) {
        await fail(413);
        return;
      }
      final uri = request.uri;
      if (uri.toString().length > 8192 ||
          uri.hasAuthority ||
          uri.hasScheme ||
          uri.hasFragment) {
        await fail(400);
        return;
      }
      final segments = uri.pathSegments;
      if (segments.length < 3 ||
          segments.first != _prefix ||
          segments.any(
            (p) =>
                p == '.' ||
                p == '..' ||
                RegExp(
                  r'[/\\\x00-\x1f\x7f]|%(?:2e|2f|5c|00)',
                  caseSensitive: false,
                ).hasMatch(p),
          )) {
        await fail(404);
        return;
      }
      source = _sources[segments[1]];
      if (source == null || !source._active) {
        await fail(404);
        return;
      }
      final inputHeaders = _headers(request.headers);
      if (_activeRequests >= _maxRequests ||
          source._requests.length >= _maxSourceRequests) {
        request.response.headers.set('Retry-After', '1');
        await fail(429);
        return;
      }
      final connectionHeaders = (inputHeaders['connection'] ?? '')
          .split(',')
          .map((value) => value.trim().toLowerCase())
          .toSet();
      inputHeaders.removeWhere(
        (key, _) =>
            _hopHeaders.contains(key) ||
            connectionHeaders.contains(key) ||
            key == 'host',
      );
      active = _ProxyRequest();
      final operation = active;
      source._requests.add(operation);
      _activeRequests++;
      // HttpResponse.done does not observe a disconnect while the callback is
      // still pending. Own this validated, bodyless connection so cancellation
      // is immediate; one response per socket avoids a second HTTP parser.
      final socket = await request.response.detachSocket(writeHeaders: false);
      connection = _ProxySocket(socket, request.method == 'HEAD', operation);
      timer = Timer(requestTimeout, () => operation.cancel(504));
      final value = await Future.any<ScriptProxyResponse?>([
        Future.sync(
          () => source!._handler(
            ScriptProxyRequest._(
              '/${segments.skip(2).join('/')}',
              Map.unmodifiable(
                uri.queryParametersAll.map(
                  (key, values) =>
                      MapEntry(key, List<String>.unmodifiable(values)),
                ),
              ),
              request.method,
              Map.unmodifiable(inputHeaders),
              operation.cancelled,
            ),
          ),
        ),
        operation.cancelled.future.then((_) => null),
      ]);
      if (operation.cancelled.isCompleted || !source._active || value == null) {
        await fail(
          operation.failureStatus == 499 ? 410 : operation.failureStatus,
        );
        return;
      }
      await _write(request, connection, value);
    } on FormatException {
      await fail(active == null ? 431 : 502);
    } catch (_) {
      await fail(502);
    } finally {
      timer?.cancel();
      connection?.destroy();
      if (active != null) {
        active.cancel(499);
        source?._requests.remove(active);
        _activeRequests--;
        if (!active.done.isCompleted) active.done.complete();
      }
    }
  }

  Future<void> _write(
    HttpRequest request,
    _ProxySocket connection,
    ScriptProxyResponse value,
  ) async {
    if (value.statusCode < 200 ||
        value.statusCode > 599 ||
        value.body.length > maxResponseBytes ||
        value.contentType.isEmpty ||
        value.contentType.length > 256 ||
        RegExp(r'[\x00-\x1f\x7f-\uffff]').hasMatch(value.contentType)) {
      throw const FormatException('Invalid proxy result');
    }
    final headers = <String, String>{};
    var headerBytes = 0;
    if (value.headers.length > 64) {
      throw const FormatException('Too many headers');
    }
    for (final entry in value.headers.entries) {
      headerBytes +=
          utf8.encode(entry.key).length + utf8.encode(entry.value).length;
      if (headerBytes > _maxHeaderBytes ||
          !_headerName.hasMatch(entry.key) ||
          RegExp(
            r'[\x00-\x08\x0a-\x1f\x7f\u0100-\uffff]',
          ).hasMatch(entry.value)) {
        throw const FormatException('Invalid proxy headers');
      }
      headers[entry.key.toLowerCase()] = entry.value;
    }
    final head = request.method == 'HEAD';
    int? declaredLength;
    if (head && headers.containsKey('content-length')) {
      declaredLength = int.tryParse(headers['content-length']!);
      if (declaredLength == null ||
          declaredLength < 0 ||
          declaredLength > 9007199254740991) {
        throw const FormatException('Invalid HEAD length');
      }
    }
    final connectionHeaders = (headers['connection'] ?? '')
        .split(',')
        .map((value) => value.trim().toLowerCase())
        .toSet();
    headers.removeWhere(
      (key, _) =>
          _hopHeaders.contains(key) ||
          connectionHeaders.contains(key) ||
          key == 'set-cookie' ||
          key == 'set-cookie2' ||
          key == 'content-type' ||
          key.startsWith('access-control-'),
    );
    var body = Uint8List.fromList(value.body);
    var status = value.statusCode;
    var outputLength = head ? declaredLength ?? body.length : body.length;
    final contentRange = headers['content-range'];
    if (status == 206) {
      final range = RegExp(
        r'^bytes (\d+)-(\d+)/(\d+|\*)$',
      ).firstMatch(contentRange ?? '');
      final start = int.tryParse(range?.group(1) ?? '');
      final end = int.tryParse(range?.group(2) ?? '');
      final total = int.tryParse(range?.group(3) ?? '');
      if (start == null ||
          end == null ||
          start < 0 ||
          end < start ||
          (request.method != 'HEAD' && end - start + 1 != body.length) ||
          (range?.group(3) != '*' && total == null) ||
          (total != null && end >= total)) {
        throw const FormatException('Invalid partial response');
      }
      if (head) outputLength = end - start + 1;
    } else if (status == 200) {
      headers.remove('content-range');
      final text = RegExp(
        r'^text/|json|mpegurl',
        caseSensitive: false,
      ).hasMatch(value.contentType);
      final canSlice = !text && !headers.containsKey('content-encoding');
      headers['accept-ranges'] = canSlice ? 'bytes' : 'none';
      final requested = request.headers.value('range');
      final ifRange = request.headers.value('if-range');
      final validatorMatches =
          ifRange == null ||
          (!ifRange.startsWith('W/') && ifRange == headers['etag']) ||
          ifRange == headers['last-modified'];
      final totalLength = head ? outputLength : body.length;
      if (requested != null && canSlice && validatorMatches) {
        final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(requested);
        int? start;
        int? end;
        if (match != null && match.group(1)!.isNotEmpty) {
          start = int.tryParse(match.group(1)!);
          end = match.group(2)!.isEmpty
              ? totalLength - 1
              : int.tryParse(match.group(2)!);
        } else if (match != null && match.group(2)!.isNotEmpty) {
          final suffix = int.tryParse(match.group(2)!);
          if (suffix != null && suffix > 0) {
            start = max(0, totalLength - suffix);
            end = totalLength - 1;
          }
        }
        if (start == null ||
            end == null ||
            start < 0 ||
            start >= totalLength ||
            end < start) {
          status = 416;
          headers['content-range'] = 'bytes */$totalLength';
          body = Uint8List(0);
          outputLength = 0;
        } else {
          end = min(end, totalLength - 1);
          headers['content-range'] = 'bytes $start-$end/$totalLength';
          outputLength = end - start + 1;
          if (!head) body = Uint8List.sublistView(body, start, end + 1);
          status = 206;
        }
      }
    }
    if (status == 204 || status == 304) {
      body = Uint8List(0);
      outputLength = 0;
    }
    await connection.send(
      status,
      {
        'content-type': value.contentType,
        'cache-control': 'no-store',
        ...headers,
      },
      body,
      length: outputLength,
    );
  }

  Future<void> _error(
    HttpRequest request,
    int status, {
    _ProxySocket? connection,
  }) async {
    try {
      if (connection != null) {
        await connection.send(status, {
          'cache-control': 'no-store',
        }, Uint8List(0));
        return;
      }
      request.response.statusCode = status;
      request.response.headers.set('Cache-Control', 'no-store');
      request.response.contentLength = 0;
      await request.response.close();
    } catch (_) {
      /* The player may already have closed its socket. */
    }
  }
}
