import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'quark_account.dart';
import 'source_playback.dart';

/// Account-scoped drive access and original public share resolution.
/// Share resolution may save files but never deletes existing account files.
class QuarkDriveClient {
  QuarkDriveClient({
    required QuarkAccountProvider accounts,
    http.Client? httpClient,
    this.isCancelled,
  })  : _accounts = accounts,
        _http = httpClient ?? http.Client(),
        _ownsHttp = httpClient == null;

  final QuarkAccountProvider _accounts;
  final http.Client _http;
  final bool _ownsHttp;
  final bool Function()? isCancelled;
  static const _pageSize = 50;
  static const _timeout = Duration(seconds: 20);
  static const _maxResponseBytes = 4 * 1024 * 1024;
  static const _apiHost = 'drive-pc.quark.cn';
  static const _referer = 'https://pan.quark.cn/';
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 '
      'Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch';
  static final _identifier = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  void close() {
    if (_ownsHttp) _http.close();
  }

  Future<CmsListing> listOwned({String folder = '0', int page = 1}) async {
    if (page < 1 || page > 10000) throw const FormatException('夸克目录页码无效');
    final session = await _accounts.requireSession();
    final generation = _accounts.generation;
    final fid = folder.startsWith('mmquark:')
        ? _ownedReference(folder, session, kind: 'folder')
        : _fid(folder);
    final payload = await _request(
      session,
      generation,
      '/1/clouddrive/file/sort',
      query: {
        'pdir_fid': fid,
        '_page': '$page',
        '_size': '$_pageSize',
        '_fetch_total': '1',
        '_fetch_sub_dirs': '0',
        '_sort': 'file_type:asc,file_name:asc',
      },
    );
    final data = payload['data'];
    if (data is! Map || data['list'] is! List) {
      throw const QuarkDriveException('invalid_response', '夸克未返回有效目录');
    }
    final rows = data['list'] as List;
    final videos = <CmsVideo>[];
    for (final row in rows.whereType<Map>()) {
      final fileId = row['fid'];
      final title = row['file_name'];
      if (fileId is! String ||
          !_identifier.hasMatch(fileId) ||
          title is! String ||
          title.trim().isEmpty) continue;
      final directory = row['dir'] == true || _integer(row['file_type']) == 0;
      if (!directory && _integer(row['category']) != 1) continue;
      final id = Uri(
        scheme: 'mmquark',
        host: directory ? 'folder' : 'owned',
        queryParameters: {'account': session.accountId, 'fid': fileId},
      ).toString();
      videos.add(
        CmsVideo(
          id: id,
          title: title,
          poster: directory
              ? ''
              : _httpUrl(row['thumbnail'] ?? row['thumbnail_url']),
          remarks: directory ? '文件夹' : _fileSize(row['size']),
          tag: directory ? 'quark-folder' : 'quark-owned',
          lines: directory
              ? const []
              : [
                  CmsLine(
                    name: '夸克网盘',
                    episodes: [CmsEpisode(name: title, url: id)],
                  ),
                ],
        ),
      );
    }
    final metadata = payload['metadata'];
    final total = metadata is Map ? _integer(metadata['_total']) : null;
    final pageCount = total != null && total >= 0
        ? ((total + _pageSize - 1) ~/ _pageSize).clamp(1, 10000)
        : page + (rows.length >= _pageSize ? 1 : 0);
    await _accounts.assertCurrentSession(session, generation: generation);
    return CmsListing(page: page, pageCount: pageCount, videos: videos);
  }

  Future<CmsEpisode> resolve(CmsEpisode episode) async {
    // Reject share/folder/arbitrary HTTP IDs before issuing any playback API.
    final reference = Uri.tryParse(episode.url);
    if (reference?.scheme != 'mmquark' || reference?.host != 'owned') {
      throw const QuarkDriveException(
        'owned_file_required',
        '请选择当前夸克账号中已有的视频；分享文件需先保存到网盘',
      );
    }
    final session = await _accounts.requireSession();
    final generation = _accounts.generation;
    final fid = _ownedReference(episode.url, session, kind: 'owned');
    final variants = <Map<String, Object>>[];
    try {
      final download = await _request(
        session,
        generation,
        '/1/clouddrive/file/download',
        body: {
          'fids': [fid],
        },
      );
      final files = download['data'];
      if (files is List) {
        for (final file in files.whereType<Map>()) {
          if (file['fid'] != null && file['fid'] != fid) continue;
          final url = _mediaUrl(file['download_url']);
          if (url.isNotEmpty) variants.add({'name': '原画', 'url': url});
        }
      }
    } on QuarkDriveException catch (error) {
      if (error.code != 'unavailable') rethrow;
      // Original download may be unavailable while an actual transcode exists.
    }
    try {
      final play = await _request(
        session,
        generation,
        '/1/clouddrive/file/v2/play',
        body: {
          'fid': fid,
          'resolutions': 'normal,low,high,super,2k,4k',
          'supports': 'fmp4,m3u8',
        },
      );
      final data = play['data'];
      final choices = data is Map ? data['video_list'] : null;
      if (choices is List) {
        const rankMap = <String, int>{
          '4k': 6,
          '2k': 5,
          'super': 4,
          'high': 3,
          'low': 2,
          'normal': 1,
        };
        final rankedChoices = <({int rank, String name, String url})>[];
        for (final choice in choices.whereType<Map>()) {
          final info = choice['video_info'];
          if (info is! Map ||
              choice['available'] == false ||
              info['available'] == false) continue;
          final url = _mediaUrl(info['url']);
          if (url.isEmpty) continue;
          final resolution = '${choice['resolution'] ?? ''}'.toLowerCase();
          final height = _integer(info['height']);
          final name = const {
                'normal': '流畅',
                'low': '标清',
                'high': '高清',
                'super': '超清',
                '2k': '2K',
                '4k': '4K',
              }[resolution] ??
              (height != null && height > 0 ? '${height}p' : '转码');
          final rank = rankMap[resolution] ?? ((height ?? 0) ~/ 360);
          rankedChoices.add((rank: rank, name: name, url: url));
        }
        rankedChoices.sort((a, b) => b.rank.compareTo(a.rank));
        for (final item in rankedChoices) {
          variants.add({'name': item.name, 'url': item.url});
        }
      }
    } on QuarkDriveException catch (error) {
      if (error.code != 'unavailable') rethrow;
    }
    await _accounts.assertCurrentSession(session, generation: generation);
    if (variants.isEmpty) {
      throw const QuarkDriveException('unavailable', '夸克未返回可用的原画或转码地址');
    }
    // Account cookies belong only to the fixed API origin. Signed media URLs
    // and thumbnails may use a CDN; never hand its player the account cookie.
    final resolved = await SourcePlayback.decode(
      {
        'parse': 0,
        'url': variants,
        'header': {'User-Agent': _userAgent, 'Referer': _referer},
      },
      episode,
      localUrl: (_) async => throw const FormatException('夸克不返回本地代理地址'),
    );
    await _accounts.assertCurrentSession(session, generation: generation);
    return resolved;
  }

  /// Walks the original public share with pagination. Stable episode references
  /// contain file identity only; short-lived provider tokens never enter history.
  static Future<List<CmsEpisode>> listPublicShareEpisodes(
    String shareUrl, {
    http.Client? httpClient,
    bool Function()? isCancelled,
  }) async {
    final match = RegExp(
      r'^https?://pan\.quark\.cn/s/([A-Za-z0-9_-]{1,128})(?:[/?#\s]|$)',
      caseSensitive: false,
    ).firstMatch(shareUrl.trim());
    if (match == null) return const [];
    final pwdId = match.group(1)!;
    final passcode = RegExp(
          r'(?:pwd|passcode|code|提取码)[=:：\s]*([A-Za-z0-9]{4})',
          caseSensitive: false,
        ).firstMatch(shareUrl)?.group(1) ??
        '';
    final client = httpClient ?? http.Client();
    try {
      final token =
          await _shareToken(client, pwdId, passcode, isCancelled: isCancelled);
      final files =
          await _walkShare(client, pwdId, token, isCancelled: isCancelled);
      return [
        for (final entry in files)
          CmsEpisode(
            name: entry.folder.isEmpty
                ? '${entry.row['file_name']}'
                : '${entry.folder}/${entry.row['file_name']}',
            url: Uri(scheme: 'mmwogg', host: 'quark', queryParameters: {
              'v': '1',
              'pwd_id': pwdId,
              'fid': '${entry.row['fid']}',
              'pdir_fid': entry.parent,
              if (passcode.isNotEmpty) 'passcode': passcode,
            }).toString(),
          )
      ];
    } finally {
      if (httpClient == null) client.close();
    }
  }

  static Future<String> _shareToken(
      http.Client client, String share, String passcode,
      {bool Function()? isCancelled}) async {
    final payload = await _publicRequest(
        client, '/1/clouddrive/share/sharepage/token',
        body: {'pwd_id': share, 'passcode': passcode},
        isCancelled: isCancelled);
    final data = payload['data'];
    final token = data is Map ? data['stoken'] : null;
    if (token is! String || token.isEmpty || token.length > 16384) {
      throw const QuarkDriveException('invalid_share', '夸克分享已失效或需要提取码');
    }
    return token;
  }

  static Future<List<({String parent, String folder, Map row})>> _walkShare(
    http.Client client,
    String share,
    String token, {
    String root = '0',
    String? target,
    bool Function()? isCancelled,
  }) async {
    const pageSize = 200;
    final files = <({String parent, String folder, Map row})>[];
    final directories = <String>{};
    final fileIds = <String>{};
    var requests = 0;
    Future<bool> walk(String parent, String folder, int depth) async {
      if (directories.contains(parent)) return false;
      if (depth > 12 || directories.length >= 128) {
        throw const QuarkDriveException(
            'share_limit_exceeded', '夸克分享目录过大，请打开较小的分享目录');
      }
      directories.add(parent);
      final children = <Map>[];
      var fetched = 0;
      final pageFingerprints = <String>{};
      for (var page = 1;; page++) {
        if (page > 100 || ++requests > 256) {
          throw const QuarkDriveException(
              'share_limit_exceeded', '夸克分享目录超过读取限制，请打开较小的分享目录');
        }
        final payload = await _publicRequest(
            client, '/1/clouddrive/share/sharepage/detail',
            isCancelled: isCancelled,
            query: {
              'pwd_id': share,
              'stoken': token,
              'pdir_fid': parent,
              'force': '0',
              '_page': '$page',
              '_size': '$pageSize',
              '_fetch_banner': '0',
              '_fetch_share': '0',
              '_fetch_total': '1',
              '_sort': 'file_type:asc,file_name:asc',
            });
        final data = payload['data'];
        if (data is! Map || data['list'] is! List) {
          throw const QuarkDriveException('invalid_response', '夸克未返回有效分享目录');
        }
        final rows = data['list'] as List;
        final metadata = payload['metadata'];
        final total =
            _integer(metadata is Map ? metadata['_total'] : data['total']);
        if (rows.isNotEmpty &&
            !pageFingerprints.add(jsonEncode([
              for (final row in rows.whereType<Map>()) row['fid'],
            ]))) {
          throw const QuarkDriveException(
              'incomplete_share', '夸克分享分页返回重复内容，请稍后重试');
        }
        fetched += rows.length;
        for (final row in rows) {
          if (row is! Map ||
              row['fid'] is! String ||
              !_identifier.hasMatch(row['fid']) ||
              row['file_name'] is! String) {
            throw const QuarkDriveException('invalid_response', '夸克分享目录数据无效');
          }
          if (row['dir'] == true || _integer(row['file_type']) == 0) {
            children.add(row);
          } else if (_integer(row['category']) == 1 ||
              RegExp(r'\.(?:mp4|mkv|ts|m3u8|mov|avi|flv|wmv|webm)$',
                      caseSensitive: false)
                  .hasMatch(row['file_name'])) {
            if (target != null && row['fid'] != target) continue;
            if (fileIds.add(row['fid'])) {
              if (files.length >= 5000) {
                throw const QuarkDriveException(
                    'share_limit_exceeded', '夸克分享视频超过读取限制，请打开较小的分享目录');
              }
              files.add((parent: parent, folder: folder, row: row));
            }
            if (target != null) return true;
          }
        }
        if (total != null && total >= 0) {
          if (fetched >= total) break;
          if (rows.isEmpty) {
            throw const QuarkDriveException(
                'incomplete_share', '夸克分享目录未读取完整，请稍后重试');
          }
        } else if (rows.length < pageSize) {
          break;
        }
      }
      for (final child in children) {
        final name = '${child['file_name']}';
        if (await walk(
            child['fid'], folder.isEmpty ? name : '$folder/$name', depth + 1)) {
          return true;
        }
      }
      return false;
    }

    await walk(root, '', 0);
    return files;
  }

  static Future<Map<String, dynamic>> _publicRequest(
    http.Client client,
    String path, {
    Map<String, String> query = const {},
    Map<String, Object>? body,
    bool Function()? isCancelled,
  }) async {
    _checkCancelled(isCancelled);
    final request = http.Request(
        body == null ? 'GET' : 'POST',
        Uri.https(_apiHost, path, {
          'pr': 'ucpro',
          'fr': 'pc',
          'uc_param_str': '',
          ...query,
        }))
      ..followRedirects = false
      ..maxRedirects = 0
      ..headers.addAll({
        'User-Agent': _userAgent,
        'Referer': _referer,
        'Content-Type': 'application/json',
        'Accept': 'application/json'
      });
    if (body != null) request.body = jsonEncode(body);
    try {
      final response = await client.send(request).timeout(_timeout);
      if (isCancelled?.call() == true) {
        await response.stream.listen((_) {}).cancel();
        _checkCancelled(isCancelled);
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.stream.listen((_) {}).cancel();
        throw const QuarkDriveException('unavailable', '夸克分享暂不可用，请检查分享状态');
      }
      final bytes = <int>[];
      await for (final part in response.stream.timeout(_timeout)) {
        _checkCancelled(isCancelled);
        if (bytes.length + part.length > _maxResponseBytes) {
          throw const QuarkDriveException('invalid_response', '夸克响应超过大小限制');
        }
        bytes.addAll(part);
      }
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map<String, dynamic> ||
          _integer(value['code']) != 0 ||
          (_integer(value['status']) != null &&
              _integer(value['status']) != 200)) {
        throw const QuarkDriveException('unavailable', '夸克分享已失效或需要提取码');
      }
      return value;
    } on TimeoutException {
      throw const QuarkDriveException('unavailable', '夸克分享读取超时，请稍后重试');
    } on http.ClientException {
      throw const QuarkDriveException('unavailable', '无法连接夸克分享');
    } on FormatException {
      throw const QuarkDriveException('invalid_response', '夸克分享接口返回格式无效');
    }
  }

  /// Refreshes tokens from the original share, then saves only the selected
  /// video. Never removes existing account files, and never stores share tokens.
  Future<CmsEpisode> resolveWoggShare(CmsEpisode episode) async {
    final uri = Uri.tryParse(episode.url);
    const allowed = {
      'v',
      'pwd_id',
      'fid',
      'pdir_fid',
      'passcode',
      'stoken',
      'fid_token'
    };
    if (uri == null ||
        uri.scheme != 'mmwogg' ||
        uri.host != 'quark' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.path.isNotEmpty ||
        uri.hasFragment ||
        uri.queryParametersAll.entries
            .any((e) => !allowed.contains(e.key) || e.value.length != 1)) {
      throw const QuarkDriveException('invalid_share', '夸克分享播放标识无效');
    }
    final pwdId = uri.queryParameters['pwd_id'] ?? '';
    final shareFid = uri.queryParameters['fid'] ?? '';
    final parent = uri.queryParameters['pdir_fid'];
    final passcode = uri.queryParameters['passcode'] ?? '';
    if (!_identifier.hasMatch(pwdId) ||
        !_identifier.hasMatch(shareFid) ||
        (parent != null && !_identifier.hasMatch(parent)) ||
        (passcode.isNotEmpty &&
            !RegExp(r'^[A-Za-z0-9]{4}$').hasMatch(passcode)) ||
        (uri.queryParameters['v'] != null && uri.queryParameters['v'] != '1')) {
      throw const QuarkDriveException('invalid_share', '夸克分享参数不完整');
    }
    final session = await _accounts.requireSession();
    final generation = _accounts.generation;
    _checkCancelled(isCancelled);
    final stoken =
        await _shareToken(_http, pwdId, passcode, isCancelled: isCancelled);
    final files = await _walkShare(_http, pwdId, stoken,
        root: parent ?? '0', target: shareFid, isCancelled: isCancelled);
    await _accounts.assertCurrentSession(session, generation: generation);
    if (files.isEmpty) {
      throw const QuarkDriveException('unavailable', '原夸克分享中已找不到此视频');
    }
    final shared = files.first;
    final shareFidToken = shared.row['share_fid_token'];
    if (shareFidToken is! String ||
        shareFidToken.isEmpty ||
        shareFidToken.length > 16384) {
      throw const QuarkDriveException('invalid_response', '夸克未返回此分享文件的有效凭据');
    }

    String tempDirFid = '';
    for (var page = 1; page <= 100; page++) {
      final rootList = await _request(
          session, generation, '/1/clouddrive/file/sort',
          query: {
            'pdir_fid': '0',
            '_page': '$page',
            '_size': '100',
            '_fetch_total': '1',
            '_fetch_sub_dirs': '0',
            '_sort': 'file_type:asc,updated_at:desc',
          });
      final data = rootList['data'];
      final rows = data is Map ? data['list'] : null;
      if (rows is! List) {
        throw const QuarkDriveException('invalid_response', '夸克未返回有效账户目录');
      }
      for (final row in rows.whereType<Map>()) {
        if ((row['dir'] == true || _integer(row['file_type']) == 0) &&
            row['file_name'] == '0000temp') {
          tempDirFid = _fid('${row['fid']}');
          break;
        }
      }
      if (tempDirFid.isNotEmpty || rows.length < 100) break;
      if (page == 100) {
        throw const QuarkDriveException(
            'share_limit_exceeded', '夸克根目录过大，无法确认转存目录');
      }
    }
    if (tempDirFid.isEmpty) {
      final created =
          await _request(session, generation, '/1/clouddrive/file', body: {
        'pdir_fid': '0',
        'file_name': '0000temp',
        'dir_path': '',
        'dir_init_lock': false,
      });
      final data = created['data'];
      tempDirFid = _fid(data is Map ? '${data['fid'] ?? ''}' : '');
    }
    final saved = await _request(
        session, generation, '/1/clouddrive/share/sharepage/save',
        body: {
          'fid_list': [shareFid],
          'fid_token_list': [shareFidToken],
          'to_pdir_fid': tempDirFid,
          'pwd_id': pwdId,
          'stoken': stoken,
          'pdir_fid': shared.parent,
          'scene': 'link',
        });
    String savedFid(Object? data) {
      if (data is! Map) return '';
      final direct = data['save_as'];
      final fids = direct is Map ? direct['save_as_top_fids'] : null;
      if (fids is List &&
          fids.isNotEmpty &&
          _identifier.hasMatch('${fids.first}')) {
        return '${fids.first}';
      }
      final task = data['task_resp'];
      if (task is Map) return savedFid(task['data']);
      return '';
    }

    var owned = savedFid(saved['data']);
    final data = saved['data'];
    final taskId = data is Map ? '${data['task_id'] ?? ''}' : '';
    if (owned.isEmpty && taskId.isNotEmpty) {
      for (var i = 0; i < 10; i++) {
        final task = await _request(session, generation, '/1/clouddrive/task',
            query: {'task_id': taskId, 'retry_index': '$i'});
        owned = savedFid(task['data']);
        if (owned.isNotEmpty) break;
        final taskData = task['data'];
        final status = taskData is Map ? _integer(taskData['status']) : null;
        if (status != 0 && status != 1) break;
        if (i < 9) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
      }
    }
    if (owned.isEmpty) {
      throw const QuarkDriveException('unavailable', '夸克分享转存尚未完成，请稍后到网盘查看');
    }
    await _accounts.assertCurrentSession(session, generation: generation);
    final resolved = await resolve(CmsEpisode(
        name: episode.name,
        url: Uri(
          scheme: 'mmquark',
          host: 'owned',
          queryParameters: {'account': session.accountId, 'fid': owned},
        ).toString()));
    await _accounts.assertCurrentSession(session, generation: generation);
    return resolved;
  }

  Future<Map<String, dynamic>> _request(
    QuarkAccountSession session,
    int generation,
    String path, {
    Map<String, String> query = const {},
    Map<String, Object>? body,
  }) async {
    _checkCancelled(isCancelled);
    await _accounts.assertCurrentSession(session, generation: generation);
    _checkCancelled(isCancelled);
    final uri = Uri.https(_apiHost, path, {
      'pr': 'ucpro',
      'fr': 'pc',
      'uc_param_str': '',
      ...query,
    });
    final request = http.Request(body == null ? 'GET' : 'POST', uri)
      ..followRedirects = false
      ..maxRedirects = 0
      ..headers.addAll({
        'Cookie': session.cookie,
        'User-Agent': _userAgent,
        'Referer': _referer,
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      });
    if (body != null) request.body = jsonEncode(body);
    try {
      final response = await _http.send(request).timeout(_timeout);
      try {
        _checkCancelled(isCancelled);
        await _accounts.assertCurrentSession(session, generation: generation);
      } catch (_) {
        await response.stream.listen((_) {}).cancel();
        rethrow;
      }
      if (response.statusCode >= 300 && response.statusCode < 400) {
        await response.stream.listen((_) {}).cancel();
        throw const QuarkDriveException(
          'redirect_refused',
          '夸克接口发生重定向，请重新验证账号',
        );
      }
      if (response.statusCode == 401) {
        await response.stream.listen((_) {}).cancel();
        _accounts.invalidate();
        throw const QuarkDriveException(
          'authentication_required',
          '夸克登录已失效，请重新登录',
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.stream.listen((_) {}).cancel();
        throw const QuarkDriveException('unavailable', '夸克暂时无法提供此文件');
      }
      final bytes = <int>[];
      await for (final part in response.stream.timeout(_timeout)) {
        _checkCancelled(isCancelled);
        if (bytes.length + part.length > _maxResponseBytes) {
          throw const QuarkDriveException('invalid_response', '夸克响应超过大小限制');
        }
        bytes.addAll(part);
      }
      await _accounts.assertCurrentSession(session, generation: generation);
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map<String, dynamic>) {
        throw const QuarkDriveException('invalid_response', '夸克接口返回格式无效');
      }
      final status = _integer(value['status']), code = _integer(value['code']);
      if (status == 401) {
        _accounts.invalidate();
        throw const QuarkDriveException(
          'authentication_required',
          '夸克登录已失效，请重新登录',
        );
      }
      if (code != 0 || (status != null && status != 200)) {
        throw const QuarkDriveException('unavailable', '夸克暂时无法提供此文件');
      }
      return value;
    } on TimeoutException {
      throw const QuarkDriveException('unavailable', '夸克请求超时，请稍后重试');
    } on http.ClientException {
      throw const QuarkDriveException('unavailable', '无法连接夸克网盘');
    } on FormatException {
      throw const QuarkDriveException('invalid_response', '夸克接口返回格式无效');
    }
  }

  static void _checkCancelled(bool Function()? check) {
    if (check?.call() == true) {
      throw const QuarkDriveException('cancelled', '夸克操作已取消');
    }
  }

  static String _ownedReference(
    String raw,
    QuarkAccountSession session, {
    required String kind,
  }) {
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme != 'mmquark' ||
        uri.host != kind ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.path.isNotEmpty ||
        uri.hasFragment ||
        uri.queryParametersAll.length != 2 ||
        uri.queryParametersAll['account']?.length != 1 ||
        uri.queryParametersAll['fid']?.length != 1) {
      throw const FormatException('夸克文件标识无效');
    }
    if (uri.queryParameters['account'] != session.accountId) {
      throw const QuarkDriveException(
        'account_mismatch',
        '夸克账号已切换，请重新打开当前账号的文件',
      );
    }
    return _fid(uri.queryParameters['fid'] ?? '');
  }

  static String _fid(String value) {
    if (!_identifier.hasMatch(value))
      throw const FormatException('夸克目录或文件标识无效');
    return value;
  }

  static int? _integer(Object? value) =>
      value is int ? value : int.tryParse('$value');
  static String _httpUrl(Object? value) {
    if (value is! String) return '';
    final uri = Uri.tryParse(value.trim());
    return uri != null &&
            const {'https', 'http'}.contains(uri.scheme) &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty
        ? uri.toString()
        : '';
  }

  static String _mediaUrl(Object? value) {
    final url = _httpUrl(value);
    if (url.isEmpty) return '';
    final path = Uri.parse(url).path.toLowerCase();
    return RegExp(r'\.(?:webp|png|jpe?g|gif|svg|html?)$').hasMatch(path)
        ? ''
        : url;
  }

  static String _fileSize(Object? value) {
    final size = _integer(value);
    if (size == null || size < 0) return '';
    if (size >= 1024 * 1024 * 1024)
      return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class QuarkDriveException implements Exception {
  const QuarkDriveException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}
