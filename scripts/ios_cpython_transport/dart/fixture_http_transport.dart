// Experimental owned-loopback transport. This is not a production source host.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

class FixtureTransportException implements Exception {
  const FixtureTransportException(this.kind);
  final String kind;
  @override
  String toString() => 'Fixture HTTP transport $kind';
}

class FixtureHttpTransport {
  FixtureHttpTransport({required List<Uri> allowedOrigins})
    : _origins = List.unmodifiable(allowedOrigins.map(_validateOrigin)) {
    if (_origins.isEmpty || _origins.length > 4) {
      throw const FormatException('Fixture requires one to four owned origins');
    }
  }

  static const maxBodyBytes = 6 * 1024 * 1024;
  static const maxCalls = 64;
  static const maxRequests = 256;
  static final _identity = RegExp(r'^[0-9a-f]{32}$');
  static final _token = RegExp(r"^[!#$%&'*+.^_`|~0-9a-z-]+$");
  static const _fields = {
    'version',
    'callId',
    'requestId',
    'url',
    'method',
    'headers',
    'body',
    'connectTimeoutMs',
    'readTimeoutMs',
    'deadlineRemainingMs',
  };
  static const _methods = {
    'GET',
    'HEAD',
    'POST',
    'PUT',
    'PATCH',
    'DELETE',
    'OPTIONS',
  };
  static const _framing = {
    'host',
    'connection',
    'content-length',
    'transfer-encoding',
    'upgrade',
    'trailer',
    'te',
    'proxy-connection',
  };
  final List<Uri> _origins;
  final Stopwatch _clock = Stopwatch()..start();
  final Map<String, _Call> _calls = {};
  final Set<String> _usedRequests = {};
  final Map<String, _Task> _active = {};
  bool _closed = false;

  int get activeRequestCount => _active.length;

  static Uri _validateOrigin(Uri origin) {
    final segments = origin.pathSegments.where((s) => s.isNotEmpty).toList();
    if (origin.scheme != 'http' ||
        origin.host != '127.0.0.1' ||
        !origin.hasPort ||
        origin.port < 1 ||
        origin.port > 65535 ||
        origin.userInfo.isNotEmpty ||
        origin.hasQuery ||
        origin.hasFragment ||
        segments.length != 1 ||
        !_identity.hasMatch(segments.single) ||
        (origin.path != '/${segments.single}' &&
            origin.path != '/${segments.single}/')) {
      throw const FormatException('Invalid owned fixture origin');
    }
    return origin.replace(path: '/${segments.single}');
  }

  static String _id(Object? value) {
    if (value is! String || !_identity.hasMatch(value)) {
      throw const FormatException('Invalid fixture identity');
    }
    return value;
  }

  static int _budget(Object? value) {
    if (value is! int || value < 1 || value > 45000) {
      throw const FormatException('Invalid fixture time budget');
    }
    return value;
  }

  Uri _url(Object? value) {
    if (value is! String ||
        value.length > 16384 ||
        RegExp(r'[\x00-\x20\x7f\\]').hasMatch(value)) {
      throw const FormatException('Invalid fixture URL');
    }
    // Inspect before Uri's dot-segment normalization, including encoded traversal.
    final raw = RegExp(
      r'^http://127\.0\.0\.1:[0-9]+(/[^?#]*)?(?:\?[^#]*)?$',
    ).firstMatch(value);
    if (raw == null) {
      throw const FormatException('URL is outside owned fixture');
    }
    for (final segment in (raw.group(1) ?? '/').split('/')) {
      final decoded = Uri.decodeComponent(segment);
      if (decoded == '.' ||
          decoded == '..' ||
          RegExp(r'[/\\%\x00-\x20\x7f]').hasMatch(decoded)) {
        throw const FormatException('Invalid fixture path');
      }
    }
    final uri = Uri.parse(value);
    if (!_origins.any(
      (base) =>
          uri.origin == base.origin &&
          (uri.path == base.path || uri.path.startsWith('${base.path}/')),
    )) {
      throw const FormatException('URL is outside owned fixture');
    }
    return uri;
  }

  static List<List<String>> _headers(Object? value, {bool response = false}) {
    if (value is! List || value.length > 128) {
      throw const FormatException('Invalid fixture headers');
    }
    final result = <List<String>>[];
    final seen = <String>{};
    var size = 0;
    for (final pair in value) {
      if (pair is! List ||
          pair.length != 2 ||
          pair[0] is! String ||
          pair[1] is! String) {
        throw const FormatException('Invalid fixture header pair');
      }
      final name = pair[0] as String;
      final text = pair[1] as String;
      if (!_token.hasMatch(name) ||
          text.codeUnits.any(
            (c) => c > 255 || c == 127 || (c < 32 && c != 9),
          )) {
        throw const FormatException('Invalid fixture header value');
      }
      size += name.length + text.length + 4;
      if (size > 32768 ||
          (!response &&
              (_framing.contains(name) ||
                  (name == 'content-type' &&
                      text.toLowerCase().startsWith('multipart/')))) ||
          (seen.contains(name) &&
              (!response ||
                  {
                    'content-length',
                    'transfer-encoding',
                    'location',
                    'content-encoding',
                  }.contains(name)))) {
        throw const FormatException('Unsupported fixture headers');
      }
      if (name == 'content-length' && !RegExp(r'^[0-9]+$').hasMatch(text)) {
        throw const FormatException('Invalid fixture content length');
      }
      seen.add(name);
      result.add([name, text]);
    }
    if (response &&
        seen.contains('content-length') &&
        seen.contains('transfer-encoding')) {
      throw const FormatException('Ambiguous fixture response framing');
    }
    return result;
  }

  Future<Map<String, Object?>> request(Map<String, Object?> envelope) async {
    if (_closed) throw const FixtureTransportException('cancelled');
    if (envelope.length != _fields.length ||
        !_fields.every(envelope.containsKey) ||
        envelope['version'] != 1 ||
        envelope['version'] is! int) {
      throw const FormatException('Invalid fixture request fields');
    }
    final callId = _id(envelope['callId']);
    final requestId = _id(envelope['requestId']);
    final uri = _url(envelope['url']);
    final method = envelope['method'];
    if (method is! String || !_methods.contains(method)) {
      throw const FormatException('Unsupported fixture HTTP method');
    }
    final sourceBody = envelope['body'];
    if (sourceBody is! Uint8List ||
        sourceBody.length > maxBodyBytes ||
        (sourceBody.isNotEmpty && (method == 'GET' || method == 'HEAD'))) {
      throw const FormatException('Invalid fixture request bytes');
    }
    final headers = _headers(envelope['headers']);
    final connectMs = _budget(envelope['connectTimeoutMs']);
    final readMs = _budget(envelope['readTimeoutMs']);
    final totalMs = _budget(envelope['deadlineRemainingMs']);
    if (connectMs > totalMs || readMs > totalMs) {
      throw const FormatException('Phase exceeds fixture call budget');
    }
    if (_usedRequests.contains(requestId)) {
      throw const FormatException('Fixture request identity was already used');
    }
    if (_usedRequests.length >= maxRequests ||
        (!_calls.containsKey(callId) && _calls.length >= maxCalls)) {
      throw const FormatException('Fixture transport lifetime limit reached');
    }
    final now = _clock.elapsedMilliseconds;
    final call = _calls.putIfAbsent(callId, () => _Call(now + totalMs));
    if (call.cancelled) throw const FixtureTransportException('cancelled');
    final previousDeadline = call.deadlineMs;
    call.deadlineMs = _min(call.deadlineMs, now + totalMs);
    if (call.deadlineMs < previousDeadline) {
      for (final active in _active.values.toList()) {
        if (active.callId == callId) {
          active.deadline(call.deadlineMs - now);
        }
      }
    }
    if (call.deadlineMs <= now) {
      throw const FixtureTransportException('timeout');
    }
    _usedRequests.add(requestId);
    final task = _Task(
      callId,
      HttpClient()
        ..autoUncompress = false
        ..findProxy = ((_) => 'DIRECT')
        ..connectionTimeout = Duration(milliseconds: connectMs),
    );
    _active[requestId] = task;
    task.deadline(call.deadlineMs - now);
    unawaited(
      _run(
        task,
        uri,
        envelope['url'] as String,
        requestId,
        method,
        headers,
        Uint8List.fromList(sourceBody),
        connectMs,
        readMs,
      ),
    );
    try {
      return await task.result.future;
    } finally {
      task.stop();
      _active.remove(requestId);
    }
  }

  Future<void> _run(
    _Task task,
    Uri uri,
    String exactUrl,
    String requestId,
    String method,
    List<List<String>> headers,
    Uint8List body,
    int connectMs,
    int readMs,
  ) async {
    try {
      task.phase(connectMs);
      final request = await task.client.openUrl(method, uri);
      if (task.done) return;
      request.followRedirects = false;
      request.persistentConnection = false;
      for (final pair in headers) {
        request.headers.add(pair[0], pair[1]);
      }
      request.contentLength = body.length;
      task.phase(
        readMs,
      ); // Upload/header wait and each body idle interval bounded.
      if (body.isNotEmpty) request.add(body);
      final response = await request.close();
      if (task.done) return;
      if (response.statusCode < 200 ||
          response.statusCode > 599 ||
          response.reasonPhrase.length > 512 ||
          RegExp(r'[\x00-\x08\x0a-\x1f\x7f]').hasMatch(response.reasonPhrase)) {
        throw const FormatException('Invalid fixture HTTP response');
      }
      final pairs = <List<String>>[];
      var headerBytes = 0;
      response.headers.forEach((name, values) {
        for (final value in values) {
          headerBytes += name.length + value.length + 4;
          if (pairs.length >= 128 || headerBytes > 32768) {
            throw const FormatException(
              'Fixture response headers exceed limit',
            );
          }
          pairs.add([name, value]);
        }
      });
      final cleanHeaders = _headers(pairs, response: true);
      final noBody =
          method == 'HEAD' ||
          response.statusCode == 204 ||
          response.statusCode == 304;
      if (!noBody && response.contentLength > maxBodyBytes) {
        throw const FormatException('Fixture response exceeds 6 MiB');
      }
      final bytes = BytesBuilder(copy: false);
      task.phase(readMs);
      await for (final chunk in response) {
        if (task.done) return;
        if (chunk.length > maxBodyBytes - bytes.length ||
            (noBody && chunk.isNotEmpty)) {
          throw const FormatException('Fixture response exceeds body limit');
        }
        bytes.add(chunk);
        task.phase(readMs);
      }
      if (task.done) return;
      if (!noBody &&
          response.contentLength >= 0 &&
          bytes.length != response.contentLength) {
        throw const FormatException('Fixture response length mismatch');
      }
      final call = _calls[task.callId]!;
      if (_closed || call.cancelled) {
        throw const FixtureTransportException('cancelled');
      }
      if (_clock.elapsedMilliseconds >= call.deadlineMs) {
        throw const FixtureTransportException('timeout');
      }
      task.succeed({
        'version': 1,
        'callId': task.callId,
        'requestId': requestId,
        'url': exactUrl,
        'status': response.statusCode,
        'reason': response.reasonPhrase,
        'headers': cleanHeaders,
        'body': bytes.takeBytes(),
      });
    } catch (error) {
      task.fail(
        error is FormatException || error is FixtureTransportException
            ? error
            : const FixtureTransportException('connection'),
      );
    }
  }

  void cancel(String callId) {
    _id(callId);
    if (_closed) return;
    if (!_calls.containsKey(callId) && _calls.length >= maxCalls) {
      throw const FormatException('Fixture transport lifetime limit reached');
    }
    (_calls.putIfAbsent(
      callId,
      () => _Call(_clock.elapsedMilliseconds),
    )).cancelled = true;
    for (final task in _active.values.toList()) {
      if (task.callId == callId) {
        task.fail(const FixtureTransportException('cancelled'));
      }
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final task in _active.values.toList()) {
      task.fail(const FixtureTransportException('cancelled'));
    }
    _calls.clear();
    _usedRequests.clear();
  }

  static int _min(int a, int b) => a < b ? a : b;
}

class _Call {
  _Call(this.deadlineMs);
  int deadlineMs;
  bool cancelled = false;
}

class _Task {
  _Task(this.callId, this.client);
  final String callId;
  final HttpClient client;
  final Completer<Map<String, Object?>> result = Completer();
  Timer? totalTimer;
  Timer? phaseTimer;
  bool _settled = false;
  bool get done => _settled;
  void deadline(int milliseconds) {
    totalTimer?.cancel();
    totalTimer = Timer(
      Duration(milliseconds: milliseconds),
      () => fail(const FixtureTransportException('timeout')),
    );
  }

  void phase(int milliseconds) {
    phaseTimer?.cancel();
    phaseTimer = Timer(
      Duration(milliseconds: milliseconds),
      () => fail(const FixtureTransportException('timeout')),
    );
  }

  void stop() {
    totalTimer?.cancel();
    phaseTimer?.cancel();
    client.close(force: true);
  }

  void fail(Object error) {
    if (done) return;
    _settled = true;
    stop();
    result.completeError(error);
  }

  void succeed(Map<String, Object?> value) {
    if (done) return;
    _settled = true;
    stop();
    result.complete(value);
  }
}
