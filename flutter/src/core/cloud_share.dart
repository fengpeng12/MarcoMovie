import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'models.dart';
import 'cloud_media_proxy.dart';

/// Native UC/Baidu share readers. Protocols are scoped to the original provider;
/// a failed share is never replaced by a search result from another source.
///
/// The UC fast-download and Baidu share DLNA paths do not create, transfer or
/// delete files. Temporary share tokens and account cookies stay in memory.
class CloudShareClient {
  CloudShareClient({
    http.Client? client,
    required this.credentialReader,
    DateTime Function()? clock,
    bool Function()? isCancelled,
    http.Client Function()? mediaClientFactory,
  })  : _http = client ?? http.Client(),
        _ownsClient = client == null,
        _clock = clock ?? DateTime.now,
        _isCancelled = isCancelled ?? (() => false),
        _mediaClientFactory = mediaClientFactory ?? http.Client.new;

  final http.Client _http;
  final bool _ownsClient;
  final Future<String> Function(String provider) credentialReader;
  final DateTime Function() _clock;
  final bool Function() _isCancelled;
  final http.Client Function() _mediaClientFactory;

  void _checkCancelled() {
    if (_isCancelled()) throw const FormatException('播放已取消');
  }

  static const _pageSize = 100;
  static const _maxDirectories = 256;
  static const _maxFiles = 20000;
  static const _maxResponseBytes = 4 * 1024 * 1024;
  static const _ucUa =
      'Mozilla/5.0 (Linux; U; Android 13; zh-CN; V2118A Build/TP1A.220624.014) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 '
      'Chrome/100.0.4896.58 UCBrowser/15.5.8.1238 Mobile Safari/537.36';
  static const _baiduUa =
      'netdisk;12.24.6;V2118A;android-android;12;JSbridge4.4.0;jointBridge;1.1.0';
  static const _baiduMediaUa = 'netdisk;P2SP;2.2.91.136;android-android;';
  static const _ucMediaUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) uc-cloud-drive/2.5.20 Chrome/100.0.4896.160 '
      'Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch';

  void dispose() {
    if (_ownsClient) _http.close();
  }

  void close() => dispose();

  static bool supportsShare(String url) => _Share.parse(url) != null;
  static bool supportsEpisode(String url) {
    final uri = Uri.tryParse(url);
    return uri?.scheme == 'mmcloud' &&
        uri!.userInfo.isEmpty &&
        !uri.hasPort &&
        const ['uc', 'baidu'].contains(uri.host);
  }

  Future<List<CmsEpisode>> listShare(String shareUrl) async {
    final share = _Share.parse(shareUrl);
    if (share == null) throw const FormatException('不支持的网盘分享地址');
    final files = share.provider == 'uc'
        ? await _ucFiles(share)
        : await _baiduFiles(share);
    return files
        .map((file) => CmsEpisode(
              name: file.name,
              url: Uri(
                  scheme: 'mmcloud',
                  host: share.provider,
                  queryParameters: {
                    'share': share.url,
                    'fid': file.id,
                    'parent': file.parent,
                    'name': file.name,
                    'size': '${file.size}',
                    if (file.path.isNotEmpty) 'path': file.path,
                  }).toString(),
              playbackSession: {
                'provider': share.provider,
                'fileName': file.name,
                'sizeBytes': file.size,
                'path': file.path,
              },
            ))
        .toList(growable: false);
  }

  Future<CmsEpisode> resolve(CmsEpisode episode) async {
    final uri = Uri.tryParse(episode.url);
    if (!supportsEpisode(episode.url) || uri == null) {
      throw const FormatException('不是受支持的网盘剧集');
    }
    final share = _Share.parse(uri.queryParameters['share'] ?? '');
    final fid = uri.queryParameters['fid'] ?? '';
    if (share == null || share.provider != uri.host || fid.isEmpty) {
      throw const FormatException('网盘剧集的来源信息无效');
    }
    // Always refresh directory membership and transient tokens. Stable references
    // cannot be turned into an arbitrary file-download request.
    final files = share.provider == 'uc'
        ? await _ucFiles(share)
        : await _baiduFiles(share);
    final selected = files.where((file) => file.id == fid).firstOrNull;
    if (selected == null) throw const FormatException('原分享中已找不到此视频');
    final media = share.provider == 'uc'
        ? await _resolveUc(share, selected)
        : await _resolveBaidu(share, selected);
    if (_isCancelled()) {
      await selected.lease?.close();
      _checkCancelled();
    }
    final mediaHeaders = <String, String>{
      'User-Agent': share.provider == 'uc' ? _ucMediaUa : _baiduMediaUa,
      'Referer': share.provider == 'uc'
          ? 'https://drive.uc.cn/'
          : 'https://pan.baidu.com/',
      // This is a guest-only callback token issued in the same response as the
      // exact media URL; account cookies are never exposed to the media player.
      if (selected.lease == null &&
          (selected.session['guestCookie'] ?? '').isNotEmpty)
        'Cookie': selected.session['guestCookie']!,
    };
    return CmsEpisode(
      name: episode.name,
      url: media,
      headers: mediaHeaders,
      variants: [
        CmsEpisode(
            name: '原画',
            url: media,
            headers: mediaHeaders,
            playbackSession: {
              if (selected.lease != null) 'cloudMediaLease': selected.lease
            })
      ],
      playbackSession: {
        'provider': share.provider,
        'fileName': selected.name,
        'sizeBytes': selected.size,
        'quality': 'original',
        'sourceReference': episode.url,
        if (selected.lease != null) 'cloudMediaLease': selected.lease,
      },
    );
  }

  Future<List<_CloudFile>> _ucFiles(_Share share) async {
    final token = await _json(
        Uri.https(
            'pc-api.uc.cn', '/1/clouddrive/share/sharepage/token', _ucQuery),
        provider: 'uc',
        budget: share.budget,
        body: {'pwd_id': share.id, 'passcode': share.passcode});
    _checkUc(token);
    final stoken = _string(_map(token['data'])['stoken']);
    if (stoken.isEmpty) throw const FormatException('UC 分享未返回访问凭据');
    final files = <_CloudFile>[];
    final pending = <({String id, String path})>[(id: '0', path: '')];
    final visited = <String>{};
    final seenFiles = <String>{};
    for (var cursor = 0; cursor < pending.length; cursor++) {
      if (cursor >= _maxDirectories) {
        throw const FormatException('UC 分享目录过多，请打开更具体的分享目录');
      }
      final dir = pending[cursor];
      if (!visited.add(dir.id)) continue;
      var fetched = 0;
      final pageFingerprints = <String>{};
      for (var page = 1; page <= 200; page++) {
        final result = await _json(
            Uri.https('pc-api.uc.cn', '/1/clouddrive/share/sharepage/detail', {
              ..._ucQuery,
              'pwd_id': share.id,
              'stoken': stoken,
              'pdir_fid': dir.id,
              'force': '0',
              '_page': '$page',
              '_size': '$_pageSize',
              '_fetch_banner': '0',
              '_fetch_share': '0',
              '_fetch_total': '1',
              '_sort': 'file_type:asc,file_name:asc',
            }),
            provider: 'uc',
            budget: share.budget);
        _checkUc(result);
        final rows = _map(result['data'])['list'];
        if (rows is! List) throw const FormatException('UC 分享目录响应无效');
        final fingerprint =
            rows.whereType<Map>().map((row) => row['fid']).join('|');
        if (rows.isNotEmpty && !pageFingerprints.add(fingerprint)) {
          throw const FormatException('UC 分享分页重复，无法完整读取目录');
        }
        for (final row in rows.whereType<Map>()) {
          final id = _string(row['fid']);
          final name = _string(row['file_name']);
          if (id.isEmpty || name.isEmpty) continue;
          final path = dir.path.isEmpty ? name : '${dir.path}/$name';
          if (row['dir'] == true || _integer(row['file_type']) == 0) {
            if (!visited.contains(id) &&
                !pending.any((item) => item.id == id)) {
              pending.add((id: id, path: path));
            }
          } else if (_video(row, name) && seenFiles.add(id)) {
            files.add(_CloudFile(
                id: id,
                parent: dir.id,
                name: name,
                size: _size(row['size']),
                path: path,
                session: {
                  'stoken': stoken,
                  'fileToken': _string(row['share_fid_token'])
                }));
          }
        }
        fetched += rows.length;
        if (files.length > _maxFiles) {
          throw const FormatException('UC 分享视频过多，请打开更具体的分享目录');
        }
        final total = _integer(_map(result['metadata'])['_total']);
        if (rows.isEmpty ||
            (total > 0 && fetched >= total) ||
            (total <= 0 && rows.length < _pageSize)) {
          break;
        }
        if (page == 200) {
          throw const FormatException('UC 分享分页没有继续返回内容');
        }
      }
    }
    return files;
  }

  Future<String> _resolveUc(_Share share, _CloudFile file) async {
    final fileToken = file.session['fileToken'] ?? '';
    if (fileToken.isEmpty) throw const FormatException('UC 分享缺少文件访问凭据');
    final guestCookies = <String, String>{};
    final result = await _json(
        Uri.https('pc-api.uc.cn', '/1/clouddrive/file/download',
            {'entry': 'ft', 'fr': 'pc', 'pr': 'UCBrowser'}),
        provider: 'uc',
        budget: share.budget,
        cookies: guestCookies,
        userAgent: _ucMediaUa,
        referer: 'https://fast.uc.cn/',
        body: {
          'fids': [file.id],
          'pwd_id': share.id,
          'stoken': file.session['stoken'],
          'fids_token': [fileToken],
        });
    if ((result.containsKey('code') && _integer(result['code']) != 0) ||
        (result.containsKey('status') && _integer(result['status']) != 200)) {
      return _resolveUcAccount(share, file);
    }
    final data = result['data'];
    final row = data is List && data.isNotEmpty ? _map(data.first) : const {};
    if ((_string(row['fid']).isNotEmpty && _string(row['fid']) != file.id) ||
        (_size(row['size']) > 0 &&
            file.size > 0 &&
            _size(row['size']) != file.size) ||
        _string(row['md5']) == 'ffc6341c056de41cf4ab95343d9c22fe') {
      return _resolveUcAccount(share, file);
    }
    final url = _mediaUrl(row['download_url'], 'UC 未返回该原始文件的播放地址');
    final pugs = guestCookies['__pugs'];
    if (pugs != null) file.session['guestCookie'] = '__pugs=$pugs';
    return url;
  }

  Future<String> _resolveUcAccount(_Share share, _CloudFile file) async {
    final credential = await credentialReader('uc');
    final cookies = _ucCredentialCookies(credential);
    if (cookies.isEmpty) {
      throw const FormatException('此 UC 视频需要已登录账号，请在网盘面板重新扫码登录');
    }
    if (cookies.containsKey('__pus')) cookies.remove('__puus');
    Future<bool> current() async =>
        !_isCancelled() && await credentialReader('uc') == credential;
    Future<void> check() async {
      if (!await current()) throw const FormatException('播放已取消或 UC 账号已切换');
    }

    await check();
    // Refresh UC's short-lived API cookie; only the fixed API receives it.
    final config = await _json(
        Uri.https('pc-api.uc.cn', '/1/clouddrive/config',
            {'pr': 'UCBrowser', 'fr': 'pc'}),
        provider: 'uc',
        budget: share.budget,
        cookies: cookies,
        userAgent: _ucMediaUa);
    await check();
    _checkUc(config);
    final result = await _json(
        Uri.https('pc-api.uc.cn', '/1/clouddrive/file/download',
            {'entry': 'ft', 'fr': 'pc', 'pr': 'UCBrowser'}),
        provider: 'uc',
        budget: share.budget,
        cookies: cookies,
        userAgent: _ucMediaUa,
        body: {
          'fids': [file.id],
          'pwd_id': share.id,
          'stoken': file.session['stoken'],
          'fids_token': [file.session['fileToken']]
        });
    await check();
    _checkUc(result);
    final data = result['data'];
    final row = data is List && data.isNotEmpty ? _map(data.first) : const {};
    if ((_string(row['fid']).isNotEmpty && _string(row['fid']) != file.id) ||
        (_size(row['size']) > 0 &&
            file.size > 0 &&
            _size(row['size']) != file.size) ||
        _string(row['md5']) == 'ffc6341c056de41cf4ab95343d9c22fe') {
      throw const FormatException('UC 登录后仍未返回原始文件，请检查账号权限');
    }
    final target =
        Uri.parse(_mediaUrl(row['download_url'], 'UC 账号没有返回此文件的原画地址'));
    final accountCookie = cookies.entries
        .where((entry) => const ['__pus', '__puus'].contains(entry.key))
        .map((entry) => '${entry.key}=${entry.value}')
        .join('; ');
    final lease = await CloudMediaLease.open(
        target: target,
        headers: {
          'Cookie': accountCookie,
          'User-Agent': _ucMediaUa,
          'Referer': 'https://drive.uc.cn/',
          'Origin': 'https://drive.uc.cn'
        },
        isCancelled: _isCancelled,
        isCurrent: current,
        client: _mediaClientFactory());
    try {
      await check();
    } catch (_) {
      await lease.close();
      rethrow;
    }
    file.lease = lease;
    return lease.url.toString();
  }

  Future<List<_CloudFile>> _baiduFiles(_Share share) async {
    var sekey = '';
    // Visiting the share is part of the original browser verification flow.
    // Keep only provider-issued share cookies, never global import headers.
    final cookies = <String, String>{};
    await _request(
        Uri.https('pan.baidu.com', '/s/${share.id}', {
          if (share.passcode.isNotEmpty) 'pwd': share.passcode,
        }),
        provider: 'baidu',
        budget: share.budget,
        cookies: cookies,
        allowShareRedirect: true);
    if (share.passcode.isNotEmpty) {
      final verify = await _baiduJson(
          Uri.https('pan.baidu.com', '/share/verify', {
            't': '${_clock().millisecondsSinceEpoch}',
            'surl': share.shortId,
            'channel': 'chunlei',
            'web': '1',
            'bdstoken': '',
            'logid': '',
            'clienttype': '0',
          }),
          share: share,
          cookies: cookies,
          referer: Uri.https('pan.baidu.com', '/share/init',
              {'surl': share.id, 'pwd': share.passcode}).toString(),
          form: {'pwd': share.passcode, 'vcode': '', 'vcode_str': ''});
      _checkBaidu(verify);
      sekey = _string(verify['randsk']);
      if (sekey.isEmpty) throw const FormatException('百度分享提取码验证未完成');
      cookies['BDCLND'] = sekey;
    } else {
      sekey = cookies['BDCLND'] ?? '';
    }
    final files = <_CloudFile>[];
    final dirs = <Map<String, String>>[
      {'path': '', 'id': '0'}
    ];
    final seenDirs = <String>{};
    final seenFiles = <String>{};
    var uk = '';
    var shareId = '';
    for (var cursor = 0; cursor < dirs.length; cursor++) {
      if (cursor >= _maxDirectories) {
        throw const FormatException('百度分享目录过多，请打开更具体的分享目录');
      }
      final dir = dirs[cursor];
      if (!seenDirs.add(dir['id']!)) continue;
      final root = cursor == 0;
      final pageSize = root ? 20 : _pageSize;
      final pageFingerprints = <String>{};
      for (var page = 1; page <= 200; page++) {
        final result = await _baiduJson(
            Uri.https('pan.baidu.com', '/share/list', {
              'desc': root ? '1' : '0',
              'showempty': '0',
              'page': '$page',
              'num': '$pageSize',
              'order': root ? 'time' : 'name',
              'view_mode': '1',
              'channel': 'chunlei',
              'web': '1',
              'bdstoken': '',
              'clienttype': '0',
              if (root) ...{
                'shorturl': share.shortId,
                'root': '1'
              } else ...{
                'is_from_web': 'true',
                'sekey': sekey,
                'uk': uk,
                'shareid': shareId,
                'dir': dir['path']!,
                'app_id': '250528'
              },
            }),
            share: share,
            cookies: cookies);
        _checkBaidu(result);
        uk = _string(result['uk']).isNotEmpty ? _string(result['uk']) : uk;
        shareId = _string(result['share_id']).isNotEmpty
            ? _string(result['share_id'])
            : shareId;
        final rows = result['list'];
        if (rows is! List) throw const FormatException('百度分享目录响应无效');
        final fingerprint =
            rows.whereType<Map>().map((row) => row['fs_id']).join('|');
        if (rows.isNotEmpty && !pageFingerprints.add(fingerprint)) {
          throw const FormatException('百度分享分页重复，无法完整读取目录');
        }
        for (final row in rows.whereType<Map>()) {
          final id = _string(row['fs_id']);
          final name = _string(row['server_filename']);
          if (id.isEmpty || name.isEmpty) continue;
          final path = _string(row['path']);
          if (_integer(row['isdir']) == 1) {
            if (!seenDirs.contains(id) &&
                !dirs.any((item) => item['id'] == id)) {
              // The original plugin uses a virtual /sharelink<uk>-<fid> path.
              final prefix = RegExp(r'^/?sharelink[^/]+');
              final suffix = prefix.hasMatch(path)
                  ? path.replaceFirst(prefix, '')
                  : '/$name';
              dirs.add({'id': id, 'path': '/sharelink$uk-$id$suffix'});
            }
          } else if (_video(row, name) && seenFiles.add(id)) {
            files.add(_CloudFile(
                id: id,
                parent: dir['id']!,
                name: name,
                size: _size(row['size']),
                path: path,
                session: {'sekey': sekey, 'uk': uk, 'shareId': shareId}));
          }
        }
        if (files.length > _maxFiles) {
          throw const FormatException('百度分享视频过多，请打开更具体的分享目录');
        }
        if (rows.length < pageSize) break;
        if (page == 200) {
          throw const FormatException('百度分享分页没有继续返回内容');
        }
      }
    }
    return files;
  }

  Future<Map> _baiduJson(Uri uri,
      {required _Share share,
      required Map<String, String> cookies,
      Map<String, String>? form,
      String? referer}) async {
    var result = await _json(uri,
        provider: 'baidu',
        budget: share.budget,
        cookies: cookies,
        form: form,
        referer: referer);
    if (_integer(result['errno']) == 0) return result;
    // Retry the same request with an existing account; captchas remain errors.
    final credential = await credentialReader('baidu');
    final account = _credentialCookies(credential);
    if ((account['BDUSS'] ?? '').isEmpty || (account['STOKEN'] ?? '').isEmpty) {
      return result;
    }
    _checkCancelled();
    if (await credentialReader('baidu') != credential) {
      throw const FormatException('百度账号已切换，请重新打开分享');
    }
    cookies.addAll(account);
    result = await _json(uri,
        provider: 'baidu',
        budget: share.budget,
        cookies: cookies,
        form: form,
        referer: referer);
    if (await credentialReader('baidu') != credential) {
      throw const FormatException('百度账号已切换，请重新打开分享');
    }
    return result;
  }

  Future<String> _resolveBaidu(_Share share, _CloudFile file) async {
    final credential = await credentialReader('baidu');
    final cookies = _credentialCookies(credential);
    final bduss = cookies['BDUSS'] ?? '';
    if (bduss.isEmpty || (cookies['STOKEN'] ?? '').isEmpty) {
      throw const FormatException('百度网盘登录会话不完整，请在网盘面板重新登录');
    }
    Future<void> checkAccount() async {
      if (await credentialReader('baidu') != credential) {
        throw const FormatException('百度网盘账号已切换，请重新点击播放');
      }
    }

    final info = await _json(
        Uri.https('mbd.baidu.com', '/userx/v1/info/get', {
          'appname': 'baiduboxapp',
          'fields': '["bg_image","member","uid","avatar","avatar_member"]',
          'client': '',
          'clientfrom': '',
          'lang': 'zh-cn',
          'tpl': '',
          'ttt': '',
        }),
        provider: 'baidu',
        budget: share.budget,
        cookies: cookies,
        userAgent: 'netdisk;P2SP;2.2.91.136;android-android');
    await checkAccount();
    _checkBaidu(info);
    final uid = _string(_map(_map(info['data'])['fields'])['uid']);
    if (uid.isEmpty) throw const FormatException('百度登录会话已失效，请重新登录');
    final time = '${_clock().millisecondsSinceEpoch}';
    const device = '73CED981D0F186D12BC18CAE1684FFD5|VSRCQTF6W';
    final rand = sha1
        .convert(utf8.encode(
          '${sha1.convert(utf8.encode(bduss))}${uid}ebrcUYiuxaZv2XGu7KIYKxUrqfnOfpDF'
          '$time${device}11.30.2ae5821440fab5e1a61a025f014bd8972',
        ))
        .toString();
    if ((file.session['shareId'] ?? '').isEmpty ||
        (file.session['uk'] ?? '').isEmpty) {
      throw const FormatException('百度分享缺少原始文件归属信息');
    }
    final result = await _json(
        Uri.https('pan.baidu.com', '/share/list', {
          'shareid': file.session['shareId']!,
          'uk': file.session['uk']!,
          'fid': file.id,
          'sekey': file.session['sekey'] ?? '',
          'origin': 'dlna',
          'devuid': device,
          'clienttype': '1',
          'channel': 'android_12_zhao_bd-netdisk_1024266h',
          'version': '11.30.2',
          'time': time,
          'rand': rand,
        }),
        provider: 'baidu',
        budget: share.budget,
        userAgent: _baiduMediaUa,
        cookies: cookies);
    await checkAccount();
    _checkBaidu(result);
    final list = result['list'];
    if (list is! List || list.isEmpty) {
      throw const FormatException('百度未返回该原始文件的播放地址');
    }
    final rows = list.whereType<Map>();
    final row =
        rows.where((row) => _string(row['fs_id']) == file.id).firstOrNull ??
            (list.length == 1 && _string(_map(list.first)['fs_id']).isEmpty
                ? _map(list.first)
                : const {});
    return _mediaUrl(row['dlink'], '百度未返回该原始文件的播放地址');
  }

  static const _ucQuery = {
    'pr': 'UCBrowser',
    'fr': 'pc',
    'uc_param_str': '',
    '__dt': '',
    '__t': '',
  };

  Future<Map> _json(Uri uri,
      {required String provider,
      required _ReadBudget budget,
      Map<String, dynamic>? body,
      Map<String, String>? form,
      Map<String, String>? cookies,
      String? referer,
      String? userAgent}) async {
    final response = await _request(uri,
        provider: provider,
        budget: budget,
        body: body,
        form: form,
        cookies: cookies,
        referer: referer,
        userAgent: userAgent);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FormatException(
          '${provider == 'uc' ? 'UC' : '百度'}网盘请求失败（${response.statusCode}）');
    }
    dynamic result;
    try {
      result = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      throw const FormatException('网盘服务没有返回有效数据');
    }
    if (result is! Map) throw const FormatException('网盘服务返回格式无效');
    return result;
  }

  Future<http.Response> _request(Uri uri,
      {required String provider,
      required _ReadBudget budget,
      Map<String, dynamic>? body,
      Map<String, String>? form,
      Map<String, String>? cookies,
      String? referer,
      String? userAgent,
      bool allowShareRedirect = false}) async {
    _checkCancelled();
    final timeout = budget.nextRequest();
    final allowed = provider == 'uc'
        ? const ['pc-api.uc.cn']
        : const ['pan.baidu.com', 'mbd.baidu.com'];
    if (uri.scheme != 'https' ||
        !allowed.contains(uri.host) ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 443)) {
      throw const FormatException('网盘请求地址不受支持');
    }
    final request =
        http.Request(body == null && form == null ? 'GET' : 'POST', uri)
          ..followRedirects = false
          ..headers.addAll({
            'User-Agent': userAgent ?? (provider == 'uc' ? _ucUa : _baiduUa),
            'Referer': referer ??
                (provider == 'uc'
                    ? 'https://drive.uc.cn/'
                    : 'https://pan.baidu.com/'),
            'Accept': 'application/json',
            if (provider == 'uc' && userAgent == _ucMediaUa)
              'Sec-Ch-Ua':
                  '"Not=A?Brand";v="99", "Chromium";v="100", "Google Chrome";v="100"',
            if (cookies != null && cookies.isNotEmpty)
              'Cookie': cookies.entries
                  .map((item) => '${item.key}=${item.value}')
                  .join('; '),
          });
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    } else if (form != null) {
      request.bodyFields = form;
    }
    late http.StreamedResponse streamed;
    try {
      streamed = await _http.send(request).timeout(timeout);
    } catch (_) {
      // ClientException can contain request URLs with temporary share tokens.
      throw const FormatException('网盘连接失败或超时，请稍后重试');
    }
    final chunks = <int>[];
    try {
      await for (final part in streamed.stream.timeout(timeout)) {
        budget.checkTime();
        if (chunks.length + part.length > _maxResponseBytes) {
          throw const FormatException('网盘响应内容过大');
        }
        chunks.addAll(part);
      }
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('网盘数据接收失败或超时，请稍后重试');
    }
    final response = http.Response.bytes(chunks, streamed.statusCode,
        headers: streamed.headers, request: request);
    // Only the share passcode cookie is needed for listing; account cookies are
    // intentionally never replaced by a late share response.
    if (cookies != null && uri.host == 'pan.baidu.com') {
      final value = RegExp(r'(?:^|,\s*)BDCLND=([^;,\s]+)')
          .firstMatch(response.headers['set-cookie'] ?? '')
          ?.group(1);
      if (value != null) cookies['BDCLND'] = value;
    }
    if (cookies != null &&
        uri.host == 'pc-api.uc.cn' &&
        uri.path == '/1/clouddrive/file/download' &&
        uri.queryParameters['entry'] == 'ft') {
      final value = RegExp(r'(?:^|,\s*)__pugs=([^;,\s]+)')
          .firstMatch(response.headers['set-cookie'] ?? '')
          ?.group(1);
      if (value != null && !RegExp(r'[\r\n\x00]').hasMatch(value)) {
        cookies['__pugs'] = value;
      }
    }
    if (cookies != null &&
        uri.host == 'pc-api.uc.cn' &&
        (cookies.containsKey('__pus') || cookies.containsKey('__puus'))) {
      for (final name in const ['__pus', '__puus']) {
        final value = RegExp('(?:^|,\\s*)$name=([^;,\\s]+)')
            .firstMatch(response.headers['set-cookie'] ?? '')
            ?.group(1);
        if (value != null) cookies[name] = value;
      }
    }
    if (response.statusCode >= 300 && response.statusCode < 400) {
      if (!allowShareRedirect) throw const FormatException('网盘会话需要重新验证');
      // Share page initialization may redirect to the provider's passcode page;
      // the verify API below supplies the passcode. Do not follow redirects.
      final location = uri.resolve(response.headers['location'] ?? '');
      if (location.scheme != 'https' || location.host != 'pan.baidu.com') {
        throw const FormatException('百度分享返回了异常跳转');
      }
    }
    return response;
  }

  static void _checkUc(Map result) {
    if ((result.containsKey('code') && _integer(result['code']) != 0) ||
        (result.containsKey('status') && _integer(result['status']) != 200)) {
      throw const FormatException('UC 分享访问失败或已失效，请检查提取码和分享状态');
    }
  }

  static void _checkBaidu(Map result) {
    if (!result.containsKey('errno') || _integer(result['errno']) != 0) {
      throw const FormatException('百度分享访问失败或登录已失效，请检查提取码与登录状态');
    }
  }

  static Map<String, String> _credentialCookies(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) raw = _string(decoded['cookie']);
    } catch (_) {}
    final cookies = <String, String>{};
    for (final item in raw.split(';')) {
      final index = item.indexOf('=');
      if (index <= 0) continue;
      final key = item.substring(0, index).trim().toUpperCase();
      final value = item.substring(index + 1).trim();
      if (const ['BDUSS', 'STOKEN', 'PTOKEN', 'BAIDUID'].contains(key) &&
          value.isNotEmpty &&
          !RegExp(r'[\r\n\x00]').hasMatch(value)) {
        cookies[key] = value;
      }
    }
    return cookies;
  }

  static Map<String, String> _ucCredentialCookies(String raw) {
    final result = <String, String>{};
    for (final part in raw.split(';')) {
      final i = part.indexOf('=');
      if (i < 1) continue;
      final name = part.substring(0, i).trim();
      final value = part.substring(i + 1).trim();
      if (const ['__pus', '__puus'].contains(name) &&
          value.isNotEmpty &&
          !RegExp(r'[\x00-\x20\x7f;,]').hasMatch(value)) {
        result[name] = value;
      }
    }
    return result;
  }

  static String _mediaUrl(dynamic value, String error) {
    final raw = _string(value);
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        !const ['https', 'http'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        RegExp(r'\.(?:jpg|jpeg|png|webp|gif)(?:\?|$)', caseSensitive: false)
            .hasMatch(raw)) {
      throw FormatException(error);
    }
    return raw;
  }

  static bool _video(Map row, String name) =>
      _integer(row['category']) == 1 ||
      RegExp(r'\.(mp4|mkv|ts|m3u8|mov|avi|flv|wmv|webm|m4v)$',
              caseSensitive: false)
          .hasMatch(name);
  static Map _map(dynamic value) => value is Map ? value : const {};
  static String _string(dynamic value) => value?.toString() ?? '';
  static int _integer(dynamic value) =>
      value is num ? value.toInt() : int.tryParse(_string(value)) ?? -1;
  static int _size(dynamic value) {
    final size = _integer(value);
    return size > 0 ? size : 0;
  }
}

class _Share {
  _Share(this.provider, this.id, this.passcode, this.url);
  final String provider;
  final String id;
  final String passcode;
  final String url;
  final _ReadBudget budget = _ReadBudget();
  String get shortId => id.startsWith('1') ? id.substring(1) : id;

  static _Share? parse(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        !const ['http', 'https'].contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 80 && uri.port != 443)) {
      return null;
    }
    final provider = const ['drive.uc.cn', 'fast.uc.cn'].contains(uri.host)
        ? 'uc'
        : uri.host == 'pan.baidu.com'
            ? 'baidu'
            : '';
    final match = RegExp(r'^/s/([A-Za-z0-9_-]{4,80})/?$').firstMatch(uri.path);
    if (provider.isEmpty || match == null) return null;
    final passcode =
        uri.queryParameters['pwd'] ?? uri.queryParameters['passcode'] ?? '';
    return _Share(provider, match.group(1)!, passcode, uri.toString());
  }
}

class _ReadBudget {
  final Stopwatch _elapsed = Stopwatch()..start();
  var _requests = 0;

  void checkTime() {
    if (_elapsed.elapsedMilliseconds >= 90000) {
      throw const FormatException('网盘分享读取超时，请稍后重试或选择较小的分享');
    }
  }

  Duration nextRequest() {
    checkTime();
    if (++_requests > 120) {
      throw const FormatException('网盘分享目录过多，请选择更具体的分享');
    }
    final remaining = 90000 - _elapsed.elapsedMilliseconds;
    return Duration(milliseconds: remaining < 20000 ? remaining : 20000);
  }
}

class _CloudFile {
  _CloudFile(
      {required this.id,
      required this.parent,
      required this.name,
      required this.size,
      required this.path,
      required this.session});
  final String id;
  final String parent;
  final String name;
  final int size;
  final String path;
  final Map<String, String> session;
  CloudMediaLease? lease;
}
