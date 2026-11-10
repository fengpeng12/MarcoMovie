// One native Python operation owns this bounded HTTP transport.
// Closing it cancels only that operation; a later operation gets a new instance.
// A runtime plugin must still validate its source handle and operation identity.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

class PythonTransportException implements Exception {
  const PythonTransportException(this.kind);
  final String kind;
  @override
  String toString() => 'Python HTTP transport $kind';
}

class PythonHttpTransport {
  PythonHttpTransport({
    required String callId,
    required Duration budget,
    bool Function(Uri)? allowUrl,
  }) : _callId = _id(callId),
       _allowUrl = allowUrl {
    if (budget.inMilliseconds < 1 || budget.inMilliseconds > 45000) {
      throw const FormatException('Invalid Python operation budget');
    }
    _calls[_callId] = _Call(budget.inMilliseconds);
  }

  static const maxBodyBytes = 6 * 1024 * 1024;
  static const maxCalls = 1;
  static const maxRequests = 32;
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
  final String _callId;
  final bool Function(Uri)? _allowUrl;
  final Stopwatch _clock = Stopwatch()..start();
  final Map<String, _Call> _calls = {};
  final Set<String> _usedRequests = {};
  final Map<String, _Task> _active = {};
  bool _closed = false;

  int get activeRequestCount => _active.length;

  static String _id(Object? value) {
    if (value is! String || !_identity.hasMatch(value)) {
      throw const FormatException('Invalid Python identity');
    }
    return value;
  }

  static int _budget(Object? value) {
    if (value is! int || value < 1 || value > 45000) {
      throw const FormatException('Invalid Python time budget');
    }
    return value;
  }

  Uri _url(Object? value) {
    if (value is! String ||
        value.length > 16384 ||
        RegExp(r'[\x00-\x20\x7f\\]').hasMatch(value)) {
      throw const FormatException('Invalid Python request URL');
    }
    final uri = Uri.parse(value);
    if ((uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.port < 1 ||
        uri.port > 65535 ||
        (_allowUrl != null && !_allowUrl(uri))) {
      throw const FormatException('Unsupported Python request URL');
    }
    return uri;
  }

  static List<List<String>> _headers(Object? value, {bool response = false}) {
    if (value is! List || value.length > 128) {
      throw const FormatException('Invalid Python headers');
    }
    final result = <List<String>>[];
    final seen = <String>{};
    var size = 0;
    for (final pair in value) {
      if (pair is! List ||
          pair.length != 2 ||
          pair[0] is! String ||
          pair[1] is! String) {
        throw const FormatException('Invalid Python header pair');
      }
      final name = pair[0] as String;
      final text = pair[1] as String;
      if (!_token.hasMatch(name) ||
          text.codeUnits.any(
            (c) => c > 255 || c == 127 || (c < 32 && c != 9),
          )) {
        throw const FormatException('Invalid Python header value');
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
        throw const FormatException('Unsupported Python headers');
      }
      if (name == 'content-length' && !RegExp(r'^[0-9]+$').hasMatch(text)) {
        throw const FormatException('Invalid Python content length');
      }
      seen.add(name);
      result.add([name, text]);
    }
    if (response &&
        seen.contains('content-length') &&
        seen.contains('transfer-encoding')) {
      throw const FormatException('Ambiguous Python response framing');
    }
    return result;
  }

  Future<Map<String, Object?>> request(Map<String, Object?> envelope) async {
    if (_closed) throw const PythonTransportException('cancelled');
    if (envelope.length != _fields.length ||
        !_fields.every(envelope.containsKey) ||
        envelope['version'] != 1 ||
        envelope['version'] is! int) {
      throw const FormatException('Invalid Python request fields');
    }
    final callId = _id(envelope['callId']);
    if (callId != _callId) {
      throw const FormatException(
        'HTTP request belongs to another Python operation',
      );
    }
    final requestId = _id(envelope['requestId']);
    final uri = _url(envelope['url']);
    final method = envelope['method'];
    if (method is! String || !_methods.contains(method)) {
      throw const FormatException('Unsupported Python HTTP method');
    }
    final sourceBody = envelope['body'];
    if (sourceBody is! Uint8List ||
        sourceBody.length > maxBodyBytes ||
        (sourceBody.isNotEmpty && (method == 'GET' || method == 'HEAD'))) {
      throw const FormatException('Invalid Python request bytes');
    }
    final headers = _headers(envelope['headers']);
    final connectMs = _budget(envelope['connectTimeoutMs']);
    final readMs = _budget(envelope['readTimeoutMs']);
    final totalMs = _budget(envelope['deadlineRemainingMs']);
    if (connectMs > totalMs || readMs > totalMs) {
      throw const FormatException('Phase exceeds Python call budget');
    }
    if (_usedRequests.contains(requestId)) {
      throw const FormatException('Python request identity was already used');
    }
    if (_usedRequests.length >= maxRequests ||
        (!_calls.containsKey(callId) && _calls.length >= maxCalls)) {
      throw const FormatException('Python transport lifetime limit reached');
    }
    final now = _clock.elapsedMilliseconds;
    final call = _calls.putIfAbsent(callId, () => _Call(now + totalMs));
    if (call.cancelled) throw const PythonTransportException('cancelled');
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
      throw const PythonTransportException('timeout');
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
        throw const FormatException('Invalid Python HTTP response');
      }
      final pairs = <List<String>>[];
      var headerBytes = 0;
      response.headers.forEach((name, values) {
        for (final value in values) {
          headerBytes += name.length + value.length + 4;
          if (pairs.length >= 128 || headerBytes > 32768) {
            throw const FormatException('Python response headers exceed limit');
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
        throw const FormatException('Python response exceeds 6 MiB');
      }
      final bytes = BytesBuilder(copy: false);
      task.phase(readMs);
      await for (final chunk in response) {
        if (task.done) return;
        if (chunk.length > maxBodyBytes - bytes.length ||
            (noBody && chunk.isNotEmpty)) {
          throw const FormatException('Python response exceeds body limit');
        }
        bytes.add(chunk);
        task.phase(readMs);
      }
      if (task.done) return;
      if (!noBody &&
          response.contentLength >= 0 &&
          bytes.length != response.contentLength) {
        throw const FormatException('Python response length mismatch');
      }
      final call = _calls[task.callId]!;
      if (_closed || call.cancelled) {
        throw const PythonTransportException('cancelled');
      }
      if (_clock.elapsedMilliseconds >= call.deadlineMs) {
        throw const PythonTransportException('timeout');
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
        error is FormatException || error is PythonTransportException
            ? error
            : error is HandshakeException
            ? const PythonTransportException('tls')
            : const PythonTransportException('connection'),
      );
    }
  }

  void cancel(String callId) {
    if (_id(callId) != _callId) {
      throw const FormatException('Cannot cancel another Python operation');
    }
    if (_closed) return;
    if (!_calls.containsKey(callId) && _calls.length >= maxCalls) {
      throw const FormatException('Python transport lifetime limit reached');
    }
    (_calls.putIfAbsent(
      callId,
      () => _Call(_clock.elapsedMilliseconds),
    )).cancelled = true;
    for (final task in _active.values.toList()) {
      if (task.callId == callId) {
        task.fail(const PythonTransportException('cancelled'));
      }
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final task in _active.values.toList()) {
      task.fail(const PythonTransportException('cancelled'));
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
      () => fail(const PythonTransportException('timeout')),
    );
  }

  void phase(int milliseconds) {
    phaseTimer?.cancel();
    phaseTimer = Timer(
      Duration(milliseconds: milliseconds),
      () => fail(const PythonTransportException('timeout')),
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
