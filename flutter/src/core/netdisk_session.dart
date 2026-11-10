import 'dart:convert';
import 'package:http/http.dart' as http;

/// Official QR tickets are one-use exchange codes, never account cookies.
class NetdiskSession {
  static const ucUserAgent =
      'Mozilla/5.0 (Linux; U; Android 13; zh-CN; V2118A Build/TP1A.220624.014) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/100.0.4896.58 UCBrowser/15.5.8.1238 Mobile Safari/537.36';
  static bool _value(String value) =>
      value.isNotEmpty &&
      value.length <= 16384 &&
      !RegExp(r'[\x00-\x20\x7f;,]').hasMatch(value);

  static bool isUsable(String provider, String credential) {
    if (credential.isEmpty ||
        credential.length > 65536 ||
        RegExp(r'[\r\n]').hasMatch(credential) ||
        RegExp(r'(?:qr_auth_|fallback_|uc_4k_|baidu_qr_auth_|dudu_4k_|ali_refresh_token_)')
            .hasMatch(credential)) {
      return false;
    }
    final pairs = <String, String>{};
    for (final part in credential.split(';')) {
      final separator = part.indexOf('=');
      if (separator > 0) {
        pairs[part.substring(0, separator).trim()] =
            part.substring(separator + 1).trim();
      }
    }
    switch (provider) {
      case 'uc':
        return _value(pairs['__pus'] ?? '') || _value(pairs['__puus'] ?? '');
      // Older releases stored the QR exchange ticket as lowercase bduss.
      // Only the actual official cookie written after exchange is accepted.
      case 'baidu':
        return _value(pairs['BDUSS'] ?? '') && _value(pairs['STOKEN'] ?? '');
      case 'ali':
        final token = credential.startsWith('ali_token=')
            ? credential.substring(10)
            : credential;
        return _value(token) && token.length >= 16 && !token.contains('=');
      default:
        return false;
    }
  }

  static Future<String> exchangeUc(http.Client client, String ticket) async {
    if (!_value(ticket)) throw const FormatException('UC 扫码授权未完成');
    final map = await _get(
        client,
        Uri.https('drive.uc.cn', '/account/mobileinfo',
            {'pr': 'UCBrowser', 'fr': 'h5', 'st': ticket}),
        {'User-Agent': ucUserAgent, 'Referer': 'https://drive.uc.cn/'});
    final data = map['data'];
    final pus = data is Map ? (data['__pus'] ?? '').toString() : '';
    if (!_value(pus)) throw const FormatException('UC 账号会话交换失败，请重新扫码');
    return '__pus=$pus';
  }

  static Future<String> exchangeBaidu(http.Client client, String ticket) async {
    if (!_value(ticket)) throw const FormatException('百度扫码授权未完成');
    final ts = DateTime.now().millisecondsSinceEpoch;
    final map = await _get(
        client,
        Uri.https('passport.baidu.com', '/v3/login/main/qrbdusslogin', {
          'v': '$ts',
          'bduss': ticket,
          'u': 'https%3A%2F%2Fpan.baidu.com%2Fdisk%2Fhome',
          'loginVersion': 'v5',
          'qrcode': '1',
          'tpl': 'netdisk',
          'maskId': '',
          'fileId': '',
          'apiver': 'v3',
          'tt': '$ts',
          'traceid': '',
          'time': '${ts ~/ 1000}',
          'alg': 'v3',
          'elapsed': '10',
          'callback': 'bd__cbs__4wi6y6',
        }),
        {'Referer': 'https://pan.baidu.com/'});
    final data = map['data'];
    Object? session = data is Map ? data['session'] : null;
    if (session is String) session = jsonDecode(session);
    if (session is! Map) throw const FormatException('百度账号会话交换失败，请重新扫码');
    final bduss = (session['bduss'] ?? '').toString();
    if (!_value(bduss) || bduss == ticket) {
      throw const FormatException('百度账号会话无效，请重新扫码');
    }
    if (!_value((session['stoken'] ?? '').toString())) {
      throw const FormatException('百度网盘会话不完整，请重新扫码');
    }
    final cookies = <String>['BDUSS=$bduss'];
    for (final key in const ['stoken', 'ptoken']) {
      final value = (session[key] ?? '').toString();
      if (_value(value)) cookies.add('${key.toUpperCase()}=$value');
    }
    return cookies.join('; ');
  }

  static String aliCredential(Object? bizExt) {
    if (bizExt is! String || bizExt.isEmpty) {
      throw const FormatException('阿里扫码授权未完成');
    }
    final decoded =
        jsonDecode(utf8.decode(base64.decode(base64.normalize(bizExt))));
    final pds = decoded is Map ? decoded['pds_login_result'] : null;
    final token = pds is Map ? (pds['refreshToken'] ?? '').toString() : '';
    final credential = 'ali_token=$token';
    if (!isUsable('ali', credential)) {
      throw const FormatException('阿里账号会话交换失败，请重新扫码');
    }
    return credential;
  }

  static Map decodeObject(String text) {
    var value = text.trim();
    if (!value.startsWith('{')) {
      final match =
          RegExp(r'^(?:[A-Za-z_$][\w$]*\s*)?\((.*)\)\s*;?$', dotAll: true)
              .firstMatch(value);
      if (match == null) throw const FormatException('登录响应无效');
      value = match.group(1)!;
    }
    final decoded = jsonDecode(value);
    if (decoded is! Map) throw const FormatException('登录响应无效');
    return decoded;
  }

  static Future<Map> _get(
      http.Client client, Uri uri, Map<String, String> headers) async {
    return (() async {
      final request = http.Request('GET', uri)..followRedirects = false;
      request.headers.addAll({'Accept': 'application/json', ...headers});
      final response = await client.send(request);
      if (response.statusCode != 200) {
        await response.stream.listen((_) {}).cancel();
        throw const FormatException('网盘账号验证失败');
      }
      final bytes = <int>[];
      await for (final chunk in response.stream) {
        if (bytes.length + chunk.length > 256 * 1024) {
          throw const FormatException('登录响应过大');
        }
        bytes.addAll(chunk);
      }
      return decodeObject(utf8.decode(bytes));
    })()
        .timeout(const Duration(seconds: 8));
  }
}
