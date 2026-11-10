import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'models.dart';

/// Native Dart implementation of the imported Ali share protocol. No Android
/// bridge or third-party token service is used. Listing is read-only; playback
/// copies the selected file into a dedicated folder and never deletes files.
class AliShareClient {
  AliShareClient({
    http.Client? client,
    required Future<String> Function(String provider) credentialReader,
    Future<void> Function(String provider, String value)? credentialWriter,
    bool Function()? isCancelled,
  })  : _http = client ?? http.Client(),
        _ownsClient = client == null,
        _readCredential = credentialReader,
        _writeCredential = credentialWriter,
        _isCancelled = isCancelled ?? (() => false);

  final http.Client _http;
  final bool _ownsClient;
  final Future<String> Function(String) _readCredential;
  final Future<void> Function(String, String)? _writeCredential;
  final bool Function() _isCancelled;
  _AliSession? _session;
  String _sessionCredential = '';
  final Map<String, Future<_AliSession>> _refreshes = {};
  final Map<String, Future<String>> _folders = {};
  final Map<String, Future<String>> _saved = {};
  static const _api = 'https://api.aliyundrive.com';
  static const _folderName = 'MarcoMovie分享播放';
  static const _timeout = Duration(seconds: 25);
  static const _maxBytes = 4 * 1024 * 1024;
  static const _mediaHeaders = {
    'Referer': 'https://www.aliyundrive.com/',
    'User-Agent': 'Mozilla/5.0',
  };
  static final _identifier = RegExp(r'^[A-Za-z0-9_-]{1,160}$');

  void close() {
    if (_ownsClient) _http.close();
  }

  static bool supportsShare(String value) => _share(value) != null;
  static bool supportsEpisode(String value) {
    final uri = Uri.tryParse(value);
    return uri?.scheme == 'mmcloud' && uri?.host == 'ali';
  }

  Future<List<CmsEpisode>> listShare(String shareUrl) async {
    final share = _share(shareUrl);
    if (share == null) throw const AliShareException('阿里分享地址无效');
    final token = await _shareToken(share);
    final episodes = <CmsEpisode>[];
    final visited = <String>{};
    var requests = 0;
    Future<void> walk(String folder, String prefix, int depth) async {
      if (depth > 20 || visited.length >= 500) {
        throw const AliShareException('阿里分享目录过多，请打开较小的分享目录');
      }
      if (!visited.add(folder)) return;
      await for (final rows in _pages(
        {'share_id': share.id, 'parent_file_id': folder},
        headers: {'x-share-token': token},
      )) {
        if (++requests > 500) {
          throw const AliShareException('阿里分享目录过多，请打开较小的分享目录');
        }
        for (final row in rows) {
          final fid = _id(row['file_id']);
          final name = '${row['name'] ?? ''}'.trim();
          if (fid.isEmpty || name.isEmpty) continue;
          final fullName = prefix.isEmpty ? name : '$prefix/$name';
          if (row['type'] == 'folder') {
            await walk(fid, fullName, depth + 1);
          } else if (row['category'] == 'video' ||
              RegExp(r'\.(mp4|mkv|m4v|mov|ts|m2ts|avi|webm|flv)$',
                      caseSensitive: false)
                  .hasMatch(name)) {
            episodes.add(CmsEpisode(
              name: fullName,
              url: Uri(scheme: 'mmcloud', host: 'ali', queryParameters: {
                'share': shareUrl,
                'fid': fid,
                'name': fullName,
              }).toString(),
            ));
            if (episodes.length > 10000) {
              throw const AliShareException('阿里分享视频过多，请打开较小的分享目录');
            }
          }
        }
      }
    }

    await walk(share.folder, '', 0);
    return episodes;
  }

  Future<CmsEpisode> resolve(CmsEpisode episode) async {
    _checkActive();
    final uri = Uri.tryParse(episode.url);
    if (!supportsEpisode(episode.url) ||
        uri == null ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort) {
      throw const AliShareException('阿里播放引用无效');
    }
    final share = _share(uri.queryParameters['share'] ?? '');
    final fid = _id(uri.queryParameters['fid']);
    if (share == null || fid.isEmpty) throw const AliShareException('阿里播放引用无效');
    final session = await _requireSession();
    final shareToken = await _shareToken(share);
    final savedKey = '${session.account}:${session.drive}:${share.id}:$fid';
    var saved = _saved[savedKey];
    if (saved == null) {
      saved = _save(session, share, shareToken, fid);
      _saved[savedKey] = saved;
    }
    late final String ownId;
    try {
      ownId = await saved;
    } catch (_) {
      _saved.remove(savedKey);
      rethrow;
    }
    final variants = <CmsEpisode>[];
    AliShareException? mediaError;
    // These endpoints and fields match the original plugin. The original URL
    // receives no account token; CDN requests need only the public media headers.
    try {
      final data = await _post(
        'https://bj29.api.aliyunpds.com/v2/file/get_download_url',
        {'drive_id': session.drive, 'file_id': ownId, 'expire_sec': 14400},
        headers: session.headers,
      );
      final url = _mediaUrl(data['url']);
      if (url.isNotEmpty) {
        variants.add(CmsEpisode(name: '原画', url: url, headers: _mediaHeaders));
      }
    } on AliShareException catch (error) {
      mediaError = error;
    }
    try {
      final data = await _post(
          '$_api/v2/file/get_video_preview_play_info',
          {
            'drive_id': session.drive,
            'file_id': ownId,
            'category': 'live_transcoding',
            'get_subtitle_info': true,
            'url_expire_sec': 14400,
          },
          headers: session.headers);
      final info = data['video_preview_play_info'];
      final tasks = info is Map ? info['live_transcoding_task_list'] : null;
      if (tasks is List) {
        final available = tasks
            .whereType<Map>()
            .where((row) =>
                (row['status'] == null || row['status'] == 'finished') &&
                _mediaUrl(row['url']).isNotEmpty)
            .toList();
        available.sort((a, b) => _integer(b['template_height'])
            .compareTo(_integer(a['template_height'])));
        for (final task in available) {
          final url = _mediaUrl(task['url']);
          if (variants.any((item) => item.url == url)) continue;
          final height = _integer(task['template_height']);
          final template = '${task['template_id'] ?? ''}'
              .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
          variants.add(CmsEpisode(
              name: height > 0
                  ? '${height}P'
                  : (template.isEmpty ? '转码' : template),
              url: url,
              headers: _mediaHeaders));
        }
      }
    } on AliShareException catch (error) {
      mediaError ??= error;
    }
    if (variants.isEmpty) {
      throw mediaError ?? const AliShareException('阿里未返回可播放地址，请检查分享及账号权限');
    }
    await _assertSession(session);
    return CmsEpisode(
        name: episode.name,
        url: variants.first.url,
        headers: variants.first.headers,
        variants: variants);
  }

  Future<String> _save(
      _AliSession session, _AliShare share, String token, String fid) async {
    await _assertSession(session);
    // Read current source metadata instead of trusting a cached title or a URL
    // supplied by history. A matching name alone must never select another file.
    final source = await _post('$_api/v2/file/get', {
      'share_id': share.id,
      'file_id': fid,
    }, headers: {
      'x-share-token': token
    });
    if (source['type'] == 'folder' || _id(source['file_id']) != fid) {
      throw const AliShareException('阿里分享文件不存在或不是可播放文件');
    }
    final folderKey = '${session.account}:${session.drive}';
    final folderFuture = _folders.putIfAbsent(
        folderKey, () => _ensureFolder(session, 'root', _folderName));
    late final String playbackFolder;
    try {
      playbackFolder = await folderFuture;
    } catch (_) {
      _folders.remove(folderKey);
      rethrow;
    }
    final sourceKey =
        sha256.convert(utf8.encode('${share.id}\n$fid')).toString();
    final folder =
        await _ensureFolder(session, playbackFolder, 'ali_$sourceKey');
    final sourceHash = _contentHash(source['content_hash']);
    final sourceSize = _integer(source['size']);
    if (sourceHash.isNotEmpty && sourceSize > 0) {
      await for (final rows in _pages(
        {'drive_id': session.drive, 'parent_file_id': folder},
        headers: session.headers,
      )) {
        for (final row in rows) {
          if (row['type'] != 'folder' &&
              _contentHash(row['content_hash']) == sourceHash &&
              _integer(row['size']) == sourceSize &&
              _id(row['file_id']).isNotEmpty) {
            return _id(row['file_id']);
          }
        }
      }
    }
    await _assertSession(session);
    final data = await _post('$_api/adrive/v2/batch', {
      'requests': [
        {
          'body': {
            'file_id': fid,
            'share_id': share.id,
            'auto_rename': true,
            'to_parent_file_id': folder,
            'to_drive_id': session.drive
          },
          'headers': {'Content-Type': 'application/json'},
          'id': '0',
          'method': 'POST',
          'url': '/file/copy',
        }
      ],
      'resource': 'file',
    }, headers: {
      ...session.headers,
      'x-share-token': token
    });
    final responses = data['responses'];
    if (responses is List && responses.length == 1 && responses.first is Map) {
      final result = responses.first as Map;
      final body = result['body'];
      final status = _integer(result['status']);
      if (body is Map &&
          body['code'] == null &&
          (status == 0 || (status >= 200 && status < 300))) {
        final ownId = _id(body['file_id']);
        if (ownId.isNotEmpty) return ownId;
      }
    }
    throw const AliShareException('阿里分享转存失败，请检查剩余空间及分享权限');
  }

  Future<String> _ensureFolder(
      _AliSession session, String parent, String name) async {
    Future<String?> find() async {
      await for (final rows in _pages(
          {'drive_id': session.drive, 'parent_file_id': parent},
          headers: session.headers)) {
        for (final row in rows) {
          if (row['type'] == 'folder' &&
              row['name'] == name &&
              _id(row['file_id']).isNotEmpty) {
            return _id(row['file_id']);
          }
        }
      }
      return null;
    }

    final existing = await find();
    if (existing != null) return existing;
    try {
      await _assertSession(session);
      final created = await _post(
          '$_api/v2/file/create',
          {
            'drive_id': session.drive,
            'parent_file_id': parent,
            'name': name,
            'type': 'folder',
            'check_name_mode': 'refuse',
          },
          headers: session.headers);
      final id = _id(created['file_id']);
      if (id.isNotEmpty) return id;
    } on AliShareException {
      // Another playback may have created the folder. Reuse it without ever
      // deleting or replacing an existing user file with the same name.
      final raced = await find();
      if (raced != null) return raced;
      rethrow;
    }
    throw const AliShareException('阿里播放目录创建失败');
  }

  Stream<List<Map>> _pages(Map<String, dynamic> body,
      {Map<String, String> headers = const {}}) async* {
    var marker = '';
    final seen = <String>{};
    for (var page = 0; page < 100; page++) {
      final data = await _post(
          '$_api/adrive/v3/file/list',
          {
            ...body,
            'limit': 200,
            'order_by': 'name',
            'order_direction': 'ASC',
            if (marker.isNotEmpty) 'marker': marker,
          },
          headers: headers);
      final items = data['items'];
      if (items is! List) throw const AliShareException('阿里未返回有效文件列表');
      yield items.whereType<Map>().toList();
      marker = '${data['next_marker'] ?? ''}';
      if (marker.isEmpty) return;
      if (!seen.add(marker)) throw const AliShareException('阿里目录分页响应重复');
    }
    throw const AliShareException('阿里目录过大，请打开较小的目录');
  }

  Future<String> _shareToken(_AliShare share) async {
    final data = await _post('$_api/v2/share_link/get_share_token',
        {'share_id': share.id, 'share_pwd': share.password});
    final token = data['share_token'];
    if (token is! String ||
        token.isEmpty ||
        token.contains(RegExp(r'[\r\n]'))) {
      throw const AliShareException('阿里分享已失效或提取码不正确');
    }
    return token;
  }

  Future<_AliSession> _requireSession() async {
    final credential = (await _readCredential('ali')).trim();
    var refresh = credential;
    if (refresh.startsWith('ali_token=')) {
      refresh = refresh.substring(10).trim();
    }
    if (refresh.startsWith('{')) {
      try {
        refresh = '${(jsonDecode(refresh) as Map)['refresh_token'] ?? ''}';
      } catch (_) {
        refresh = '';
      }
    }
    if (refresh.isEmpty ||
        refresh.length > 8192 ||
        refresh.contains(RegExp(r'[\s;]')) ||
        refresh.contains('://')) {
      throw const AliShareException('请先在网盘配置中登录阿里云盘');
    }
    final current = _session;
    if (_sessionCredential == credential &&
        current != null &&
        current.expires
            .isAfter(DateTime.now().add(const Duration(minutes: 1)))) {
      return current;
    }
    final loading = _refreshes.putIfAbsent(
        credential, () => _refreshSession(credential, refresh));
    try {
      return await loading;
    } finally {
      if (identical(_refreshes[credential], loading)) {
        _refreshes.remove(credential);
      }
    }
  }

  Future<_AliSession> _refreshSession(String credential, String refresh) async {
    final data = await _post('https://auth.aliyundrive.com/v2/account/token',
        {'refresh_token': refresh, 'grant_type': 'refresh_token'});
    final access = data['access_token'];
    final account = _id(data['user_id']);
    var drive = _id(data['resource_drive_id']);
    if (drive.isEmpty || drive == 'NO_ID') {
      drive = _id(data['default_drive_id']);
    }
    if (drive.isEmpty) drive = _id(data['backup_drive_id']);
    if (access is! String ||
        access.isEmpty ||
        access.contains(RegExp(r'[\r\n]')) ||
        account.isEmpty ||
        drive.isEmpty) {
      throw const AliShareException('阿里登录已失效，请重新登录');
    }
    final session = _AliSession(
        access,
        account,
        drive,
        _id(data['device_id']),
        DateTime.now().add(Duration(
            seconds: _integer(data['expires_in']) > 0
                ? _integer(data['expires_in'])
                : 3600)),
        credential);
    final current = _session;
    if (current != null && current.account != session.account) {
      _saved.clear();
      _folders.clear();
    }
    var stored = credential;
    if ((await _readCredential('ali')).trim() != credential) {
      throw const AliShareException('阿里账号已切换，请重新播放');
    }
    final rotated = data['refresh_token'];
    if (_writeCredential != null &&
        rotated is String &&
        rotated.isNotEmpty &&
        rotated != refresh &&
        !rotated.contains(RegExp(r'[\s;]'))) {
      stored = 'ali_token=$rotated';
      // Do not overwrite a different account selected while refresh was in flight.
      await _writeCredential('ali', stored);
    }
    session.credential = stored;
    await _assertSession(session);
    _sessionCredential = stored;
    _session = session;
    return session;
  }

  Future<void> _assertSession(_AliSession session) async {
    _checkActive();
    if ((await _readCredential('ali')).trim() != session.credential) {
      throw const AliShareException('阿里账号已切换，请重新播放');
    }
    _checkActive();
  }

  void _checkActive() {
    if (_isCancelled()) throw const AliShareException('阿里播放已取消');
  }

  Future<Map<String, dynamic>> _post(String url, Map<String, dynamic> body,
      {Map<String, String> headers = const {}}) async {
    try {
      _checkActive();
      final request = http.Request('POST', Uri.parse(url))
        ..followRedirects = false
        ..headers.addAll({
          ..._mediaHeaders,
          'Content-Type': 'application/json',
          'X-Canary': 'client=Android,app=adrive,version=v4.1.4',
          ...headers
        })
        ..body = jsonEncode(body);
      final response = await _http.send(request).timeout(_timeout);
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(_timeout)) {
        if (bytes.length + chunk.length > _maxBytes) {
          throw const AliShareException('阿里响应过大');
        }
        bytes.addAll(chunk);
      }
      if (response.statusCode == 401) {
        throw const AliShareException('阿里登录已失效，请重新登录');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw const AliShareException('阿里请求失败，请检查账号或分享权限');
      }
      final data = jsonDecode(utf8.decode(bytes));
      if (data is! Map) throw const AliShareException('阿里返回了无效响应');
      if (data['code'] != null &&
          data['code'] != '' &&
          data['code'] != 0 &&
          data['code'] != '0') {
        throw const AliShareException('阿里请求未通过，请检查账号、分享或会员权限');
      }
      return Map<String, dynamic>.from(data);
    } on AliShareException {
      rethrow;
    } on TimeoutException {
      throw const AliShareException('阿里请求超时，请稍后重试');
    } catch (_) {
      throw const AliShareException('阿里请求失败，请检查网络后重试');
    }
  }

  static _AliShare? _share(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        ![
          'www.alipan.com',
          'alipan.com',
          'www.aliyundrive.com',
          'aliyundrive.com'
        ].contains(uri.host.toLowerCase())) {
      return null;
    }
    final parts = uri.pathSegments;
    if (parts.length < 2 || parts[0] != 's' || _id(parts[1]).isEmpty) {
      return null;
    }
    var folder = 'root';
    if (parts.length > 2) {
      if (parts.length != 4 || parts[2] != 'folder' || _id(parts[3]).isEmpty) {
        return null;
      }
      folder = parts[3];
    }
    final password =
        uri.queryParameters['pwd'] ?? uri.queryParameters['password'] ?? '';
    if (password.length > 64) return null;
    return _AliShare(parts[1], folder, password);
  }

  static String _id(Object? value) {
    final text = '${value ?? ''}';
    return _identifier.hasMatch(text) ? text : '';
  }

  static int _integer(Object? value) => int.tryParse('$value') ?? 0;
  static String _contentHash(Object? value) {
    final text = '${value ?? ''}'.toLowerCase();
    return RegExp(r'^(?:[0-9a-f]{40}|[0-9a-f]{64})$').hasMatch(text)
        ? text
        : '';
  }

  static String _mediaUrl(Object? value) {
    final text = value is String ? value.trim() : '';
    final uri = Uri.tryParse(text);
    return uri != null &&
            uri.scheme == 'https' &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty
        ? text
        : '';
  }
}

class AliShareException implements Exception {
  const AliShareException(this.message);
  final String message;
  @override
  String toString() => message;
}

class _AliShare {
  const _AliShare(this.id, this.folder, this.password);
  final String id;
  final String folder;
  final String password;
}

class _AliSession {
  _AliSession(this.access, this.account, this.drive, this.device, this.expires,
      this.credential);
  final String access;
  final String account;
  final String drive;
  final String device;
  final DateTime expires;
  String credential;
  Map<String, String> get headers => {
        'Authorization': 'Bearer $access',
        if (device.isNotEmpty) 'x-device-id': device
      };
}
