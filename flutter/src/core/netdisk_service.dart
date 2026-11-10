import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'quark_account.dart';
import 'storage_service.dart';

/// Descriptor for each of the 4 TV netdisk drives (`我的夸父`, `我的优汐`, `我的嘟嘟`, `我的阿狸`).
class NetdiskDriveInfo {
  final String key;
  final String tvName;
  final String providerName;
  final String appHint;
  final String linePrefix;

  const NetdiskDriveInfo({
    required this.key,
    required this.tvName,
    required this.providerName,
    required this.appHint,
    required this.linePrefix,
  });

  static const List<NetdiskDriveInfo> all = [
    NetdiskDriveInfo(
      key: 'quark',
      tvName: '我的夸父',
      providerName: '夸克网盘',
      appHint: '请使用手机「夸克 App」扫描二维码登录',
      linePrefix: '夸父智1',
    ),
    NetdiskDriveInfo(
      key: 'uc',
      tvName: '我的优汐',
      providerName: 'UC网盘',
      appHint: '请使用手机「UC浏览器 App」扫描二维码登录',
      linePrefix: '优汐智1',
    ),
    NetdiskDriveInfo(
      key: 'baidu',
      tvName: '我的嘟嘟',
      providerName: '百度网盘',
      appHint: '请使用手机「百度网盘 App」扫描二维码登录',
      linePrefix: '嘟嘟无限2',
    ),
    NetdiskDriveInfo(
      key: 'ali',
      tvName: '我的阿狸',
      providerName: '阿里云盘',
      appHint: '请使用手机「阿里云盘 App」扫描二维码登录',
      linePrefix: '阿狸原画',
    ),
  ];

  String get tvAlias => tvName;
  List<String> get lineBadges => [linePrefix];

  static NetdiskDriveInfo byKey(String key) {
    return all.firstWhere(
      (d) => d.key == key,
      orElse: () => all.first,
    );
  }
}

/// Active QR Code login session returned by [NetdiskService.startQrSession].
class NetdiskQrSession {
  final String driveKey;
  final String qrContentUrl;
  final String qrImageUrl;
  final String token;
  final Map<String, String> extra;

  const NetdiskQrSession({
    required this.driveKey,
    required this.qrContentUrl,
    required this.qrImageUrl,
    required this.token,
    this.extra = const {},
  });

  String get qrContent => qrContentUrl;
}

enum NetdiskPollState {
  waiting,
  scanned,
  confirmed,
  expired,
  error,
}

class NetdiskPollResult {
  final NetdiskPollState state;
  final String message;
  final String credential;

  const NetdiskPollResult({
    required this.state,
    required this.message,
    this.credential = '',
  });

  String get status => state.name;
}

/// Handles official QR code generation and login polling for Quark (`我的夸父`),
/// UC (`我的优汐`), Baidu (`我的嘟嘟`), and AliyunDrive (`我的阿狸`), matching the TV
/// `csp_MyDriveGuard` (`🗂我的云盘┃配置`) experience.
class NetdiskService {
  static List<NetdiskDriveInfo> get drives => NetdiskDriveInfo.all;
  final http.Client _http;
  final bool _ownsClient;
  late final QuarkAccountProvider _quarkAccounts;

  NetdiskService({http.Client? httpClient, QuarkAccountProvider? quarkAccounts})
      : _http = httpClient ?? http.Client(), _ownsClient = httpClient == null {
    _quarkAccounts = quarkAccounts ?? QuarkAccountProvider(
      readCredential: () => '', writeCredential: (_) {}, httpClient: _http);
  }

  void close() {
    if (_ownsClient) _http.close();
  }

  static const Map<String, String> _commonHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15',
    'Accept': 'application/json, text/plain, */*',
  };

  static bool isLoggedIn(StorageService storage, String driveKey) {
    return storage.isNetdiskLoggedIn(driveKey);
  }

  static String statusLabel(StorageService storage, String driveKey) {
    return isLoggedIn(storage, driveKey) ? '已登录+启用中' : '未登录 · 点击扫码';
  }

  /// Retained for API compatibility. The UI renders qrContent locally; login
  /// tokens must never be sent to a third-party QR image service.
  static String buildQrRenderUrl(String content) => '';

  /// Starts a real QR login session with the official cloud drive passport API.
  Future<NetdiskQrSession> createQrSession(String driveKey) => startQrSession(driveKey);
  Future<NetdiskPollResult> pollQrStatus(NetdiskQrSession session) => pollQrSession(session);

  Future<NetdiskQrSession> startQrSession(String driveKey) async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    try {
      if (driveKey == 'quark') {
        final map = await _quarkPassport('/cas/ajax/getTokenForQrcodeLogin',
            {'client_id': '532', 'v': '1.2', 'request_id': '$ts'});
        if (map['status'] != 2000000) throw const FormatException('夸克二维码创建失败');
        final data = map['data'] as Map? ?? const {};
        final members = data['members'] as Map? ?? const {};
        final token = members['token'];
        if (token is String && _validQuarkToken(token)) {
          final qrContent = Uri.https('su.quark.cn', '/4_eMHBJ', {
            'token': token,
            'client_id': '532',
            'ssb': 'weblogin',
            'uc_param_str':
                'dsdnfrpfbivesscpgimibtbmnijblauputogpintnwktprchmt',
            'uc_biz_str':
                'S:custom|OPT:SAREA@0|OPT:IMMERSIVE@1|OPT:BACK_BTN_STYLE@0',
          }).toString();
          return NetdiskQrSession(
            driveKey: driveKey,
            qrContentUrl: qrContent,
            qrImageUrl: buildQrRenderUrl(qrContent),
            token: token,
          );
        }
        throw const FormatException('夸克二维码创建失败，请稍后重试');
      } else if (driveKey == 'uc') {
        final uri = Uri.parse(
          'https://api.open.uc.cn/cas/ajax/getTokenForQrcodeLogin?client_id=381&v=1.2&request_id=$ts',
        );
        final res = await _http
            .get(uri, headers: _commonHeaders)
            .timeout(const Duration(seconds: 8));
        final map = jsonDecode(utf8.decode(res.bodyBytes)) as Map;
        final data = map['data'] as Map? ?? const {};
        final members = data['members'] as Map? ?? const {};
        final token = (members['token'] ?? '').toString();
        if (token.isNotEmpty) {
          final qrContent =
              'https://su.uc.cn/1_n0ZCv?uc_param_str=dsdnfrpfbivesscpgimibtbmnijblauputogpintnwktprchmt&token=$token&client_id=381&uc_biz_str=S%3Acustom%7CC%3Atitlebar_fix';
          return NetdiskQrSession(
            driveKey: driveKey,
            qrContentUrl: qrContent,
            qrImageUrl: buildQrRenderUrl(qrContent),
            token: token,
          );
        }
      } else if (driveKey == 'baidu') {
        final uri = Uri.parse(
          'https://passport.baidu.com/v2/api/getqrcode?lp=pc&qrloginfrom=pc&tt=$ts',
        );
        final res = await _http
            .get(uri, headers: _commonHeaders)
            .timeout(const Duration(seconds: 8));
        final map = jsonDecode(utf8.decode(res.bodyBytes)) as Map;
        final sign = (map['sign'] ?? '').toString();
        final imgurl = (map['imgurl'] ?? '').toString();
        if (sign.isNotEmpty) {
          final qrContent =
              'https://wappass.baidu.com/wp/?qrlogin=&t=${ts ~/ 1000}&error=0&sign=$sign&cmd=qf';
          final directImg = imgurl.isNotEmpty
              ? (imgurl.startsWith('http') ? imgurl : ['https', '://', imgurl].join())
              : buildQrRenderUrl(qrContent);
          return NetdiskQrSession(
            driveKey: driveKey,
            qrContentUrl: qrContent,
            qrImageUrl: directImg,
            token: sign,
          );
        }
      } else if (driveKey == 'ali') {
        final uri = Uri.parse(
          'https://passport.aliyundrive.com/newlogin/qrcode/generate.do?appName=aliyun_drive&fromSite=52&appEntrance=web&_csrf_token=',
        );
        final res = await _http
            .get(uri, headers: _commonHeaders)
            .timeout(const Duration(seconds: 8));
        final map = jsonDecode(utf8.decode(res.bodyBytes)) as Map;
        final content =
            (map['content'] as Map?)?['data'] as Map? ?? const {};
        final codeContent = (content['codeContent'] ?? '').toString();
        final ck = (content['ck'] ?? '').toString();
        final t = (content['t'] ?? '').toString();
        if (codeContent.isNotEmpty && ck.isNotEmpty) {
          return NetdiskQrSession(
            driveKey: driveKey,
            qrContentUrl: codeContent,
            qrImageUrl: buildQrRenderUrl(codeContent),
            token: ck,
            extra: {'t': t, 'codeContent': codeContent},
          );
        }
      }
    } catch (_) {
      if (driveKey == 'quark') {
        throw const FormatException('暂时无法创建夸克登录二维码，请稍后重试');
      }
      // Fallback below if network or passport endpoint is blocked.
    }

    final fallbackUrl = switch (driveKey) {
      'quark' => 'https://pan.quark.cn/',
      'uc' => 'https://drive.uc.cn/',
      'baidu' => 'https://pan.baidu.com/',
      'ali' => 'https://www.alipan.com/',
      _ => 'https://pan.quark.cn/',
    };
    return NetdiskQrSession(
      driveKey: driveKey,
      qrContentUrl: fallbackUrl,
      qrImageUrl: buildQrRenderUrl(fallbackUrl),
      token: 'fallback_$ts',
    );
  }

  /// Polls the QR login status for [session].
  Future<NetdiskPollResult> pollQrSession(NetdiskQrSession session) async {
    if (session.driveKey == 'quark' && !_validQuarkToken(session.token)) {
      return const NetdiskPollResult(state: NetdiskPollState.error,
          message: '夸克二维码已失效，请刷新后重试');
    }
    if (session.token.startsWith('fallback_')) {
      return const NetdiskPollResult(
        state: NetdiskPollState.error,
        message: '网盘登录暂时不可用，请刷新二维码后重试',
      );
    }
    final ts = DateTime.now().millisecondsSinceEpoch;
    try {
      if (session.driveKey == 'quark') {
        final map = await _quarkPassport('/cas/ajax/getServiceTicketByQrcodeToken',
            {'client_id': '532', 'v': '1.2', 'token': session.token, 'request_id': '$ts'});
        final status = map['status'];
        if (status == 2000000) {
          final st = ((map['data'] as Map?)?['members'] as Map?)?['service_ticket'];
          if (st is! String) throw const FormatException('扫码授权凭据无效');
          final account = await _quarkAccounts.exchangeServiceTicket(st);
          return NetdiskPollResult(
            state: NetdiskPollState.confirmed,
            message: '夸父（夸克网盘）扫码登录成功！',
            credential: account.toCredential(),
          );
        } else if (status == 50004002) {
          return const NetdiskPollResult(
            state: NetdiskPollState.expired,
            message: '二维码已过期，请点击刷新二维码',
          );
        }
        if (status != 50004001) {
          return const NetdiskPollResult(state: NetdiskPollState.error,
              message: '夸克扫码授权尚未完成，请刷新后重试');
        }
        return const NetdiskPollResult(
          state: NetdiskPollState.waiting,
          message: '等待使用手机「夸克 App」扫码并确认…',
        );
      } else if (session.driveKey == 'uc') {
        final uri = Uri.parse(
          'https://api.open.uc.cn/cas/ajax/getServiceTicketByQrcodeToken?client_id=381&v=1.2&token=${session.token}&request_id=$ts',
        );
        final res = await _http
            .get(uri, headers: _commonHeaders)
            .timeout(const Duration(seconds: 6));
        final map = jsonDecode(utf8.decode(res.bodyBytes)) as Map;
        final status = map['status'];
        if (status == 2000000) {
          final st =
              (((map['data'] as Map?)?['members'] as Map?)?['service_ticket'] ??
                      '')
                  .toString();
          return NetdiskPollResult(
            state: NetdiskPollState.confirmed,
            message: '优汐（UC网盘）扫码登录成功！',
            credential: 'uc_st=$st; token=${session.token}',
          );
        } else if (status == 50004002) {
          return const NetdiskPollResult(
            state: NetdiskPollState.expired,
            message: '二维码已过期，请点击刷新二维码',
          );
        }
        return const NetdiskPollResult(
          state: NetdiskPollState.waiting,
          message: '等待使用手机「UC浏览器 App」扫码并确认…',
        );
      } else if (session.driveKey == 'baidu') {
        final uri = Uri.parse(
          'https://passport.baidu.com/channel/unicast?channel_id=${session.token}&tpl=netdisk&apiver=v3&tt=$ts',
        );
        final res = await _http
            .get(uri, headers: _commonHeaders)
            .timeout(const Duration(seconds: 6));
        final body = utf8.decode(res.bodyBytes).trim();
        final jsonStr = body.startsWith('(') && body.endsWith(')')
            ? body.substring(1, body.length - 1)
            : body;
        final map = jsonDecode(jsonStr) as Map;
        final errno = map['errno'];
        if (errno == 0 && map['channel_v'] != null) {
          final cv = jsonDecode(map['channel_v'].toString()) as Map;
          final status = cv['status'];
          if (status == 1) {
            return const NetdiskPollResult(
              state: NetdiskPollState.scanned,
              message: '已扫码，请在手机百度网盘上点击「确认登录」…',
            );
          } else if (status == 0 && cv['v'] != null) {
            return NetdiskPollResult(
              state: NetdiskPollState.confirmed,
              message: '嘟嘟（百度网盘）扫码登录成功！',
              credential: 'bduss=${cv['v']}',
            );
          }
        }
        return const NetdiskPollResult(
          state: NetdiskPollState.waiting,
          message: '等待使用手机「百度网盘 App」扫码并确认…',
        );
      } else if (session.driveKey == 'ali') {
        final uri = Uri.parse(
          'https://passport.aliyundrive.com/newlogin/qrcode/query.do?appName=aliyun_drive&fromSite=52',
        );
        final res = await _http
            .post(
              uri,
              headers: {
                ..._commonHeaders,
                'Content-Type': 'application/x-www-form-urlencoded',
              },
              body: {
                'ck': session.token,
                't': session.extra['t'] ?? '',
              },
            )
            .timeout(const Duration(seconds: 6));
        final map = jsonDecode(utf8.decode(res.bodyBytes)) as Map;
        final data =
            (map['content'] as Map?)?['data'] as Map? ?? const {};
        final status = (data['qrCodeStatus'] ?? '').toString();
        if (status == 'CONFIRMED') {
          String token = (data['bizExt'] ?? session.token).toString();
          return NetdiskPollResult(
            state: NetdiskPollState.confirmed,
            message: '阿狸（阿里云盘）扫码登录成功！',
            credential: 'ali_token=$token',
          );
        } else if (status == 'SCANED') {
          return const NetdiskPollResult(
            state: NetdiskPollState.scanned,
            message: '已扫码，请在手机阿里云盘上点击「确认登录」…',
          );
        } else if (status == 'EXPIRED') {
          return const NetdiskPollResult(
            state: NetdiskPollState.expired,
            message: '二维码已过期，请点击刷新二维码',
          );
        }
        return const NetdiskPollResult(
          state: NetdiskPollState.waiting,
          message: '等待使用手机「阿里云盘 App」扫码并确认…',
        );
      }
    } catch (_) {
      if (session.driveKey == 'quark') {
        return const NetdiskPollResult(state: NetdiskPollState.error,
            message: '夸克账号验证失败，请重新扫码');
      }
    }
    return const NetdiskPollResult(
      state: NetdiskPollState.waiting,
      message: '等待手机端扫码授权…',
    );
  }

  static bool _validQuarkToken(String value) => value.isNotEmpty && value.length <= 8192 &&
      !RegExp(r'[\x00-\x20\x7f]').hasMatch(value) && !value.startsWith('fallback_');

  Future<Map> _quarkPassport(String path, Map<String, String> parameters) async {
    if (!const {'/cas/ajax/getTokenForQrcodeLogin',
      '/cas/ajax/getServiceTicketByQrcodeToken'}.contains(path)) {
      throw StateError('Unexpected Quark passport endpoint');
    }
    final request = http.Request('GET', Uri.https('uop.quark.cn', path, parameters))
      ..followRedirects = false;
    request.headers.addAll(_commonHeaders);
    return (() async {
      final response = await _http.send(request);
      if (response.statusCode != 200) {
        await response.stream.listen((_) {}).cancel();
        throw const FormatException('夸克登录服务暂时不可用');
      }
      final bytes = <int>[];
      await for (final part in response.stream) {
        if (bytes.length + part.length > 256 * 1024) {
          throw const FormatException('夸克登录响应无效');
        }
        bytes.addAll(part);
      }
      final data = jsonDecode(utf8.decode(bytes));
      if (data is! Map) throw const FormatException('夸克登录响应无效');
      return data;
    })().timeout(const Duration(seconds: 8));
  }
}
