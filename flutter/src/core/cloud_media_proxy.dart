import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

/// An ephemeral capability for one authenticated UC file. Credentials never
/// leave this transport or follow a redirect to a different origin.
class CloudMediaLease {
  CloudMediaLease._(this._server, this._client, this._target, this._headers,
      this._isCancelled, this._isCurrent, this._capability) {
    _server.listen(_serve);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _sweep());
  }

  final HttpServer _server;
  final http.Client _client;
  final Uri _target;
  final Map<String, String> _headers;
  final bool Function() _isCancelled;
  final Future<bool> Function() _isCurrent;
  final String _capability;
  final _requests = <HttpRequest>{};
  final _created = DateTime.now();
  DateTime _lastUsed = DateTime.now();
  Timer? _timer;
  bool _closed = false;
  bool _checking = false;

  Uri get url =>
      Uri.parse('http://127.0.0.1:${_server.port}/$_capability/media');

  static bool isTrustedUcMedia(Uri uri) =>
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      (!uri.hasPort || uri.port == 443) &&
      (uri.host == 'uc.cn' ||
          uri.host.endsWith('.uc.cn') ||
          uri.host == 'ucweb.com' ||
          uri.host.endsWith('.ucweb.com'));

  static Future<CloudMediaLease> open(
      {required Uri target,
      required Map<String, String> headers,
      required bool Function() isCancelled,
      required Future<bool> Function() isCurrent,
      http.Client? client}) async {
    if (!isTrustedUcMedia(target)) {
      client?.close();
      throw const FormatException('UC 返回的媒体域名无法安全携带账号会话');
    }
    if (isCancelled() || !await isCurrent()) {
      client?.close();
      throw const FormatException('播放已取消或网盘账号已切换');
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final token = base64Url
        .encode(List.generate(32, (_) => Random.secure().nextInt(256)))
        .replaceAll('=', '');
    return CloudMediaLease._(server, client ?? http.Client(), target,
        Map.of(headers), isCancelled, isCurrent, token);
  }

  Future<void> _sweep() async {
    if (_checking || _closed) return;
    _checking = true;
    try {
      if (_isCancelled() ||
          DateTime.now().difference(_created).inHours >= 12 ||
          (_requests.isEmpty &&
              DateTime.now().difference(_lastUsed).inMinutes >= 5) ||
          !await _isCurrent()) {
        await close();
      }
    } catch (_) {
      await close();
    } finally {
      _checking = false;
    }
  }

  Future<void> _serve(HttpRequest request) async {
    if (_closed ||
        request.uri.path != '/$_capability/media' ||
        request.uri.hasQuery ||
        !const ['GET', 'HEAD'].contains(request.method)) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    if (_requests.length >= 4) {
      request.response.statusCode = HttpStatus.tooManyRequests;
      await request.response.close();
      return;
    }
    _requests.add(request);
    _lastUsed = DateTime.now();
    try {
      if (_isCancelled() || !await _isCurrent()) {
        request.response.statusCode = HttpStatus.gone;
        return;
      }
      final upstream = http.Request(request.method, _target)
        ..followRedirects = false;
      upstream.headers.addAll(_headers);
      final range = request.headers.value('range');
      if (range != null) {
        if (!RegExp(r'^bytes=\d*-\d*$').hasMatch(range) || range == 'bytes=-') {
          request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          return;
        }
        upstream.headers['Range'] = range;
      }
      final response =
          await _client.send(upstream).timeout(const Duration(seconds: 20));
      if (_closed || _isCancelled() || !await _isCurrent()) {
        await response.stream.listen((_) {}).cancel();
        request.response.statusCode = HttpStatus.gone;
        return;
      }
      // Never follow redirects, including redirects to another UC hostname.
      if (!const [200, 206, 416].contains(response.statusCode)) {
        await response.stream.listen((_) {}).cancel();
        request.response.statusCode = HttpStatus.badGateway;
        return;
      }
      final mime = response.headers['content-type'] ?? '';
      if (mime.contains('text/html') || mime.contains('application/json')) {
        await response.stream.listen((_) {}).cancel();
        request.response.statusCode = HttpStatus.badGateway;
        return;
      }
      request.response.statusCode = response.statusCode;
      for (final key in const [
        'content-type',
        'content-length',
        'content-range',
        'accept-ranges',
        'etag',
        'last-modified'
      ]) {
        final value = response.headers[key];
        if (value != null) request.response.headers.set(key, value);
      }
      request.response.headers.set('cache-control', 'no-store');
      if (request.method == 'HEAD') {
        await response.stream.listen((_) {}).cancel();
        return;
      }
      await for (final chunk
          in response.stream.timeout(const Duration(seconds: 30))) {
        if (_closed || _isCancelled()) break;
        request.response.add(chunk);
        await request.response.flush().timeout(const Duration(seconds: 30));
        _lastUsed = DateTime.now();
      }
    } catch (_) {
      // Do not surface upstream URLs, cookies or socket errors to the player.
      try {
        request.response.statusCode = HttpStatus.badGateway;
      } catch (_) {}
    } finally {
      _requests.remove(request);
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    _headers.clear();
    _client.close();
    await _server.close(force: true);
  }
}
