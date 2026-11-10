import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'quark_account.dart';
import 'source_playback.dart';

/// Read-only access to files already in the authenticated Quark account.
/// Share IDs/tokens never enter this client, and it has no save/delete methods.
class QuarkDriveClient {
  QuarkDriveClient({
    required QuarkAccountProvider accounts,
    http.Client? httpClient,
  }) : _accounts = accounts,
       _http = httpClient ?? http.Client(),
       _ownsHttp = httpClient == null;

  final QuarkAccountProvider _accounts;
  final http.Client _http;
  final bool _ownsHttp;
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
          title.trim().isEmpty)
        continue;
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
        final transcodes = <({int rank, Map<String, String> item})>[];
        for (final choice in choices.whereType<Map>()) {
          final info = choice['video_info'];
          if (info is! Map ||
              choice['available'] == false ||
              info['available'] == false)
            continue;
          final url = _mediaUrl(info['url']);
          if (url.isEmpty) continue;
          final resolution = '${choice['resolution'] ?? ''}';
          final height = _integer(info['height']);
          final name =
              const {
                'normal': '流畅',
                'low': '标清',
                'high': '高清',
                'super': '超清',
                '2k': '2K',
                '4k': '4K',
              }[resolution] ??
              (height != null && height > 0 ? '${height}p' : '转码');
          final rank =
              const {
                '4k': 6000,
                '2k': 5000,
                'super': 4000,
                'high': 3000,
                'low': 2000,
                'normal': 1000,
              }[resolution] ??
              (height ?? 0);
          transcodes.add((rank: rank, item: {'name': name, 'url': url}));
        }
        transcodes.sort((a, b) => b.rank.compareTo(a.rank));
        for (final entry in transcodes) {
          variants.add(entry.item);
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

  Future<Map<String, dynamic>> _request(
    QuarkAccountSession session,
    int generation,
    String path, {
    Map<String, String> query = const {},
    Map<String, Object>? body,
  }) async {
    await _accounts.assertCurrentSession(session, generation: generation);
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
