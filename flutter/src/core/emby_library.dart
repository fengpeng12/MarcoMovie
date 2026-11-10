import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';

class EmbyLibrary {
  final Uri base;
  final String user, token, device;
  const EmbyLibrary._(this.base, this.user, this.token, this.device);
  static const prefix = 'emby://account/';
  static String _nonce() {
    final rng = Random.secure();
    return List.generate(
      16,
      (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  static Uri _base(String address) {
    final u = Uri.parse(address.trim());
    if (!['http', 'https'].contains(u.scheme) ||
        u.host.isEmpty ||
        u.userInfo.isNotEmpty ||
        u.hasQuery ||
        u.hasFragment) {
      throw const FormatException('请输入含 HTTP 或 HTTPS 的 Emby 服务器根地址');
    }
    final path = u.path.replaceFirst(RegExp(r'/+$'), '');
    return u.replace(
      path: path.toLowerCase().endsWith('/emby') ? path : '$path/emby',
    );
  }

  static Future<SubscriptionEntry> login(
    String address,
    String username,
    String password, {
    required String group,
    required bool isPrivate,
  }) async {
    final base = _base(address);
    final prefs = await SharedPreferences.getInstance();
    final device = prefs.getString('emby.device') ?? _nonce();
    if (!await prefs.setString('emby.device', device))
      throw StateError('无法保存设备标识');
    final login = EmbyLibrary._(base, '', '', device);
    final json = await login._api(
      '/Users/AuthenticateByName',
      body: {'Username': username.trim(), 'Pw': password},
    );
    final user = json['User']?['Id'];
    final token = json['AccessToken'];
    if (user is! String || user.isEmpty || token is! String || token.isEmpty) {
      throw const FormatException('Emby 没有返回有效账户');
    }
    final key = sha256.convert(utf8.encode('$base\n$user')).toString();
    final name = 'Emby · ${username.trim()}';
    final api = '$prefix$key';
    if (!await prefs.setString(
      'emby.account.$key',
      jsonEncode({
        'base': base.toString(),
        'user': user,
        'token': token,
        'device': device,
      }),
    ))
      throw StateError('无法保存 Emby 登录状态');
    return SubscriptionEntry(
      id: 'emby_$key',
      name: name,
      group: group,
      isPrivate: isPrivate,
      format: 'Emby',
      siteCount: 1,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      rawContent: jsonEncode({
        'sites': [
          {'key': 'emby_$key', 'name': name, 'type': 1, 'api': api},
        ],
      }),
    );
  }

  static Future<EmbyLibrary> open(CmsSite site) async {
    final key = site.api.substring(prefix.length);
    final value = (await SharedPreferences.getInstance()).getString(
      'emby.account.$key',
    );
    if (value == null) throw StateError('请在本机重新登录 Emby');
    final s = jsonDecode(value);
    return EmbyLibrary._(_base(s['base']), s['user'], s['token'], s['device']);
  }

  static bool isImage(String raw) =>
      Uri.tryParse(raw)?.fragment.startsWith('mm-emby=') == true;

  static Future<Map<String, String>> imageHeaders(String raw) async {
    final uri = Uri.parse(raw);
    final account = uri.fragment.substring(8);
    final library = await open(
      CmsSite(key: account, name: 'Emby', type: 1, api: '$prefix$account'),
    );
    if (uri.origin != library.base.origin ||
        !uri.path.startsWith('${library.base.path}/Items/') ||
        !RegExp(r'/Items/[a-zA-Z0-9_-]+/Images/Primary$').hasMatch(uri.path)) {
      throw const FormatException('Emby 海报地址与账户不匹配');
    }
    return {'X-Emby-Token': library.token};
  }

  Uri _url(String path, [Map<String, String>? params]) =>
      base.replace(path: base.path + path, queryParameters: params);

  Future<Map<String, dynamic>> _api(
    String path, {
    Map<String, String>? params,
    Map? body,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    final deadline = Timer(
      const Duration(seconds: 15),
      () => client.close(force: true),
    );
    try {
      final r = await client.openUrl(
        body == null ? 'GET' : 'POST',
        _url(path, params),
      );
      r.followRedirects = false;
      r.headers.set(
        'Authorization',
        'Emby Client="Marco Movie", Device="${Platform.operatingSystem}", DeviceId="$device", Version="1"',
      );
      if (token.isNotEmpty) r.headers.set('X-Emby-Token', token);
      if (body != null) {
        r.headers.contentType = ContentType.json;
        r.write(jsonEncode(body));
      }
      final response = await r.close();
      if (response.statusCode == 401 || response.statusCode == 403)
        throw StateError('Emby 拒绝访问，请检查账号或重新登录');
      if (response.statusCode < 200 || response.statusCode >= 300)
        throw HttpException('Emby HTTP ${response.statusCode}');
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length > 4 * 1024 * 1024)
          throw const FormatException('Emby 响应过大');
        bytes.addAll(chunk);
      }
      return bytes.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } finally {
      deadline.cancel();
      client.close(force: true);
    }
  }

  CmsVideo _card(Map i, [List<CmsLine> lines = const []]) {
    final id = i['Id'] as String;
    final tags = i['ImageTags'];
    return CmsVideo(
      id: id,
      title: i['Name']?.toString() ?? '',
      year: i['ProductionYear']?.toString() ?? '',
      description: i['Overview']?.toString() ?? '',
      poster:
          _url('/Items/$id/Images/Primary', {
                if (tags is Map && tags['Primary'] is String)
                  'tag': tags['Primary'],
                'maxWidth': '500',
              })
              .replace(
                fragment:
                    'mm-emby=' +
                    sha256.convert(utf8.encode('$base\n$user')).toString(),
              )
              .toString(),
      lines: lines,
    );
  }

  Future<(List<CmsCategory>, CmsListing)> home() async {
    final views = await _api('/Users/$user/Views');
    final groups = (views['Items'] as List)
        .whereType<Map>()
        .map((v) => CmsCategory(id: v['Id'], name: v['Name']))
        .toList();
    return (groups, await list('', '', 1));
  }

  Future<CmsListing> list(String parent, String query, int page) async {
    const limit = 40;
    final j = await _api(
      '/Users/$user/Items',
      params: {
        'Recursive': 'true',
        'IncludeItemTypes': 'Movie,Series,Video',
        'Fields': 'Overview,ProductionYear',
        'Limit': '$limit',
        'StartIndex': '${(page - 1) * limit}',
        if (parent.isNotEmpty) 'ParentId': parent,
        if (query.isNotEmpty) 'SearchTerm': query,
      },
    );
    final cards = (j['Items'] as List)
        .whereType<Map>()
        .map((v) => _card(v))
        .toList();
    final total =
        j['TotalRecordCount'] as int? ?? (page - 1) * limit + cards.length;
    return CmsListing(
      page: page,
      pageCount: max(page, (total / limit).ceil()),
      videos: cards,
    );
  }

  Future<CmsVideo> detail(String id) async {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id))
      throw const FormatException('Emby 媒体编号无效');
    final item = await _api(
      '/Users/$user/Items/$id',
      params: {'Fields': 'Overview,MediaSources'},
    );
    final episodes = <CmsEpisode>[];
    void add(Map row) {
      final name = row['Name']?.toString() ?? '正片';
      final sources = row['MediaSources'];
      final sid = sources is List && sources.isNotEmpty
          ? sources.first['Id']
          : row['Id'];
      episodes.add(
        CmsEpisode(
          name: row['ParentIndexNumber'] == null
              ? name
              : 'S${row['ParentIndexNumber']}E${row['IndexNumber']} $name',
          url: Uri(
            scheme: 'mmemby',
            host: 'play',
            queryParameters: {'id': row['Id'], 'source': sid ?? row['Id']},
          ).toString(),
        ),
      );
    }

    if (item['Type'] == 'Series') {
      var start = 0;
      while (start < 10000) {
        final j = await _api(
          '/Shows/$id/Episodes',
          params: {
            'UserId': user,
            'Fields': 'MediaSources',
            'Limit': '200',
            'StartIndex': '$start',
          },
        );
        final rows = j['Items'] as List;
        rows.whereType<Map>().forEach(add);
        start += rows.length;
        if (rows.isEmpty || start >= (j['TotalRecordCount'] as int? ?? start))
          break;
      }
    } else {
      add(item);
    }
    return _card(item, [
      if (episodes.isNotEmpty) CmsLine(name: 'Emby', episodes: episodes),
    ]);
  }

  Future<CmsEpisode> resolve(CmsEpisode episode) async {
    final p = Uri.parse(episode.url).queryParameters;
    final id = p['id'] ?? '';
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id))
      throw const FormatException('Emby 剧集编号无效');
    final wanted = p['source'] ?? id;
    final info = await _api(
      '/Items/$id/PlaybackInfo',
      body: {
        'UserId': user,
        if (wanted != id) 'MediaSourceId': wanted,
        'IsPlayback': true,
        'AutoOpenLiveStream': false,
        'EnableDirectPlay': false,
        'EnableDirectStream': true,
        'EnableTranscoding': true,
        'MaxStreamingBitrate': 80000000,
        'DeviceProfile': {
          'Name': 'Marco Movie',
          'MaxStreamingBitrate': 80000000,
          'DirectPlayProfiles': [
            {
              'Type': 'Video',
              'Container': 'mp4,m4v,mkv,mov,ts',
              'VideoCodec': 'h264',
              'AudioCodec': 'aac,mp3',
            },
          ],
          'TranscodingProfiles': [
            {
              'Type': 'Video',
              'Container': 'ts',
              'Protocol': 'hls',
              'VideoCodec': 'h264',
              'AudioCodec': 'aac',
              'Context': 'Streaming',
              'MaxAudioChannels': '2',
              'MinSegments': 1,
            },
          ],
        },
      },
    );
    if ((info['ErrorCode']?.toString() ?? '').isNotEmpty) {
      throw StateError('Emby 无法为当前账号或设备提供播放方案');
    }
    final sources = (info['MediaSources'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    final matching = sources.where((s) => s['Id'] == wanted).toList();
    if (matching.isEmpty && wanted == id && sources.isNotEmpty)
      matching.add(sources.first);
    if (matching.isEmpty) throw StateError('Emby 未返回所选媒体版本');
    final source = matching.first;
    final sourceId = source['Id']?.toString() ?? '';
    if (sourceId.isEmpty) throw const FormatException('Emby 媒体版本缺失');
    if (source['RequiresOpening'] == true)
      throw StateError('当前 Emby 资源需要实时流打开协议');
    final session = info['PlaySessionId']?.toString() ?? '';
    if (session.isEmpty) throw const FormatException('Emby 播放会话缺失');
    final direct =
        source['SupportsDirectStream'] == true ||
        source['SupportsDirectPlay'] == true;
    if (!direct &&
        (source['SupportsTranscoding'] != true ||
            (source['TranscodingUrl']?.toString() ?? '').isEmpty)) {
      throw StateError('Emby 没有可用的直连或转码方案');
    }
    final parameters = {
      'MediaSourceId': sourceId,
      'PlaySessionId': session,
      'DeviceId': device,
    };
    Uri stream;
    if (direct) {
      stream = _url('/Videos/$id/stream', {...parameters, 'Static': 'true'});
    } else {
      final raw = source['TranscodingUrl'].toString();
      stream = Uri.parse('${base.toString()}/').resolve(raw);
      if (stream.origin != base.origin ||
          stream.userInfo.isNotEmpty ||
          !stream.path.startsWith('${base.path}/Videos/')) {
        throw const FormatException('Emby 转码地址与服务器不匹配');
      }
      final query = Map<String, String>.from(stream.queryParameters)
        ..removeWhere(
          (k, _) => ['api_key', 'x-emby-token'].contains(k.toLowerCase()),
        );
      stream = stream.replace(
        queryParameters: {...query, ...parameters},
        fragment: '',
      );
    }
    return CmsEpisode(
      name: episode.name,
      url: stream.toString(),
      headers: {'X-Emby-Token': token},
      playbackSession: {
        'ItemId': id,
        'MediaSourceId': sourceId,
        'PlaySessionId': session,
        'PlayMethod': direct ? 'DirectStream' : 'Transcode',
        'CanSeek': true,
      },
    );
  }

  EmbyPlaybackSession track(CmsEpisode episode) =>
      EmbyPlaybackSession._(this, episode.playbackSession);
}

/// At most one HTTP check-in in flight and one latest pending state per playback.
/// Reporting failures must not interrupt video; a subsequent update retries start.
class EmbyPlaybackSession {
  final EmbyLibrary _library;
  final Map<String, dynamic> _info;
  EmbyPlaybackSession._(this._library, Map<String, dynamic> info)
    : _info = Map.unmodifiable(info);
  bool _started = false, _stopped = false;
  int _lastSentMs = -10000, _positionMs = 0;
  bool _paused = false;
  Map<String, dynamic>? _pending;
  Future<void>? _work;
  final Stopwatch _clock = Stopwatch()..start();

  Future<void> update(
    int positionMs,
    bool paused, {
    String event = 'TimeUpdate',
    bool force = false,
  }) {
    if (_stopped || _info.isEmpty) return Future.value();
    _positionMs = max(0, positionMs);
    final changed = paused != _paused;
    _paused = paused;
    final now = _clock.elapsedMilliseconds;
    if (!force && !changed && now - _lastSentMs < 10000)
      return _work ?? Future.value();
    _lastSentMs = now;
    return _enqueue({
      ..._info,
      'PositionTicks': _positionMs * 10000,
      'IsPaused': paused,
      'EventName': changed ? (paused ? 'Pause' : 'Unpause') : event,
    });
  }

  Future<void> stop([int? positionMs]) {
    if (_stopped || _info.isEmpty) return _work ?? Future.value();
    _stopped = true;
    _positionMs = max(0, positionMs ?? _positionMs);
    return _enqueue({
      ..._info,
      'PositionTicks': _positionMs * 10000,
      'IsPaused': _paused,
      '_stop': true,
    });
  }

  Future<void> _enqueue(Map<String, dynamic> state) {
    _pending = state;
    return _work ??= _drain().whenComplete(() => _work = null);
  }

  Future<void> _drain() async {
    while (_pending != null) {
      final state = _pending!;
      _pending = null;
      final stopping = state.remove('_stop') == true;
      final path = stopping
          ? '/Sessions/Playing/Stopped'
          : (_started ? '/Sessions/Playing/Progress' : '/Sessions/Playing');
      try {
        await _library._api(path, body: state);
        if (!stopping) _started = true;
      } catch (_) {
        /* Optional server reporting cannot stop local playback. */
      }
    }
  }
}
