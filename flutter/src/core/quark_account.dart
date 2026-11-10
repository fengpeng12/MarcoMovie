import 'dart:async';
import 'dart:convert';
import 'dart:io' show Cookie;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

class QuarkAccountException implements Exception {
  final String code;
  final String message;

  const QuarkAccountException(this.code, this.message);

  @override
  String toString() => message;
}

/// Validated credentials for the fixed Quark account/drive endpoints.
class QuarkAccountSession {
  final String cookie;
  final String driveSt;

  /// A local account isolation key derived from __pus, not a server user ID.
  /// Refreshing the rotating __puus cookie does not change this key.
  final String accountId;
  final DateTime validatedAt;

  const QuarkAccountSession({
    required this.cookie,
    required this.driveSt,
    required this.accountId,
    required this.validatedAt,
  });

  bool get pcApi => true;
  bool get h5Save => driveSt.isNotEmpty;

  String toCredential() => jsonEncode({
    'provider': 'quark',
    'version': 1,
    'cookie': cookie,
    'driveSt': driveSt,
    'accountId': accountId,
    'validatedAt': validatedAt.toUtc().toIso8601String(),
  });

  /// Parses a stored validation record; this alone does not revalidate it online.
  static QuarkAccountSession? tryParseCredential(String value) {
    if (value.length > 40 * 1024) return null;
    try {
      final data = jsonDecode(value);
      if (data is! Map ||
          data['provider'] != 'quark' ||
          data['version'] != 1 ||
          data['cookie'] is! String ||
          data['driveSt'] is! String ||
          data['accountId'] is! String ||
          data['validatedAt'] is! String) {
        return null;
      }
      final jar = _AccountCookies.fromHeader(data['cookie'] as String);
      final at = DateTime.tryParse(data['validatedAt'] as String);
      final ticket = data['driveSt'] as String;
      if (at == null ||
          at.isAfter(DateTime.now().add(const Duration(minutes: 5))) ||
          ticket.isNotEmpty && !_validTicket(ticket) ||
          data['accountId'] != jar.accountId)
        return null;
      return QuarkAccountSession(
        cookie: jar.header,
        driveSt: ticket,
        accountId: jar.accountId,
        validatedAt: at.toUtc(),
      );
    } catch (_) {
      return null;
    }
  }
}

bool _validTicket(String value) =>
    value.isNotEmpty &&
    value.length <= 8192 &&
    !RegExp(r'[\x00-\x20\x7f]').hasMatch(value) &&
    !value.startsWith('fallback_') &&
    !value.contains('qr_auth_');

class _AccountCookies {
  final Map<String, String> _values = {};
  static final _name = RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$");
  static final _invalidValue = RegExp(r'[\x00-\x20\x7f;,]');
  static const _attributes = {
    'path',
    'domain',
    'expires',
    'max-age',
    'secure',
    'httponly',
    'samesite',
    'priority',
    'partitioned',
  };

  _AccountCookies();

  _AccountCookies.fromHeader(String raw) {
    if (raw.isEmpty ||
        raw.length > 16 * 1024 ||
        RegExp(r'[\r\n]').hasMatch(raw)) {
      throw const QuarkAccountException('quark_auth_required', '请验证真实夸克登录凭据');
    }
    for (final part in raw.split(';')) {
      final item = part.trim();
      if (item.isEmpty) continue;
      final equal = item.indexOf('=');
      if (equal <= 0) _badCookie();
      final name = item.substring(0, equal).trim();
      final value = item.substring(equal + 1).trim();
      if (!_name.hasMatch(name) ||
          _attributes.contains(name.toLowerCase()) ||
          _invalidValue.hasMatch(value) ||
          _values.containsKey(name))
        _badCookie();
      _values[name] = value;
    }
    requireIdentity();
  }

  Never _badCookie() => throw const QuarkAccountException(
    'quark_cookie_invalid',
    '夸克 Cookie 格式无效，请重新登录或检查凭据',
  );

  void requireIdentity() {
    final identity = _values['__pus'] ?? '';
    if (!_validTicket(identity)) {
      throw const QuarkAccountException('quark_auth_required', '请先完成夸克账号验证');
    }
  }

  String get accountId {
    requireIdentity();
    return sha256.convert(utf8.encode(_values['__pus']!)).toString();
  }

  String get header =>
      _values.entries.map((e) => '${e.key}=${e.value}').join('; ');

  void receive(http.Response response, Uri endpoint) {
    final raw = response.headers['set-cookie'];
    if (raw == null || raw.isEmpty) return;
    if (raw.length > 32 * 1024) _badCookie();
    // http.Client combines repeated fields. An Expires comma is not a boundary.
    final fields = raw.split(
      RegExp(r"\r?\n|,(?=\s*[!#$%&'*+.^_`|~0-9A-Za-z-]+=)"),
    );
    for (final field in fields) {
      Cookie parsed;
      try {
        parsed = Cookie.fromSetCookieValue(field.trim());
      } catch (_) {
        _badCookie();
      }
      final domain = parsed.domain
          ?.replaceFirst(RegExp(r'^\.'), '')
          .toLowerCase();
      if (domain != null &&
          domain.isNotEmpty &&
          domain != endpoint.host &&
          !endpoint.host.endsWith('.$domain'))
        continue;
      // This is an account credential, not arbitrary cookies for website paths.
      if (parsed.path != null && parsed.path != '/' && parsed.path!.isNotEmpty)
        continue;
      if (!_name.hasMatch(parsed.name) ||
          _attributes.contains(parsed.name.toLowerCase()) ||
          _invalidValue.hasMatch(parsed.value) ||
          parsed.value.length > 8192)
        _badCookie();
      final expired = parsed.maxAge != null
          ? parsed.maxAge! <= 0
          : parsed.expires != null && !parsed.expires!.isAfter(DateTime.now());
      if (expired) {
        _values.remove(parsed.name);
      } else {
        _values[parsed.name] = parsed.value;
      }
    }
    if (_values.length > 64 || header.length > 16 * 1024) _badCookie();
  }
}

class _PendingValidation {
  final String input;
  final int generation;
  String? output;
  late Future<QuarkAccountSession> future;
  _PendingValidation(this.input, this.generation);
}

/// Owns validation and credential refresh, independently of storage/UI classes.
class QuarkAccountProvider {
  final FutureOr<String> Function() readCredential;
  final FutureOr<void> Function(String) writeCredential;
  final http.Client _http;
  final bool _ownsClient;
  int _generation = 0;
  String? _observedCredential;
  QuarkAccountSession? _cached;
  _PendingValidation? _pending;

  QuarkAccountProvider({
    required this.readCredential,
    required this.writeCredential,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  int get generation => _generation;

  /// Call before an external account change, including an A -> B -> A switch.
  void invalidate() {
    _generation++;
    _observedCredential = null;
    _cached = null;
    _pending = null;
  }

  void close() {
    invalidate();
    if (_ownsClient) _http.close();
  }

  Future<void> assertCurrentSession(
    QuarkAccountSession session, {
    int? generation,
  }) async {
    final expected = generation ?? _generation;
    final raw = await readCredential();
    if (expected != _generation || raw != session.toCredential()) {
      throw StateError('夸克账号已更改，请重试');
    }
  }

  Future<QuarkAccountSession> requireSession() async {
    final beforeRead = _generation;
    final raw = await readCredential();
    if (beforeRead != _generation) throw StateError('夸克账号已更改，请重试');
    final pending = _pending;
    if (pending != null && (raw == pending.input || raw == pending.output))
      return pending.future;
    if (_observedCredential != null && _observedCredential != raw) invalidate();
    _observedCredential = raw;
    final cached = _cached;
    if (cached != null &&
        cached.toCredential() == raw &&
        DateTime.now().difference(cached.validatedAt) <
            const Duration(minutes: 5))
      return cached;
    if (raw.trim().isEmpty) {
      throw const QuarkAccountException('quark_auth_required', '请先登录并验证夸克账号');
    }
    final task = _PendingValidation(raw, _generation);
    _pending = task;
    task.future = _refresh(task).whenComplete(() {
      if (identical(_pending, task)) _pending = null;
    });
    return task.future;
  }

  Future<QuarkAccountSession> _refresh(_PendingValidation task) async {
    final stored = QuarkAccountSession.tryParseCredential(task.input);
    final session = await validateCredential(stored?.cookie ?? task.input);
    if (task.generation != _generation ||
        await readCredential() != task.input ||
        task.generation != _generation)
      throw StateError('夸克账号已更改，请重试');
    task.output = session.toCredential();
    await writeCredential(task.output!);
    if (task.generation != _generation ||
        await readCredential() != task.output ||
        task.generation != _generation)
      throw StateError('夸克账号已更改，请重试');
    _observedCredential = task.output;
    _cached = session;
    _generation++;
    return session;
  }

  /// Validates a pasted Cookie. Does not save it or modify the user's drive.
  Future<QuarkAccountSession> validateCredential(String rawCookie) =>
      Future.sync(() => _validate(_AccountCookies.fromHeader(rawCookie)));

  /// QR CAS service_ticket -> account cookies -> validated drive session.
  /// CAS ST and the mobileinfo Drive ST are different credentials.
  Future<QuarkAccountSession> exchangeServiceTicket(String casSt) async {
    if (!_validTicket(casSt)) {
      throw const QuarkAccountException(
        'quark_ticket_invalid',
        '扫码授权凭据无效，请刷新二维码',
      );
    }
    final cookies = _AccountCookies();
    final endpoint = Uri.https('pan.quark.cn', '/account/info', {
      'st': casSt,
      'lw': 'scan',
    });
    final response = await _get(endpoint);
    cookies.receive(response, endpoint);
    cookies.requireIdentity();
    return _validate(cookies, casSt: casSt);
  }

  Future<QuarkAccountSession> _validate(
    _AccountCookies cookies, {
    String? casSt,
  }) async {
    final member = Uri.https('drive-pc.quark.cn', '/1/clouddrive/member', {
      'pr': 'ucpro',
      'fr': 'pc',
      'uc_param_str': '',
      'fetch_subscribe': 'true',
      '_ch': 'home',
      'fetch_identity': 'true',
    });
    final response = await _get(member, cookie: cookies.header);
    final data = _data(response);
    if (!(data['member_type'] is String || data['total_capacity'] is num)) {
      throw const QuarkAccountException(
        'quark_account_invalid',
        '夸克账号验证未返回有效账户信息',
      );
    }
    cookies.receive(response, member);
    cookies.requireIdentity();
    final mobile = Uri.https('pan.quark.cn', '/account/mobileinfo', {
      'pr': 'ucpro',
      'fr': 'h5',
      if (casSt != null) 'st': casSt,
    });
    var activeCookies = cookies;
    var driveSt = '';
    try {
      final mobileResponse = await _get(mobile, cookie: cookies.header);
      final ticket = _data(mobileResponse)['serviceTicket'];
      final updated = _AccountCookies.fromHeader(cookies.header);
      updated.receive(mobileResponse, mobile);
      updated.requireIdentity();
      // A separate H5 response cannot replace the account validated by member.
      if (updated.accountId == cookies.accountId) {
        activeCookies = updated;
        if (ticket is String && _validTicket(ticket)) driveSt = ticket;
      }
    } on QuarkAccountException {
      // PC list/download/play already passed member validation. H5 is an
      // optional capability, never a fabricated substitute ticket.
    }
    return QuarkAccountSession(
      cookie: activeCookies.header,
      driveSt: driveSt,
      accountId: activeCookies.accountId,
      validatedAt: DateTime.now().toUtc(),
    );
  }

  Map _data(http.Response response) {
    try {
      final value = jsonDecode(utf8.decode(response.bodyBytes));
      if (value is Map &&
          value['status'] == 200 &&
          value['code'] == 0 &&
          value['data'] is Map) {
        return value['data'] as Map;
      }
    } catch (_) {}
    throw const QuarkAccountException(
      'quark_account_invalid',
      '夸克账号授权已失效或响应无效，请重新登录',
    );
  }

  Future<http.Response> _get(Uri endpoint, {String? cookie}) async {
    final allowed =
        endpoint.scheme == 'https' &&
        endpoint.userInfo.isEmpty &&
        endpoint.port == 443 &&
        ((endpoint.host == 'pan.quark.cn' &&
                const {
                  '/account/info',
                  '/account/mobileinfo',
                }.contains(endpoint.path)) ||
            endpoint.host == 'drive-pc.quark.cn' &&
                endpoint.path == '/1/clouddrive/member');
    if (!allowed) throw StateError('Unexpected Quark account endpoint');
    try {
      final request = http.Request('GET', endpoint)..followRedirects = false;
      request.headers.addAll({
        'User-Agent': 'Mozilla/5.0',
        'Referer': 'https://pan.quark.cn/',
        'Accept': 'application/json',
        if (cookie != null) 'Cookie': cookie,
      });
      return await (() async {
        final response = await _http.send(request);
        if (response.statusCode != 200) {
          await response.stream.listen((_) {}).cancel();
          throw const QuarkAccountException(
            'quark_account_http',
            '夸克账号验证失败，请重新登录',
          );
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > 1024 * 1024) {
            throw const QuarkAccountException(
              'quark_account_response',
              '夸克账号响应过大',
            );
          }
          bytes.add(chunk);
        }
        return http.Response.bytes(
          bytes.takeBytes(),
          response.statusCode,
          headers: response.headers,
        );
      })().timeout(const Duration(seconds: 8));
    } on QuarkAccountException {
      rethrow;
    } catch (_) {
      throw const QuarkAccountException(
        'quark_account_unavailable',
        '暂时无法验证夸克账号，请稍后重试',
      );
    }
  }
}
