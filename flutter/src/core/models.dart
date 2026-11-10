/// Core domain models shared across macOS, iOS, iPadOS, Windows, and Android backup schemas.
library;

import 'csp_bridge.dart';

class CmsDepot {
  final String name;
  final String url;
  final String subscriptionId;
  const CmsDepot({
    required this.name,
    required this.url,
    this.subscriptionId = '',
  });
  Map<String, dynamic> toJson() => {
    'name': name,
    'url': url,
    'subscriptionId': subscriptionId,
  };
  factory CmsDepot.fromJson(Map<String, dynamic> json) {
    return CmsDepot(
      name: (json['name'] ?? '').toString().trim(),
      url: (json['url'] ?? '').toString().trim(),
      subscriptionId: (json['subscriptionId'] ?? '').toString(),
    );
  }
}

class SubscriptionEntry {
  final String id;
  final String name;
  final String url;
  final String group;
  final String format;
  final bool isPrivate;
  final bool enabled;
  final String rawContent;
  final int siteCount;
  final int liveCount;
  final int updatedAt;
  final String warehouseUrl;
  final String activeDepotName;
  final List<CmsDepot> depots;
  const SubscriptionEntry({
    required this.id,
    required this.name,
    this.url = '',
    this.group = '默认分组',
    this.format = 'JSON',
    this.isPrivate = false,
    this.enabled = true,
    this.rawContent = '',
    this.siteCount = 0,
    this.liveCount = 0,
    this.updatedAt = 0,
    this.warehouseUrl = '',
    this.activeDepotName = '',
    this.depots = const [],
  });
  SubscriptionEntry copyWith({
    String? id,
    String? name,
    String? url,
    String? group,
    String? format,
    bool? isPrivate,
    bool? enabled,
    String? rawContent,
    int? siteCount,
    int? liveCount,
    int? updatedAt,
    String? warehouseUrl,
    String? activeDepotName,
    List<CmsDepot>? depots,
  }) {
    return SubscriptionEntry(
      id: id ?? this.id,
      name: name ?? this.name,
      url: url ?? this.url,
      group: group ?? this.group,
      format: format ?? this.format,
      isPrivate: isPrivate ?? this.isPrivate,
      enabled: enabled ?? this.enabled,
      rawContent: rawContent ?? this.rawContent,
      siteCount: siteCount ?? this.siteCount,
      liveCount: liveCount ?? this.liveCount,
      updatedAt: updatedAt ?? this.updatedAt,
      warehouseUrl: warehouseUrl ?? this.warehouseUrl,
      activeDepotName: activeDepotName ?? this.activeDepotName,
      depots: depots ?? this.depots,
    );
  }

  bool get isEffectivelyPrivate =>
      isPrivate || group.contains('隐私') || group.contains('私密');
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'group': group,
    'format': format,
    'isPrivate': isEffectivelyPrivate,
    'enabled': enabled,
    'rawContent': rawContent,
    'siteCount': siteCount,
    'liveCount': liveCount,
    'updatedAt': updatedAt,
    'warehouseUrl': warehouseUrl,
    'activeDepotName': activeDepotName,
    'depots': depots.map((d) => d.toJson()).toList(),
  };
  factory SubscriptionEntry.fromJson(Map<String, dynamic> json) {
    final g = (json['group'] ?? '').toString().trim();
    final f = (json['format'] ?? '').toString().trim();
    final cleanGroup = g.isEmpty ? '默认分组' : g;
    return SubscriptionEntry(
      id: (json['id'] ?? '').toString().trim(),
      name: (json['name'] ?? '订阅源').toString().trim(),
      url: (json['url'] ?? '').toString().trim(),
      group: cleanGroup,
      format: f.isEmpty ? 'JSON' : f,
      isPrivate:
          json['isPrivate'] == true ||
          cleanGroup.contains('隐私') ||
          cleanGroup.contains('私密'),
      enabled: json['enabled'] != false,
      rawContent: (json['rawContent'] ?? '').toString(),
      siteCount: (json['siteCount'] as num?)?.toInt() ?? 0,
      liveCount: (json['liveCount'] as num?)?.toInt() ?? 0,
      updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      warehouseUrl: (json['warehouseUrl'] ?? '').toString(),
      activeDepotName: (json['activeDepotName'] ?? '').toString(),
      depots: (json['depots'] as List? ?? const [])
          .whereType<Map>()
          .map((d) => CmsDepot.fromJson(Map<String, dynamic>.from(d)))
          .toList(),
    );
  }
}

class CmsFilter {
  final String primaryTab;
  final String categoryId;
  final String genreLabel;
  final String area;
  final String year;
  const CmsFilter({
    this.primaryTab = 'recommend',
    this.categoryId = '',
    this.genreLabel = '',
    this.area = '',
    this.year = '',
  });
  bool get hasSubFilter =>
      categoryId.isNotEmpty ||
      genreLabel.isNotEmpty ||
      area.isNotEmpty ||
      year.isNotEmpty;
  int get activeDimensionCount =>
      (categoryId.isNotEmpty || genreLabel.isNotEmpty ? 1 : 0) +
      (area.isNotEmpty ? 1 : 0) +
      (year.isNotEmpty ? 1 : 0);
  CmsFilter copyWith({
    String? primaryTab,
    String? categoryId,
    String? genreLabel,
    String? area,
    String? year,
  }) {
    return CmsFilter(
      primaryTab: primaryTab ?? this.primaryTab,
      categoryId: categoryId ?? this.categoryId,
      genreLabel: genreLabel ?? this.genreLabel,
      area: area ?? this.area,
      year: year ?? this.year,
    );
  }
}

class CmsSite {
  final String key;
  final String? originalKey;
  String get sourceKey => originalKey ?? key;
  final String name;
  final int type;
  final String api;
  final String playUrl;
  final bool searchable;
  final String ext;
  /// Original JSON string value for full-name JS Spider init. [ext] keeps the
  /// existing normalized URL/plugin representation; object values have no raw string.
  final String? rawExtension;
  /// Site override and the owning subscription's plugin declaration, respectively.
  /// Keep both on the site: a merged subscription has no single global plugin.
  final String jar;
  final String spider;
  String get pluginReference => jar.isNotEmpty ? jar : spider;
  final Map<String, String> headers;
  final String group;
  final bool isPrivate;
  final String subscriptionId;
  const CmsSite({
    required this.key,
    this.originalKey,
    required this.name,
    required this.type,
    required this.api,
    this.playUrl = '',
    this.searchable = true,
    this.ext = '',
    this.rawExtension,
    this.jar = '',
    this.spider = '',
    this.headers = const {},
    this.group = '默认分组',
    this.isPrivate = false,
    this.subscriptionId = '',
  });
  CmsSite copyWith({
    String? key,
    String? name,
    int? type,
    String? api,
    String? playUrl,
    bool? searchable,
    String? ext,
    String? rawExtension,
    String? jar,
    String? spider,
    Map<String, String>? headers,
    String? group,
    bool? isPrivate,
    String? subscriptionId,
  }) {
    return CmsSite(
      key: key ?? this.key,
      originalKey: originalKey ?? this.key,
      name: name ?? this.name,
      type: type ?? this.type,
      api: api ?? this.api,
      playUrl: playUrl ?? this.playUrl,
      searchable: searchable ?? this.searchable,
      ext: ext ?? this.ext,
      rawExtension: rawExtension ?? (ext == null ? this.rawExtension : null),
      jar: jar ?? this.jar,
      spider: spider ?? this.spider,
      headers: headers ?? this.headers,
      group: group ?? this.group,
      isPrivate: isPrivate ?? this.isPrivate,
      subscriptionId: subscriptionId ?? this.subscriptionId,
    );
  }

  bool get isHttpApi {
    final lower = api.trim().toLowerCase();
    return lower.startsWith('http://') || lower.startsWith('https://');
  }

  bool get isM3uVodApi {
    return api.trim().toLowerCase().startsWith('m3u_vod://');
  }

  bool get isScriptOrJarApi {
    final lower = api.trim().toLowerCase().split('?').first;
    return isRemoteScriptSource || lower.startsWith('csp_') ||
        lower.endsWith('.js') ||
        lower.endsWith('.mjs') ||
        lower.endsWith('.jar') ||
        lower.endsWith('.py');
  }

  bool get isJavaScriptSource {
    final path = api.toLowerCase().split(RegExp(r'[?#]')).first;
    return api == 'csp_LocalScript.js' ||
        (type == 3 &&
            isHttpApi &&
            (path.endsWith('.js') || path.endsWith('.mjs')));
  }

  /// TVBox type 3 declares a script, even when a gateway hides its extension.
  /// Android JARs still require their own runtime/explicit portable adapter.
  bool get isRemoteScriptSource => type == 3 && isHttpApi &&
      Uri.tryParse(api)?.path.toLowerCase().endsWith('.jar') != true;

  bool get isDrpySource => api == 'csp_LocalRule.js' || api.toLowerCase() == 'csp_drpy';

  bool get isPythonSource =>
      api == 'csp_LocalScript.py' ||
      (type == 3 &&
          isHttpApi &&
          Uri.tryParse(api)?.path.toLowerCase().endsWith('.py') == true);

  /// Supports standard JSON/XML CMS (`type` 0 or 1), remote HTTP spider endpoints (`type` 4),
  /// M3U/TXT VOD playlists (`m3u_vod://`), and TVBox `csp_*` / `.js` spider sites via `CspBridge`.
  bool get isEmby => api.startsWith('emby://account/');
  bool get isCatPaw => api.startsWith('catpaw://');
  bool get canBrowse =>
      key != 'mydrive' &&
      (isEmby ||
          isCatPaw ||
          (type == 4 && isHttpApi) ||
          (isScriptOrJarApi
              ? CspBridge.hasAdapter(this)
              : isM3uVodApi ||
                    ((isHttpApi || isScriptOrJarApi) &&
                        (type == 0 ||
                            type == 1 ||
                            type == 4 ||
                            type == 3 ||
                            type == -1))));
  bool get isEffectivelyPrivate =>
      isPrivate || group.contains('隐私') || group.contains('私密');
  bool get requiresPluginRuntime => !canBrowse;
  bool get supported => canBrowse;
  String get unsupportedReason {
    if (isScriptOrJarApi && CspBridge.isNetdiskSite(this)) {
      return '此网盘源的原始插件尚未适配当前设备，无法读取原始网盘线路。请使用同一来源提供的兼容接口，或切换片源';
    }
    if (isScriptOrJarApi) return '该插件需要相应运行环境，可在兼容设备上使用';
    return '当前设备不支持此接口类型';
  }
}

class LiveSource {
  final String name;
  final String url;
  final Map<String, String> headers;
  final String group;
  final bool isPrivate;
  final String subscriptionId;
  /// Catalogue base URL and script owner survive subscription reloads.
  final String origin;
  final String inlineContent;
  final CmsSite? plugin;
  const LiveSource({
    required this.name,
    required this.url,
    this.headers = const {},
    this.group = '默认分组',
    this.isPrivate = false,
    this.subscriptionId = '',
    this.origin = '',
    this.inlineContent = '',
    this.plugin,
  });
  CmsSite get playbackSite => plugin ?? CmsSite(
    key: 'live:$subscriptionId:$name:$url', name: name, type: 1,
    api: url.startsWith('http') ? url : origin, headers: headers,
    group: group, isPrivate: isEffectivelyPrivate, subscriptionId: subscriptionId,
  );
  bool get isEffectivelyPrivate =>
      isPrivate || group.contains('隐私') || group.contains('私密');
  LiveSource copyWith({
    String? name,
    String? url,
    Map<String, String>? headers,
    String? group,
    bool? isPrivate,
    String? subscriptionId,
    String? origin,
    String? inlineContent,
    CmsSite? plugin,
  }) {
    return LiveSource(
      name: name ?? this.name,
      url: url ?? this.url,
      headers: headers ?? this.headers,
      group: group ?? this.group,
      isPrivate: isPrivate ?? this.isPrivate,
      subscriptionId: subscriptionId ?? this.subscriptionId,
      origin: origin ?? this.origin,
      inlineContent: inlineContent ?? this.inlineContent,
      plugin: (plugin ?? this.plugin)?.copyWith(
        group: group ?? this.group, isPrivate: isPrivate ?? this.isPrivate,
        subscriptionId: subscriptionId ?? this.subscriptionId,
      ),
    );
  }
}

class CmsParse {
  final String name;
  final String url;
  final int type;
  final Map<String, String> headers;
  const CmsParse({
    required this.name,
    required this.url,
    this.type = 0,
    this.headers = const {},
  });
}

class CmsConfig {
  final List<CmsSite> sites;
  final List<LiveSource> lives;
  final List<CmsDepot> depots;
  final List<CmsParse> parses;
  final String spider;
  const CmsConfig({
    this.sites = const [],
    this.lives = const [],
    this.depots = const [],
    this.parses = const [],
    this.spider = '',
  });
  List<CmsSite> get supportedSites =>
      sites.where((s) => s.supported).toList(growable: false);
  List<CmsSite> get publicSupportedSites => sites
      .where((s) => s.supported && !s.isEffectivelyPrivate)
      .toList(growable: false);
  List<CmsSite> get privateSupportedSites => sites
      .where((s) => s.supported && s.isEffectivelyPrivate)
      .toList(growable: false);
  List<LiveSource> get publicLives =>
      lives.where((l) => !l.isEffectivelyPrivate).toList(growable: false);
  List<LiveSource> get privateLives =>
      lives.where((l) => l.isEffectivelyPrivate).toList(growable: false);
  List<CmsSite> get pluginOnlySites => sites
      .where(
        (s) =>
            !s.supported &&
            !CspBridge.isMyDriveSite(s) &&
            !CspBridge.isNetdiskSite(s) &&
            !s.api.toLowerCase().startsWith('csp_sixv') &&
            !(s.api.toLowerCase().startsWith('csp_xpathguard') && s.ext.trim().isEmpty),
      )
      .toList(growable: false);
  Iterable<CmsSite> get scriptOwners sync* {
    yield* sites;
    for (final live in lives) {
      if (live.plugin != null) yield live.playbackSite;
    }
  }
  bool get isMultiDepotOnly =>
      sites.isEmpty && lives.isEmpty && depots.isNotEmpty;
}

class CmsCategory {
  final String id;
  final String name;

  /// MacCMS `type_pid`; empty or `0` for top-level categories.
  final String parentId;
  const CmsCategory({required this.id, required this.name, this.parentId = ''});
  bool get isTopLevel => parentId.isEmpty || parentId == '0';
}

class CmsEpisode {
  final String name;
  final String url;
  final Map<String, String> headers;

  /// Ephemeral server playback metadata; never part of subscription/history backups.
  final Map<String, dynamic> playbackSession;
  /// Short-lived quality choices returned for one episode; not saved in history.
  final List<CmsEpisode> variants;
  final String externalAudioUrl;
  const CmsEpisode({
    required this.name,
    required this.url,
    this.headers = const {},
    this.playbackSession = const {},
    this.variants = const [],
    this.externalAudioUrl = '',
  });
  String? get cloudProvider {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.userInfo.isNotEmpty || uri.hasPort) return null;
    if (uri.scheme == 'mmcloud' && const {'uc', 'baidu', 'ali'}.contains(uri.host)) return uri.host;
    if ((uri.scheme == 'mmwogg' && uri.host == 'quark') ||
        (uri.scheme == 'mmquark' && uri.host == 'owned')) return 'quark';
    return null;
  }

  bool get isScriptEpisode => url.startsWith('mmjs://play?');
  bool get needsSourceResolution =>
      isScriptEpisode || url.startsWith('mmcloud://') || url.startsWith('mmemby://play?') || url.startsWith('mmpaw://play?') || url.startsWith('mmt4://play?') || url.startsWith('mmquark://owned?') || url.startsWith('mmwogg://quark?');

  /// Whether [url] points to an already-downloaded local file (offline playback).
  bool get isLocalFile {
    final raw = url.trim();
    return raw.startsWith('/') ||
        RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(raw) ||
        raw.toLowerCase().startsWith('file://');
  }

  bool get isDirectPlayable {
    if (isLocalFile) return true;
    final u = url.trim().toLowerCase();
    if (!u.startsWith('http://') &&
        !u.startsWith('https://') &&
        !u.startsWith('rtmp://') &&
        !u.startsWith('rtsp://')) {
      return false;
    }
    if (u.contains('tuxiaobei.com/play/') ||
        u.contains('youlai.cn/jijiu/article/') ||
        u.contains('api.bilibili.com/x/player/playurl')) {
      return true;
    }
    final pathOnly = u.split('?').first.split('#').first;
    if (pathOnly.endsWith('.html') ||
        pathOnly.endsWith('.htm') ||
        pathOnly.contains('/share/')) {
      return false;
    }
    if (pathOnly.contains('/play/') &&
        !RegExp(
          r'\.(?:m3u8?|mp4|flv|mkv|ts|webm|mpd|mov|avi)$',
          caseSensitive: false,
        ).hasMatch(pathOnly)) {
      return false;
    }
    return true;
  }
}

class CmsLine {
  final String name;
  final List<CmsEpisode> episodes;
  const CmsLine({required this.name, required this.episodes});
}

class CmsVideo {
  final String id;
  final String title;
  final String poster;
  final String remarks;
  final String year;
  final String area;
  final String actor;
  final String description;
  final String tag;
  final List<CmsLine> lines;
  final List<String> sourceWarnings;
  const CmsVideo({
    required this.id,
    required this.title,
    this.poster = '',
    this.remarks = '',
    this.year = '',
    this.area = '',
    this.actor = '',
    this.description = '',
    this.tag = '',
    this.lines = const [],
    this.sourceWarnings = const [],
  });
}

class CmsListing {
  final int page;
  final int pageCount;
  final List<CmsVideo> videos;
  /// The requested subfilters were delegated to this source's category method.
  /// Its opaque filter values need not appear in returned video metadata.
  final bool sourceFiltered;
  const CmsListing({this.page = 1, this.pageCount = 1, this.videos = const [],
    this.sourceFiltered = false});
}

class LiveChannel {
  final String name;
  final String group;
  final List<String> urls;
  final String logo;
  final List<CmsEpisode> streams;
  const LiveChannel({
    required this.name,
    required this.group,
    required this.urls,
    this.logo = '',
    this.streams = const [],
  });
  List<CmsEpisode> get episodes => streams.isNotEmpty ? streams : [
    for (var i = 0; i < urls.length; i++)
      CmsEpisode(name: '线路 ${i + 1}', url: urls[i]),
  ];
}

class LiveGroup {
  final String name;
  final List<LiveChannel> channels;
  const LiveGroup({required this.name, required this.channels});
}

class WatchHistoryEntry {
  final String site;
  final String id;
  final String title;
  final String poster;
  final String line;
  final String episode;
  final int index;
  final int position;
  final int duration;
  final int updated;
  const WatchHistoryEntry({
    required this.site,
    required this.id,
    required this.title,
    this.poster = '',
    this.line = '',
    this.episode = '',
    this.index = 0,
    this.position = 0,
    this.duration = 0,
    this.updated = 0,
  });
  String get key => '$site\n$id';
  bool get complete =>
      duration >= 60000 &&
      position >= duration - (duration * 0.05).round().clamp(15000, 120000);
  int get resumePosition => complete ? 0 : (position < 0 ? 0 : position);
  double get progressFraction {
    if (duration <= 0) return 0.0;
    return (position / duration).clamp(0.0, 1.0);
  }

  Map<String, dynamic> toJson() => {
    'site': site,
    'id': id,
    'title': title,
    'poster': poster,
    'line': line,
    'episode': episode,
    'index': index,
    'position': position < 0 ? 0 : position,
    'duration': duration < 0 ? 0 : duration,
    'updated': updated,
  };
  factory WatchHistoryEntry.fromJson(Map<String, dynamic> json) {
    final pos = (json['position'] as num?)?.toInt() ?? 0;
    final dur = (json['duration'] as num?)?.toInt() ?? 0;
    return WatchHistoryEntry(
      site: (json['site'] ?? '').toString(),
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      poster: (json['poster'] ?? '').toString(),
      line: (json['line'] ?? '').toString(),
      episode: (json['episode'] ?? '').toString(),
      index: (json['index'] as num?)?.toInt() ?? 0,
      position: pos < 0 ? 0 : pos,
      duration: dur < 0 ? 0 : dur,
      updated: (json['updated'] as num?)?.toInt() ?? 0,
    );
  }
}

class FavoriteEntry {
  final String site;
  final String id;
  final String title;
  final String poster;
  final String remarks;
  final int updated;
  const FavoriteEntry({
    required this.site,
    required this.id,
    required this.title,
    this.poster = '',
    this.remarks = '',
    this.updated = 0,
  });
  String get key => '$site\n$id';
  Map<String, dynamic> toJson() => {
    'site': site,
    'id': id,
    'title': title,
    'poster': poster,
    'remarks': remarks,
    'updated': updated,
  };
  factory FavoriteEntry.fromJson(Map<String, dynamic> json) {
    return FavoriteEntry(
      site: (json['site'] ?? '').toString(),
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      poster: (json['poster'] ?? '').toString(),
      remarks: (json['remarks'] ?? '').toString(),
      updated: (json['updated'] as num?)?.toInt() ?? 0,
    );
  }
}
