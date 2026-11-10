import 'dart:async';
import 'dart:convert';
import 'cms_parser.dart';
import 'trailer_source.dart';
import 'models.dart';
import 'wogg_source.dart';

typedef CspHttpTextFetcher = Future<String> Function(
  String url, {
  Map<String, String> headers,
  Duration? requestTimeout,
});

/// Cross-platform compatibility bridge for TVBox `csp_*` and `drpy2.min.js` sites
/// on iOS, iPadOS, macOS, and Windows where Android `DexClassLoader` is unavailable.
class CspBridge {
  static const String _mobileSafariUa =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';
  static const String _desktopSafariUa =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.15';

  static bool isBannerNoticeSite(CmsSite site) {
    final n = site.name.toLowerCase();
    return n.contains('免费分享') ||
        n.contains('更新日期') ||
        n.contains('防失联') ||
        n.contains('公众号') ||
        n.contains('发布页') ||
        n.contains('网址发布') ||
        n.contains('谨防') ||
        n.contains('禁商用') ||
        n.contains('仅供学习') ||
        (n.contains('请先点击') && n.contains('配置'));
  }

  static bool canHandleSite(CmsSite site) {
    final lowerApi = site.api.trim().toLowerCase();
    if (lowerApi.startsWith('csp_')) {
      return !RegExp(
        r'^csp_(?:unknown|unknownguard|testpending.*|local.*)$',
        caseSensitive: false,
      ).hasMatch(lowerApi);
    }
    final cleanApi = lowerApi.split('?').first;
    if (cleanApi.endsWith('.js') || cleanApi.endsWith('.mjs') || cleanApi.endsWith('.py') || cleanApi.endsWith('.jar')) {
      return true;
    }
    return false;
  }

  static String? guardAdapterFor(CmsSite site) => site.type != 3 ? null : const {
    'csp_dm84guard': 'dm84-v1',
    'csp_dm84': 'dm84-v1',
    'csp_aueteguard': 'auete-v1',
    'csp_auete': 'auete-v1',
    'csp_bttwooguard': 'bttwoo-v1',
    'csp_bttwoo': 'bttwoo-v1',
    'csp_t4guard': 't4-v1',
    'csp_t4': 't4-v1',
    'csp_fyguard': 'fy-v1',
    'csp_fy': 'fy-v1',
  }[site.api.toLowerCase()];

  static bool hasAdapter(CmsSite site) => WoggSource.supports(site) || (guardAdapterFor(site) != null && site.pluginReference.trim().isNotEmpty) || site.isDrpySource || site.isRemoteScriptSource || site.isJavaScriptSource || site.isPythonSource || TrailerSource.matches(site) || hasBuiltinAdapter(site);

  static bool hasBuiltinAdapter(CmsSite site) =>
      !site.api.startsWith('csp_Local') && (isDoubanSite(site) || isMyDriveSite(site) || isBiliSite(site) ||
      isTuxiaobeiSite(site) || isFirstAidSite(site) || isHuyaSite(site) ||
      isDouyuSite(site) || backendsForSite(site).isNotEmpty);

  static bool isDoubanSite(CmsSite site) {
    if (isBannerNoticeSite(site)) return true;
    final lowerApi = site.api.toLowerCase();
    final lowerName = site.name.toLowerCase();
    return lowerApi.contains('doudou') ||
        lowerApi.contains('douban') ||
        lowerName.contains('豆豆') ||
        lowerName.contains('豆瓣');
  }

  static bool isMyDriveSite(CmsSite site) {
    if (isBannerNoticeSite(site)) return false;
    final lowerApi = site.api.toLowerCase();
    final lowerName = site.name.toLowerCase();
    final lowerKey = site.key.toLowerCase();
    return lowerApi.contains('mydrive') ||
        lowerApi.contains('panwebshare') ||
        lowerApi == 'csp_config' ||
        lowerApi == 'csp_configcenter' ||
        lowerApi.startsWith('csp_push') ||
        lowerKey.contains('mydrive') ||
        lowerKey == 'config' ||
        lowerKey == 'push_agent' ||
        lowerName.contains('我的云盘') ||
        lowerName.contains('我的网盘') ||
        lowerName.contains('云盘配置') ||
        lowerName.contains('网盘配置') ||
        lowerName.contains('配置中心');
  }

  static bool isNetdiskSite(CmsSite site) {
    if (isMyDriveSite(site)) return true;
    final lowerApi = site.api.toLowerCase();
    final lowerName = site.name.toLowerCase();
    final lowerKey = site.key.toLowerCase();
    return lowerApi.contains('wogg') ||
        lowerApi.contains('seedhub') ||
        lowerApi.contains('pansou') ||
        lowerApi.contains('s_zps') ||
        lowerApi.contains('ypanso') ||
        lowerApi.contains('bpanso') ||
        lowerApi.contains('yiso') ||
        lowerApi.contains('panta') ||
        lowerApi.contains('kkss') ||
        lowerApi.contains('ucss') ||
        lowerApi.contains('uuss') ||
        lowerApi.contains('quark') ||
        lowerApi.contains('baidu') ||
        lowerApi.contains('alipan') ||
        lowerApi.contains('aliyundrive') ||
        lowerName.contains('玩偶') ||
        lowerName.contains('木偶') ||
        lowerName.contains('多多') ||
        lowerName.contains('虎斑') ||
        lowerName.contains('盘库') ||
        lowerName.contains('蜡笔') ||
        lowerName.contains('至臻') ||
        lowerName.contains('闪电') ||
        lowerName.contains('聚剧') ||
        lowerName.contains('四盘') ||
        lowerName.contains('盘搜') ||
        lowerName.contains('易搜') ||
        lowerName.contains('盘她') ||
        lowerName.contains('盘他') ||
        lowerName.contains('夸父') ||
        lowerName.contains('优汐') ||
        lowerName.contains('嘟嘟') ||
        lowerName.contains('阿狸') ||
        lowerName.contains('抠抠') ||
        lowerName.contains('土豆') ||
        lowerName.contains('米粒') ||
        lowerName.contains('下饭') ||
        lowerName.contains('小米') ||
        lowerName.contains('二小') ||
        lowerName.contains('欧哥') ||
        lowerName.contains('奥秘') ||
        lowerName.contains('团长') ||
        lowerName.contains('雷鲸') ||
        lowerName.contains('花卷') ||
        lowerName.contains('观影') ||
        lowerName.contains('七味') ||
        lowerName.contains('快影') ||
        lowerName.contains('4k') ||
        lowerName.contains('云盘') ||
        lowerKey.contains('wogg') ||
        lowerKey.contains('seedhub') ||
        lowerKey.contains('zpan') ||
        lowerKey.contains('yiso') ||
        lowerKey.contains('ypanso') ||
        lowerKey.contains('bpanso');
  }

  /// Maps a playback line name (e.g. `夸父智1`, `夸克`, `优汐智1`, `嘟嘟无限2`, `百度`, `阿狸原画`)
  /// to its corresponding Netdisk drive key (`quark`, `uc`, `baidu`, `ali`), or `null` if it is a normal VOD line.
  static String? netdiskDriveKeyForLineName(String lineName) {
    final lower = lineName.trim().toLowerCase();
    if (lower.isEmpty) return null;
    if (lower.contains('夸父') || lower.contains('夸克') || lower.contains('quark')) {
      return 'quark';
    }
    if (lower.contains('优汐') || lower == 'uc' || lower.startsWith('uc') || lower.contains('uc网盘') || lower.contains('uc云盘')) {
      return 'uc';
    }
    if (lower.contains('嘟嘟') || lower.contains('百度') || lower.contains('baidu')) {
      return 'baidu';
    }
    if (lower.contains('阿狸') || lower.contains('阿里') || lower.contains('alipan') || lower.contains('aliyun')) {
      return 'ali';
    }
    return null;
  }

  /// Extracts a 1-based episode number from Netdisk / VOD episode labels such as
  /// `JJC.S01E02 [1.30GB]`, `E01 [5.38GB]`, `[4K HDR] 第03集`, or `第12集`.
  static int extractEpisodeNumber(String episodeName, int fallbackIndex) {
    final stripped = episodeName
        .replaceAll(RegExp(r'\[[^\]]*\]'), ' ')
        .replaceAll(RegExp(r'\b(?:4[kK]|1080[pP]|2160[pP]|720[pP]|HDR\d*|x26[45]|H\.?26[45]|HEVC|AAC|DDP\d*(?:\.\d+)?)\b'), ' ')
        .trim();
    final seMatch = RegExp(r'[Ss]\d{1,2}[Ee](\d{1,4})').firstMatch(stripped);
    if (seMatch != null) {
      final n = int.tryParse(seMatch.group(1) ?? '');
      if (n != null && n > 0) return n;
    }
    final cnMatch = RegExp(r'第\s*(\d{1,4})\s*[集话期章节回]').firstMatch(stripped);
    if (cnMatch != null) {
      final n = int.tryParse(cnMatch.group(1) ?? '');
      if (n != null && n > 0) return n;
    }
    final epMatch = RegExp(r'(?:^|[^a-zA-Z0-9])[Ee][Pp]?(\d{1,4})(?!\d)').firstMatch(stripped);
    if (epMatch != null) {
      final n = int.tryParse(epMatch.group(1) ?? '');
      if (n != null && n > 0) return n;
    }
    final numOnly = RegExp(r'^\s*#?(\d{1,4})(?:\s|$)').firstMatch(stripped);
    if (numOnly != null) {
      final n = int.tryParse(numOnly.group(1) ?? '');
      if (n != null && n > 0) return n;
    }
    return fallbackIndex + 1;
  }

  /// Finds the best matching episode index in [targetLine] for [sourceEpisodeName].
  static int matchEpisodeIndexInLine(
    CmsLine targetLine,
    String sourceEpisodeName,
    int fallbackIndex,
  ) {
    if (targetLine.episodes.isEmpty) return 0;
    final trimmed = sourceEpisodeName.trim();
    final exactIdx = targetLine.episodes.indexWhere((e) => e.name.trim() == trimmed);
    if (exactIdx >= 0) return exactIdx;
    final targetNum = extractEpisodeNumber(trimmed, fallbackIndex);
    for (int i = 0; i < targetLine.episodes.length; i++) {
      if (extractEpisodeNumber(targetLine.episodes[i].name, i) == targetNum) {
        return i;
      }
    }
    return (targetNum - 1).clamp(0, targetLine.episodes.length - 1);
  }

  static bool isBiliSite(CmsSite site) {
    final lowerApi = site.api.toLowerCase();
    final lowerKey = site.key.toLowerCase();
    return lowerApi.contains('bili') || lowerKey.contains('bili');
  }

  static bool isTuxiaobeiSite(CmsSite site) {
    final lowerApi = site.api.toLowerCase();
    final lowerKey = site.key.toLowerCase();
    final lowerName = site.name.toLowerCase();
    final lowerExt = site.ext.toLowerCase();
    return lowerApi.contains('tuxiaobei') ||
        lowerKey.contains('兔小贝') ||
        lowerName.contains('兔小贝') ||
        lowerExt.contains('tuxiaobei') ||
        lowerExt.contains('兔小贝') ||
        lowerExt.contains('%e5%85%94%e5%b0%8f%e8%b4%9d');
  }

  static bool isFirstAidSite(CmsSite site) {
    final lowerApi = site.api.toLowerCase();
    final lowerName = site.name.toLowerCase();
    return lowerApi.contains('firstaid') || lowerName.contains('急救');
  }

  static bool isHuyaSite(CmsSite site) {
    final lowerApi = site.api.toLowerCase();
    final lowerKey = site.key.toLowerCase();
    final lowerName = site.name.toLowerCase();
    final lowerExt = site.ext.toLowerCase();
    return lowerApi.contains('huya') ||
        lowerKey.contains('虎牙') ||
        lowerKey.contains('huya') ||
        lowerName.contains('虎牙') ||
        lowerExt.contains('huya') ||
        lowerExt.contains('虎牙');
  }

  static bool isDouyuSite(CmsSite site) {
    final lowerKey = site.key.toLowerCase();
    final lowerName = site.name.toLowerCase();
    final lowerExt = site.ext.toLowerCase();
    return lowerKey.contains('斗鱼') ||
        lowerKey.contains('douyu') ||
        lowerName.contains('斗鱼') ||
        lowerExt.contains('douyu') ||
        lowerExt.contains('斗鱼');
  }

  /// Only endpoints explicitly supplied by this source. A plugin name is
  /// never permission to substitute another provider or reuse its video IDs.
  static List<({String name, String api})> backendsForSite(CmsSite site) {
    // Non-MacCMS HTML scrapers / Guard adapters are handled by their own adapters.
    if (guardAdapterFor(site) != null ||
        isNetdiskSite(site) ||
        isBiliSite(site) ||
        isDoubanSite(site) ||
        isMyDriveSite(site) ||
        isTuxiaobeiSite(site) ||
        isFirstAidSite(site) ||
        isHuyaSite(site) ||
        isDouyuSite(site) ||
        TrailerSource.matches(site)) {
      return [];
    }
    if (site.key == 'html' && site.name == 'HTML') return [];
    final trimmedApi = site.api.trim();
    final isHtmlSiteExt = isNetdiskSite(site) ||
        RegExp(
          r'^csp_(?:libvio|newcz|sixv.*|s_zps.*|wogg.*|seedhub.*|ypanso.*|bpanso.*|kkss.*|uuss.*|push.*)$',
          caseSensitive: false,
        ).hasMatch(trimmedApi);
    final endpoints = <({String name, String api})>[];
    final seen = <String>{};
    void addCandidate(String raw) {
      final t = raw.trim();
      if (!t.startsWith('http://') && !t.startsWith('https://')) return;
      final lower = t.toLowerCase().split('?').first;
      if (lower.endsWith('.jar') ||
          lower.endsWith('.js') ||
          lower.endsWith('.py') ||
          lower.endsWith('.txt')) {
        return;
      }
      if (seen.add(t)) {
        endpoints.add((name: site.name.isEmpty ? '默认线路' : site.name, api: t));
      }
    }

    addCandidate(site.api);
    final ext = site.ext.trim();
    if (ext.isNotEmpty && !isHtmlSiteExt) {
      if (!ext.startsWith('{')) {
        addCandidate(ext);
        for (final part in ext.split(RegExp(r'[\$,|;\s]+'))) {
          addCandidate(part);
        }
      }
      if (!ext.startsWith('{') && !ext.startsWith('http')) {
        try {
          final decoded = utf8.decode(base64.decode(ext), allowMalformed: true).trim();
          addCandidate(decoded);
          if (decoded.startsWith('{')) {
            final map = jsonDecode(decoded);
            if (map is Map) {
              for (final k in const ['api', 'url', 'host', 'site']) {
                final v = map[k];
                if (v is String) addCandidate(v);
              }
            }
          }
        } catch (_) {}
      } else if (ext.startsWith('{')) {
        try {
          final map = jsonDecode(ext);
          if (map is Map) {
            for (final k in const ['api', 'url', 'host', 'site']) {
              final v = map[k];
              if (v is String) addCandidate(v);
            }
          }
        } catch (_) {}
      }
    }
    return endpoints;
  }

  static Future<(List<CmsCategory>, CmsListing)> fetchHome(
    CmsSite site,
    CspHttpTextFetcher fetchText,
  ) async {
    if (TrailerSource.matches(site)) return ([TrailerSource.category], await TrailerSource.list(1, '', fetchText));
    if (isDoubanSite(site)) {
      return _fetchDoubanHome(fetchText);
    }
    if (isMyDriveSite(site)) {
      return _fetchMyDriveHome(fetchText);
    }
    if (isTuxiaobeiSite(site)) {
      return _fetchTuxiaobeiHome(fetchText);
    }
    if (isFirstAidSite(site)) {
      return _fetchFirstAidHome(fetchText);
    }
    if (isHuyaSite(site)) {
      return _fetchHuyaHome(fetchText);
    }
    if (isDouyuSite(site)) {
      return _fetchDouyuHome(fetchText);
    }
    if (isBiliSite(site)) {
      return _fetchBiliHome(site, fetchText);
    }
    return _fetchConfiguredHome(site, fetchText);
  }

  static Future<CmsListing> fetchCategory(
    CmsSite site,
    String categoryId,
    int page,
    CspHttpTextFetcher fetchText, {
    List<String> childIds = const [],
  }) async {
    if (TrailerSource.matches(site)) return TrailerSource.list(page, '', fetchText);
    if (isDoubanSite(site)) {
      return _fetchDoubanCategory(categoryId, page, fetchText);
    }
    if (isMyDriveSite(site)) {
      return _fetchMyDriveCategory(categoryId, page, fetchText);
    }
    if (isTuxiaobeiSite(site)) {
      return _fetchTuxiaobeiCategory(categoryId, page, fetchText);
    }
    if (isFirstAidSite(site)) {
      return _fetchFirstAidCategory(categoryId, page, fetchText);
    }
    if (isHuyaSite(site)) {
      return _fetchHuyaCategory(categoryId, page, fetchText);
    }
    if (isDouyuSite(site)) {
      return _fetchDouyuCategory(categoryId, page, fetchText);
    }
    if (isBiliSite(site)) {
      return _fetchBiliSearch(categoryId, page, fetchText);
    }
    return _fetchConfiguredCategory(site, categoryId, page, fetchText, childIds);
  }

  /// Interleaves the same page of several leaf categories into one listing so a
  /// parent category (e.g. 电影片 / 连续剧) shows a mixed, de-duplicated feed.
  static CmsListing mergeChildListings(List<CmsListing> children, int page) {
    final seen = <String>{};
    final merged = <CmsVideo>[];
    var maxPages = 1;
    var longest = 0;
    for (final c in children) {
      if (c.pageCount > maxPages) maxPages = c.pageCount;
      if (c.videos.length > longest) longest = c.videos.length;
    }
    for (int i = 0; i < longest; i++) {
      for (final c in children) {
        if (i >= c.videos.length) continue;
        final v = c.videos[i];
        final key = v.id.isNotEmpty ? v.id : v.title;
        if (seen.add(key)) merged.add(v);
      }
    }
    return CmsListing(
      page: page < 1 ? 1 : page,
      pageCount: maxPages,
      videos: merged,
    );
  }

  static Future<CmsListing> fetchSearch(
    CmsSite site,
    String keyword,
    int page,
    CspHttpTextFetcher fetchText,
  ) async {
    if (TrailerSource.matches(site)) return TrailerSource.list(page, keyword, fetchText);
    if (isDoubanSite(site) || isMyDriveSite(site)) {
      return const CmsListing();
    }
    if (isBiliSite(site)) {
      return _fetchBiliSearch(keyword, page, fetchText);
    }
    if (isFirstAidSite(site)) {
      final (_, homeListing) = await _fetchFirstAidHome(fetchText);
      final filtered = homeListing.videos
          .where((v) => v.title.toLowerCase().contains(keyword.toLowerCase()))
          .toList(growable: false);
      return CmsListing(page: 1, pageCount: 1, videos: filtered);
    }
    return _fetchConfiguredSearch(site, keyword, page, fetchText);
  }

  static Future<CmsVideo> fetchDetail(
    CmsSite site,
    CmsVideo fallback,
    CspHttpTextFetcher fetchText,
  ) async {
    if (TrailerSource.matches(site)) return TrailerSource.detail(fallback, fetchText);
    if (isTuxiaobeiSite(site)) {
      final cleanId = fallback.id.contains(r'$')
          ? fallback.id.split(r'$').last.split('@@').first
          : fallback.id;
      return CmsVideo(
        id: fallback.id,
        title: fallback.title,
        poster: fallback.poster,
        remarks: fallback.remarks,
        year: fallback.year,
        area: fallback.area,
        actor: fallback.actor,
        description: fallback.description.isEmpty ? '儿童启蒙精选视频' : fallback.description,
        tag: fallback.tag,
        lines: [
          CmsLine(
            name: '启蒙直连',
            episodes: [
              CmsEpisode(
                name: fallback.title.isEmpty ? '正片' : fallback.title,
                url: 'https://www.tuxiaobei.com/play/$cleanId',
                headers: const {'User-Agent': _mobileSafariUa},
              ),
            ],
          ),
        ],
      );
    }

    if (isFirstAidSite(site)) {
      final cleanPath = fallback.id.replaceFirst(RegExp(r'^/'), '');
      final url = fallback.id.startsWith('http')
          ? fallback.id
          : 'https://m.youlai.cn/$cleanPath';
      return CmsVideo(
        id: fallback.id,
        title: fallback.title,
        poster: fallback.poster,
        remarks: fallback.remarks,
        description: fallback.description.isEmpty ? '有来医生急救科普教学视频' : fallback.description,
        lines: [
          CmsLine(
            name: '教学视频',
            episodes: [
              CmsEpisode(
                name: fallback.title.isEmpty ? '正片' : fallback.title,
                url: url,
                headers: const {'User-Agent': _mobileSafariUa},
              ),
            ],
          ),
        ],
      );
    }

    if (isHuyaSite(site)) {
      return _fetchHuyaDetail(fallback, fetchText);
    }

    if (isBiliSite(site) && fallback.id.startsWith('BV')) {
      final detailed = await _fetchBiliDetail(fallback, fetchText);
      if (detailed.lines.isNotEmpty) return detailed;
    }

    // Catalogue entries are matched by CmsClient against imported sources,
    // which returns the actual owning site with its resolver and credentials.
    if (isDoubanSite(site) || isMyDriveSite(site) ||
        fallback.id.startsWith('msearch:')) {
      return _withoutLines(fallback);
    }
    if (isBiliSite(site) || isDouyuSite(site)) return fallback;

    final backends = _requireBackends(site);
    final bound = _homeBackendBySite[_backendKey(site)];
    final backend = backends.firstWhere((b) => b.api == bound,
        orElse: () => backends.first);
    // A detail ID belongs to one backend. Never try the same number at another
    // service, and never merge same-title search results into these lines.
    final isAppV2 = _isAppV2Endpoint(backend.api);
    final uri = isAppV2
        ? _configuredUri(backend.api, {'id': fallback.id}, appPath: 'video_detail')
        : _configuredUri(backend.api, {'ac': 'detail', 'ids': fallback.id});
    final raw = await fetchText(uri.toString(), headers: site.headers);
    final listing = CmsParser.parseListing(raw);
    if (listing.videos.isEmpty) return _withoutLines(fallback);
    final v = listing.videos.first;
    return CmsVideo(
      id: v.id.isEmpty ? fallback.id : v.id,
      title: v.title.isEmpty ? fallback.title : v.title,
      poster: CmsParser.isBrokenPosterUrl(v.poster) ? fallback.poster : v.poster,
      remarks: v.remarks.isEmpty ? fallback.remarks : v.remarks,
      year: v.year.isEmpty ? fallback.year : v.year,
      area: v.area.isEmpty ? fallback.area : v.area,
      actor: v.actor.isEmpty ? fallback.actor : v.actor,
      description: v.description.isEmpty ? fallback.description : v.description,
      tag: v.tag.isEmpty ? fallback.tag : v.tag,
      lines: v.lines,
    );
  }

  static CmsVideo _withoutLines(CmsVideo video) => CmsVideo(
    id: video.id, title: video.title, poster: video.poster,
    remarks: video.remarks, year: video.year, area: video.area,
    actor: video.actor, description: video.description, tag: video.tag,
  );

  /// Resolves on-demand wrapper URLs (Tuxiaobei HTML, Youlai HTML, Bilibili playurl JSON, Huya room)
  /// into direct `.mp4` / `.m3u8` media stream URLs right before playback starts.
  static Future<CmsEpisode> resolveEpisodeForPlayback(
    CmsSite site,
    CmsEpisode episode,
    CspHttpTextFetcher fetchText,
  ) async {
    if (TrailerSource.matches(site)) return TrailerSource.resolve(episode, fetchText);
    final rawUrl = episode.url.trim();

    // 1. Tuxiaobei `/play/{id}` -> extract `video-src` MP4
    if (rawUrl.contains('tuxiaobei.com/play/')) {
      try {
        final html = await fetchText(
          rawUrl,
          headers: const {'User-Agent': _mobileSafariUa},
        );
        final match = RegExp(r'''video-src\s*=\s*["']([^"']+\.mp4[^"']*)["']''')
            .firstMatch(html);
        final mp4 = match?.group(1)?.trim() ?? '';
        if (mp4.isNotEmpty) {
          return CmsEpisode(
            name: episode.name,
            url: mp4.startsWith('//') ? 'https:$mp4' : mp4,
            headers: const {'User-Agent': _mobileSafariUa},
          );
        }
      } catch (_) {}
    }

    // 2. Youlai `/jijiu/article/...` -> extract `vod.youlai.cn/...mp4`
    if (rawUrl.contains('youlai.cn/') && rawUrl.endsWith('.html')) {
      try {
        final html = await fetchText(
          rawUrl,
          headers: const {'User-Agent': _mobileSafariUa},
        );
        final match = RegExp(r'https?://vod\.youlai\.cn/[^\s"<>]+\.mp4')
            .firstMatch(html);
        final mp4 = match?.group(0)?.trim() ?? '';
        if (mp4.isNotEmpty) {
          return CmsEpisode(
            name: episode.name,
            url: mp4,
            headers: const {'User-Agent': _mobileSafariUa},
          );
        }
      } catch (_) {}
    }

    // 3. Bilibili `api.bilibili.com/x/player/playurl` -> extract `durl[0].url`
    if (rawUrl.contains('api.bilibili.com/x/player/playurl')) {
      try {
        final jsonStr = await fetchText(
          rawUrl,
          headers: const {
            'User-Agent': _desktopSafariUa,
            'Referer': 'https://www.bilibili.com/',
          },
        );
        final decoded = jsonDecode(jsonStr);
        if (decoded is Map) {
          final data = decoded['data'];
          if (data is Map && data['durl'] is List && (data['durl'] as List).isNotEmpty) {
            final first = (data['durl'] as List).first;
            if (first is Map) {
              final streamUrl = (first['url'] ?? '').toString().trim();
              if (streamUrl.isNotEmpty) {
                return CmsEpisode(
                  name: episode.name,
                  url: streamUrl,
                  headers: const {
                    'User-Agent': _desktopSafariUa,
                    'Referer': 'https://www.bilibili.com/',
                  },
                );
              }
            }
          }
        }
      } catch (_) {}
    }

    // 4. Huya room -> extract HLS `.m3u8`
    if (rawUrl.contains('huya.com/') && !rawUrl.contains('.m3u8')) {
      final roomId = rawUrl.split('/').last.split('?').first.trim();
      if (roomId.isNotEmpty) {
        try {
          final jsonStr = await fetchText(
            'https://mp.huya.com/cache.php?m=Live&do=profileRoom&roomid=$roomId',
            headers: const {'User-Agent': _mobileSafariUa},
          );
          final decoded = jsonDecode(jsonStr);
          final hlsList = decoded?['data']?['stream']?['hls']?['multiLine'];
          if (hlsList is List && hlsList.isNotEmpty) {
            final streamUrl = (hlsList.first['url'] ?? '').toString().trim();
            if (streamUrl.isNotEmpty) {
              return CmsEpisode(
                name: episode.name,
                url: streamUrl,
                headers: const {'User-Agent': _mobileSafariUa},
              );
            }
          }
        } catch (_) {}
      }
    }

    return episode;
  }

  // ---------------------------------------------------------------------------
  // Douban (`csp_DouDouGuard`) implementation
  // ---------------------------------------------------------------------------

  static const List<CmsCategory> _doubanCategories = [
    CmsCategory(id: 'hot_gaia', name: '热播电影'),
    CmsCategory(id: 'tv_hot', name: '热播剧集'),
    CmsCategory(id: 'show_hot', name: '热播综艺'),
    CmsCategory(id: 'movie', name: '电影筛选'),
    CmsCategory(id: 'tv', name: '电视筛选'),
    CmsCategory(id: 'rank_list_movie', name: '电影榜单'),
    CmsCategory(id: 'rank_list_tv', name: '电视剧榜单'),
  ];

  // ---------------------------------------------------------------------------
  // MyDrive (`csp_MyDriveGuard` — `🗂我的云盘┃配置`) implementation
  // ---------------------------------------------------------------------------

  static const List<CmsCategory> _myDriveCategories = [
    CmsCategory(id: 'qr_config', name: '网盘配置'),
    CmsCategory(id: 'quark', name: '我的夸父'),
    CmsCategory(id: 'uc', name: '我的优汐'),
    CmsCategory(id: 'baidu', name: '我的嘟嘟'),
    CmsCategory(id: 'ali', name: '我的阿狸'),
  ];

  static const List<CmsVideo> _myDriveQrCards = [
    CmsVideo(
      id: 'netdisk_qr:quark',
      title: '我的夸父 · 夸克网盘',
      remarks: '点击扫码登录',
      year: '4K原画',
      area: '云盘配置',
      actor: '夸克网盘官方扫码授权 / Cookie 配置',
      description: '扫码登录夸克网盘（我的夸父），同步电视端夸父智1 / 夸父无限1 4K 原画网盘线路。',
    ),
    CmsVideo(
      id: 'netdisk_qr:uc',
      title: '我的优汐 · UC网盘',
      remarks: '点击扫码登录',
      year: '4K原画',
      area: '云盘配置',
      actor: 'UC网盘官方扫码授权 / Cookie 配置',
      description: '扫码登录UC网盘（我的优汐），同步电视端优汐智1 / 优汐无限1 4K 原画网盘线路。',
    ),
    CmsVideo(
      id: 'netdisk_qr:baidu',
      title: '我的嘟嘟 · 百度网盘',
      remarks: '点击扫码登录',
      year: '4K原画',
      area: '云盘配置',
      actor: '百度网盘官方扫码授权 / Cookie 配置',
      description: '扫码登录百度网盘（我的嘟嘟），同步电视端嘟嘟无限2 / 嘟嘟无限3 4K 原画网盘线路。',
    ),
    CmsVideo(
      id: 'netdisk_qr:ali',
      title: '我的阿狸 · 阿里云盘',
      remarks: '点击扫码登录',
      year: '4K原画',
      area: '云盘配置',
      actor: '阿里云盘官方扫码授权 / Token 配置',
      description: '扫码登录阿里云盘（我的阿狸），同步电视端阿狸原画 4K 直连网盘线路。',
    ),
  ];

  static Future<(List<CmsCategory>, CmsListing)> _fetchMyDriveHome(
    CspHttpTextFetcher fetchText,
  ) async {
    final listing = await _fetchMyDriveCategory('qr_config', 1, fetchText);
    return (_myDriveCategories, listing);
  }

  static Future<CmsListing> _fetchMyDriveCategory(
    String categoryId,
    int page,
    CspHttpTextFetcher fetchText,
  ) async {
    final pg = page < 1 ? 1 : page;
    final cards = <CmsVideo>[];
    if (pg == 1) {
      if (categoryId == 'quark') {
        cards.add(_myDriveQrCards[0]);
      } else if (categoryId == 'uc') {
        cards.add(_myDriveQrCards[1]);
      } else if (categoryId == 'baidu') {
        cards.add(_myDriveQrCards[2]);
      } else if (categoryId == 'ali') {
        cards.add(_myDriveQrCards[3]);
      } else {
        cards.addAll(_myDriveQrCards);
      }
    }
    // These are account configuration cards, not a media catalogue. Douban
    // posters cannot stand in for files in a user's cloud drive.
    return CmsListing(page: pg, pageCount: 1, videos: cards);
  }

  static String _doubanCollectionCode(String categoryId) {
    switch (categoryId) {
      case 'hot_gaia':
        return 'movie_hot_gaia';
      case 'tv_hot':
        return 'tv_hot';
      case 'show_hot':
        return 'show_hot';
      case 'movie':
        return 'movie_real_time_hotest';
      case 'tv':
        return 'tv_real_time_hotest';
      case 'rank_list_movie':
        return 'movie_top250';
      case 'rank_list_tv':
        return 'tv_domestic';
      default:
        return 'movie_hot_gaia';
    }
  }

  static Future<(List<CmsCategory>, CmsListing)> _fetchDoubanHome(
    CspHttpTextFetcher fetchText,
  ) async {
    try {
      final listing = await _fetchDoubanCategory('hot_gaia', 1, fetchText);
      if (listing.videos.isNotEmpty) {
        return (_doubanCategories, listing);
      }
    } catch (_) {}
    // Fallback to VOD pool if Douban API is unreachable
    return _fetchConfiguredHome(
      const CmsSite(key: 'douban_fallback', name: '豆豆', type: 3, api: 'csp_DouDouGuard'),
      fetchText,
    );
  }

  static Future<CmsListing> _fetchDoubanCategory(
    String categoryId,
    int page,
    CspHttpTextFetcher fetchText,
  ) async {
    final code = _doubanCollectionCode(categoryId);
    final count = 20;
    final start = ((page < 1 ? 1 : page) - 1) * count;
    final url =
        'https://m.douban.com/rexxar/api/v2/subject_collection/$code/items?start=$start&count=$count';
    final raw = await fetchText(
      url,
      headers: const {
        'User-Agent': _mobileSafariUa,
        'Referer': 'https://m.douban.com/',
      },
    );
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return const CmsListing();
    final total = (decoded['total'] as num?)?.toInt() ?? 100;
    final pageCount = ((total + count - 1) ~/ count).clamp(1, 50);
    final rawItems = decoded['subject_collection_items'] ?? decoded['items'];
    if (rawItems is! List) return const CmsListing();
    final videos = <CmsVideo>[];
    for (final item in rawItems) {
      if (item is! Map) continue;
      final title = (item['title'] ?? '').toString().trim();
      if (title.isEmpty) continue;
      String poster = '';
      if (item['pic'] is Map) {
        poster = (item['pic']['large'] ?? item['pic']['normal'] ?? '').toString().trim();
      } else if (item['cover'] is Map) {
        poster = (item['cover']['url'] ?? '').toString().trim();
      }
      poster = CmsParser.upgradePosterUrlToHd(poster);
      String ratingStr = '';
      if (item['rating'] is Map && item['rating']['value'] != null) {
        final val = item['rating']['value'];
        if (val is num && val > 0) {
          ratingStr = '豆瓣 ${val.toStringAsFixed(1)}';
        }
      }
      final subtitle = (item['card_subtitle'] ?? item['info'] ?? '').toString().trim();
      final year = (item['year'] ?? '').toString().trim();
      videos.add(
        CmsVideo(
          id: 'msearch:$title',
          title: title,
          poster: poster,
          remarks: ratingStr.isNotEmpty ? ratingStr : (item['episodes_info'] ?? '').toString().trim(),
          year: year,
          actor: subtitle,
          description: subtitle,
        ),
      );
    }
    return CmsListing(
      page: page < 1 ? 1 : page,
      pageCount: pageCount,
      videos: videos,
    );
  }

  // ---------------------------------------------------------------------------
  // Tuxiaobei (`dr_兔小贝`) implementation
  // ---------------------------------------------------------------------------

  static const List<CmsCategory> _tuxiaobeiCategories = [
    CmsCategory(id: '2', name: '儿歌'),
    CmsCategory(id: '3', name: '故事'),
    CmsCategory(id: '4', name: '国学'),
    CmsCategory(id: '25', name: '启蒙'),
  ];

  static Future<(List<CmsCategory>, CmsListing)> _fetchTuxiaobeiHome(
    CspHttpTextFetcher fetchText,
  ) async {
    final listing = await _fetchTuxiaobeiCategory('2', 1, fetchText);
    return (_tuxiaobeiCategories, listing);
  }

  static Future<CmsListing> _fetchTuxiaobeiCategory(
    String categoryId,
    int page,
    CspHttpTextFetcher fetchText,
  ) async {
    final cat = categoryId.isEmpty ? '2' : categoryId;
    final pg = page < 1 ? 1 : page;
    final raw = await fetchText(
      'https://www.tuxiaobei.com/list/mip-data?typeId=$cat&page=$pg&callback=',
      headers: const {'User-Agent': _mobileSafariUa},
    );
    final openBrace = raw.indexOf('{');
    final closeBrace = raw.lastIndexOf('}');
    if (openBrace < 0 || closeBrace <= openBrace) return const CmsListing();
    final decoded = jsonDecode(raw.substring(openBrace, closeBrace + 1));
    final items = decoded?['data']?['items'];
    if (items is! List) return const CmsListing();
    final videos = <CmsVideo>[];
    for (final item in items) {
      if (item is! Map) continue;
      final vid = (item['video_id'] ?? '').toString().trim();
      final name = (item['name'] ?? '').toString().trim();
      final img = (item['image'] ?? '').toString().trim();
      final dur = (item['duration_string'] ?? '').toString().trim();
      if (vid.isEmpty || name.isEmpty) continue;
      videos.add(
        CmsVideo(
          id: vid,
          title: name,
          poster: img,
          remarks: dur,
          lines: [
            CmsLine(
              name: '启蒙直连',
              episodes: [
                CmsEpisode(
                  name: name,
                  url: 'https://www.tuxiaobei.com/play/$vid',
                  headers: const {'User-Agent': _mobileSafariUa},
                ),
              ],
            ),
          ],
        ),
      );
    }
    return CmsListing(page: pg, pageCount: 20, videos: videos);
  }

  // ---------------------------------------------------------------------------
  // Youlai First Aid (`csp_FirstAidGuard`) implementation
  // ---------------------------------------------------------------------------

  static const List<CmsCategory> _firstAidCategories = [
    CmsCategory(id: '0', name: '急救技能'),
    CmsCategory(id: '1', name: '家庭生活'),
    CmsCategory(id: '2', name: '急危重症'),
    CmsCategory(id: '3', name: '常见损伤'),
    CmsCategory(id: '4', name: '动物致伤'),
  ];

  static Future<(List<CmsCategory>, CmsListing)> _fetchFirstAidHome(
    CspHttpTextFetcher fetchText,
  ) async {
    final listing = await _fetchFirstAidCategory('0', 1, fetchText);
    return (_firstAidCategories, listing);
  }

  static Future<CmsListing> _fetchFirstAidCategory(
    String categoryId,
    int page,
    CspHttpTextFetcher fetchText,
  ) async {
    final html = await fetchText(
      'https://m.youlai.cn/jijiu/',
      headers: const {'User-Agent': _mobileSafariUa},
    );
    final linkPattern = RegExp(
      r'''href\s*=\s*["']([^"']*jijiu/article/[^"']+\.html)["'][^>]*>([\s\S]*?)</a>''',
      caseSensitive: false,
    );
    final allVideos = <CmsVideo>[];
    final seenIds = <String>{};
    for (final m in linkPattern.allMatches(html)) {
      final href = (m.group(1) ?? '').trim();
      final inner = (m.group(2) ?? '')
          .replaceAll(RegExp(r'<[^>]*>'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (href.isEmpty || inner.isEmpty || !seenIds.add(href)) continue;
      final cleanHref = href.replaceFirst(RegExp(r'^/'), '');
      final fullUrl = href.startsWith('http') ? href : 'https://m.youlai.cn/$cleanHref';
      allVideos.add(
        CmsVideo(
          id: fullUrl,
          title: inner,
          remarks: '急救教学',
          description: '有来医生急救技能科普教学视频：$inner',
          lines: [
            CmsLine(
              name: '教学直连',
              episodes: [
                CmsEpisode(
                  name: inner,
                  url: fullUrl,
                  headers: const {'User-Agent': _mobileSafariUa},
                ),
              ],
            ),
          ],
        ),
      );
    }
    final catIdx = int.tryParse(categoryId.split('|').last) ?? 0;
    if (allVideos.length > 10 && catIdx > 0) {
      final chunk = (allVideos.length / 5).ceil().clamp(1, allVideos.length);
      final start = (catIdx * chunk).clamp(0, allVideos.length - 1);
      final end = (start + chunk).clamp(start + 1, allVideos.length);
      return CmsListing(page: 1, pageCount: 1, videos: allVideos.sublist(start, end));
    }
    return CmsListing(page: 1, pageCount: 1, videos: allVideos);
  }

  // ---------------------------------------------------------------------------
  // Huya & Douyu Live (`drpy2.min.js`) implementation
  // ---------------------------------------------------------------------------

  static const List<CmsCategory> _huyaCategories = [
    CmsCategory(id: '2135', name: '一起看'),
    CmsCategory(id: '1663', name: '星秀'),
    CmsCategory(id: '2165', name: '户外'),
    CmsCategory(id: '2633', name: '二次元'),
    CmsCategory(id: '1', name: '英雄联盟'),
    CmsCategory(id: '2336', name: '王者荣耀'),
  ];

  static Future<(List<CmsCategory>, CmsListing)> _fetchHuyaHome(
    CspHttpTextFetcher fetchText,
  ) async {
    final listing = await _fetchHuyaCategory('2135', 1, fetchText);
    return (_huyaCategories, listing);
  }

  static Future<CmsListing> _fetchHuyaCategory(
    String categoryId,
    int page,
    CspHttpTextFetcher fetchText,
  ) async {
    final gameId = categoryId.isEmpty ? '2135' : categoryId;
    final pg = page < 1 ? 1 : page;
    final raw = await fetchText(
      'https://www.huya.com/cache.php?m=LiveList&do=getLiveListByPage&gameId=$gameId&tagAll=0&page=$pg',
      headers: const {'User-Agent': _desktopSafariUa},
    );
    final decoded = jsonDecode(raw);
    final datas = decoded?['data']?['datas'];
    final totalPage = (decoded?['data']?['totalPage'] as num?)?.toInt() ?? 1;
    if (datas is! List) return const CmsListing();
    final videos = <CmsVideo>[];
    for (final item in datas) {
      if (item is! Map) continue;
      final roomId = (item['profileRoom'] ?? '').toString().trim();
      final title = (item['introduction'] ?? item['roomName'] ?? '').toString().trim();
      final pic = (item['screenshot'] ?? '').toString().trim();
      final nick = (item['nick'] ?? '').toString().trim();
      if (roomId.isEmpty || title.isEmpty) continue;
      videos.add(
        CmsVideo(
          id: roomId,
          title: title,
          poster: pic,
          remarks: nick,
          actor: nick,
        ),
      );
    }
    return CmsListing(page: pg, pageCount: totalPage < 1 ? 1 : totalPage, videos: videos);
  }

  static Future<CmsVideo> _fetchHuyaDetail(
    CmsVideo fallback,
    CspHttpTextFetcher fetchText,
  ) async {
    final roomId = fallback.id.split('/').last.trim();
    try {
      final raw = await fetchText(
        'https://mp.huya.com/cache.php?m=Live&do=profileRoom&roomid=$roomId',
        headers: const {'User-Agent': _mobileSafariUa},
      );
      final decoded = jsonDecode(raw);
      final hlsList = decoded?['data']?['stream']?['hls']?['multiLine'];
      final lines = <CmsLine>[];
      if (hlsList is List) {
        for (int i = 0; i < hlsList.length; i++) {
          final item = hlsList[i];
          if (item is! Map) continue;
          final url = (item['url'] ?? '').toString().trim();
          if (url.isNotEmpty) {
            lines.add(
              CmsLine(
                name: '直播线路 ${i + 1}',
                episodes: [
                  CmsEpisode(
                    name: '高清直播',
                    url: url,
                    headers: const {'User-Agent': _mobileSafariUa},
                  ),
                ],
              ),
            );
          }
        }
      }
      if (lines.isNotEmpty) {
        return CmsVideo(
          id: fallback.id,
          title: fallback.title,
          poster: fallback.poster,
          remarks: fallback.remarks,
          actor: fallback.actor,
          description: fallback.description.isEmpty ? '虎牙实时直播间：$roomId' : fallback.description,
          lines: lines,
        );
      }
    } catch (_) {}
    return fallback;
  }

  static const List<CmsCategory> _douyuCategories = [
    CmsCategory(id: 'yqk', name: '一起看'),
    CmsCategory(id: 'ip', name: '原创IP'),
    CmsCategory(id: 'ecy', name: '二次元'),
    CmsCategory(id: 'music', name: '音乐'),
    CmsCategory(id: 'HW', name: '户外'),
    CmsCategory(id: 'LOL', name: '英雄联盟'),
    CmsCategory(id: 'wzry', name: '王者荣耀'),
  ];

  static Future<(List<CmsCategory>, CmsListing)> _fetchDouyuHome(
    CspHttpTextFetcher fetchText,
  ) async {
    final listing = await _fetchDouyuCategory('yqk', 1, fetchText);
    return (_douyuCategories, listing);
  }

  static Future<CmsListing> _fetchDouyuCategory(
    String categoryId,
    int page,
    CspHttpTextFetcher fetchText,
  ) async {
    final type = categoryId.isEmpty ? 'yqk' : categoryId;
    final pg = page < 1 ? 1 : page;
    final raw = await fetchText(
      'https://m.douyu.com/api/room/list?page=$pg&type=$type',
      headers: const {'User-Agent': _mobileSafariUa},
    );
    final decoded = jsonDecode(raw);
    final list = decoded?['data']?['list'];
    final pageCount = (decoded?['data']?['pageCount'] as num?)?.toInt() ?? 1;
    if (list is! List) return const CmsListing();
    final videos = <CmsVideo>[];
    for (final item in list) {
      if (item is! Map) continue;
      final rid = (item['rid'] ?? '').toString().trim();
      final name = (item['roomName'] ?? '').toString().trim();
      final pic = (item['roomSrc'] ?? '').toString().trim();
      final nick = (item['nickname'] ?? '').toString().trim();
      if (rid.isEmpty || name.isEmpty) continue;
      videos.add(
        CmsVideo(
          id: 'msearch:$name',
          title: name,
          poster: pic,
          remarks: nick,
          actor: nick,
        ),
      );
    }
    return CmsListing(page: pg, pageCount: pageCount < 1 ? 1 : pageCount, videos: videos);
  }

  // ---------------------------------------------------------------------------
  // Bilibili (`csp_BiliGuard`) implementation
  // ---------------------------------------------------------------------------

  static List<CmsCategory> _defaultBiliCategoriesForSite(CmsSite site) {
    final name = site.name;
    if (name.contains('MV') || name.contains('音乐')) {
      return const [
        CmsCategory(id: '华语MV超清', name: '华语MV'),
        CmsCategory(id: '抖音热歌MV', name: '抖音热歌'),
        CmsCategory(id: '经典老歌MV', name: '经典老歌'),
        CmsCategory(id: '粤语金曲MV', name: '粤语金曲'),
        CmsCategory(id: '无损音乐现场', name: '音乐现场'),
      ];
    }
    if (name.contains('演唱会')) {
      return const [
        CmsCategory(id: '演唱会超清', name: '演唱会精选'),
        CmsCategory(id: '粤语歌曲超清', name: '粤语现场'),
        CmsCategory(id: '经典老歌超清', name: '经典老歌'),
        CmsCategory(id: '音乐节现场', name: '音乐节'),
      ];
    }
    if (name.contains('有声') || name.contains('小说') || name.contains('听书')) {
      return const [
        CmsCategory(id: '有声小说全集', name: '热门有声'),
        CmsCategory(id: '悬疑推理有声小说', name: '悬疑推理'),
        CmsCategory(id: '仙侠玄幻有声小说', name: '仙侠玄幻'),
        CmsCategory(id: '历史评书全集', name: '历史评书'),
      ];
    }
    if (name.contains('看球') || name.contains('回放') || name.contains('球迷') || name.contains('体育')) {
      return const [
        CmsCategory(id: 'NBA全场回放超清', name: '篮球回放'),
        CmsCategory(id: '欧冠比赛集锦超清', name: '欧冠集锦'),
        CmsCategory(id: '英超全场集锦', name: '英超集锦'),
        CmsCategory(id: '天下足球超清', name: '足球专题'),
      ];
    }
    if (name.contains('少儿')) {
      return const [
        CmsCategory(id: '儿童早教', name: '儿童早教'),
        CmsCategory(id: '儿童启蒙故事', name: '启蒙故事'),
        CmsCategory(id: '儿童英语启蒙', name: '英语启蒙'),
        CmsCategory(id: '儿童科普动画', name: '科普动画'),
      ];
    }
    if (name.contains('小学')) {
      return const [
        CmsCategory(id: '小学语文同步课堂', name: '小学语文'),
        CmsCategory(id: '小学数学同步课堂', name: '小学数学'),
        CmsCategory(id: '小学英语同步课堂', name: '小学英语'),
      ];
    }
    if (name.contains('初中')) {
      return const [
        CmsCategory(id: '初中语文同步课堂', name: '初中语文'),
        CmsCategory(id: '初中数学同步课堂', name: '初中数学'),
        CmsCategory(id: '初中英语同步课堂', name: '初中英语'),
        CmsCategory(id: '初中物理同步课堂', name: '初中物理'),
      ];
    }
    if (name.contains('高中')) {
      return const [
        CmsCategory(id: '高中语文同步课堂', name: '高中语文'),
        CmsCategory(id: '高中数学同步课堂', name: '高中数学'),
        CmsCategory(id: '高中英语同步课堂', name: '高中英语'),
        CmsCategory(id: '高中物理同步课堂', name: '高中物理'),
      ];
    }
    return const [
      CmsCategory(id: '纪录片超清', name: '纪录片'),
      CmsCategory(id: '一口气看完动漫', name: '动漫合集'),
      CmsCategory(id: '电影解说超清', name: '影视解说'),
      CmsCategory(id: '美食纪录片', name: '美食探索'),
    ];
  }

  static Future<(List<CmsCategory>, CmsListing)> _fetchBiliHome(
    CmsSite site,
    CspHttpTextFetcher fetchText,
  ) async {
    var categories = <CmsCategory>[];
    if (site.ext.trim().startsWith('{')) {
      try {
        final extMap = jsonDecode(site.ext);
        if (extMap is Map && extMap['json'] is String) {
          final jsonUrl = (extMap['json'] as String).trim();
          if (jsonUrl.startsWith('http')) {
            final raw = await fetchText(jsonUrl);
            categories = CmsParser.parseCategories(raw)
                .where((c) => c.id != 'peizhi' && !c.name.contains('配置'))
                .toList(growable: false);
          }
        }
      } catch (_) {}
    }
    if (categories.isEmpty) {
      categories = _defaultBiliCategoriesForSite(site);
    }
    final firstKeyword = categories.first.id;
    final listing = await _fetchBiliSearch(firstKeyword, 1, fetchText);
    return (categories, listing);
  }

  static Future<CmsListing> _fetchBiliSearch(
    String keyword,
    int page,
    CspHttpTextFetcher fetchText,
  ) async {
    final pg = page < 1 ? 1 : page;
    try {
      final encoded = Uri.encodeQueryComponent(keyword);
      final raw = await fetchText(
        'https://api.bilibili.com/x/web-interface/search/type?search_type=video&keyword=$encoded&page=$pg',
        headers: const {
          'User-Agent': _desktopSafariUa,
          'Referer': 'https://www.bilibili.com/',
          'Cookie': 'buvid3=MARCOMOVIE-APPLE-CLIENT-BUVID3-INFOC;',
        },
      );
      final decoded = jsonDecode(raw);
      final results = decoded?['data']?['result'];
      final numPages = (decoded?['data']?['numPages'] as num?)?.toInt() ?? 1;
      if (results is List && results.isNotEmpty) {
        final videos = <CmsVideo>[];
        for (final item in results) {
          if (item is! Map) continue;
          final bvid = (item['bvid'] ?? '').toString().trim();
          final rawTitle = (item['title'] ?? '').toString();
          final title = rawTitle
              .replaceAll(RegExp(r'<[^>]*>'), '')
              .replaceAll('&quot;', '"')
              .replaceAll('&amp;', '&')
              .trim();
          var pic = (item['pic'] ?? '').toString().trim();
          if (pic.startsWith('//')) pic = 'https:$pic';
          final duration = (item['duration'] ?? '').toString().trim();
          final author = (item['author'] ?? '').toString().trim();
          final desc = (item['description'] ?? '').toString().trim();
          if (bvid.isEmpty || title.isEmpty) continue;
          videos.add(
            CmsVideo(
              id: bvid,
              title: title,
              poster: pic,
              remarks: duration,
              actor: author,
              description: desc,
            ),
          );
        }
        if (videos.isNotEmpty) {
          return CmsListing(page: pg, pageCount: numPages < 1 ? 1 : numPages, videos: videos);
        }
      }
    } catch (_) {}
    // Fallback to VOD pool search if Bilibili search is rate-limited
    return _fetchConfiguredSearch(
      const CmsSite(key: 'bili', name: 'Bili', type: 3, api: 'csp_BiliGuard'),
      keyword,
      pg,
      fetchText,
    );
  }

  static Future<CmsVideo> _fetchBiliDetail(
    CmsVideo fallback,
    CspHttpTextFetcher fetchText,
  ) async {
    try {
      final raw = await fetchText(
        'https://api.bilibili.com/x/web-interface/view?bvid=${fallback.id}',
        headers: const {
          'User-Agent': _desktopSafariUa,
          'Referer': 'https://www.bilibili.com/',
          'Cookie': 'buvid3=MARCOMOVIE-APPLE-CLIENT-BUVID3-INFOC;',
        },
      );
      final decoded = jsonDecode(raw);
      final data = decoded?['data'];
      if (data is Map) {
        final pages = data['pages'];
        final episodes = <CmsEpisode>[];
        if (pages is List) {
          for (final p in pages) {
            if (p is! Map) continue;
            final cid = (p['cid'] ?? '').toString().trim();
            final part = (p['part'] ?? '').toString().trim();
            if (cid.isEmpty) continue;
            episodes.add(
              CmsEpisode(
                name: part.isEmpty ? '第 ${episodes.length + 1} P' : part,
                url:
                    'https://api.bilibili.com/x/player/playurl?bvid=${fallback.id}&cid=$cid&qn=64&fnval=1&platform=html5&high_quality=1',
                headers: const {
                  'User-Agent': _desktopSafariUa,
                  'Referer': 'https://www.bilibili.com/',
                },
              ),
            );
          }
        }
        if (episodes.isNotEmpty) {
          var pic = (data['pic'] ?? fallback.poster).toString().trim();
          if (pic.startsWith('//')) pic = 'https:$pic';
          return CmsVideo(
            id: fallback.id,
            title: (data['title'] ?? fallback.title).toString().trim(),
            poster: pic,
            remarks: fallback.remarks,
            actor: (data['owner']?['name'] ?? fallback.actor).toString().trim(),
            description: (data['desc'] ?? fallback.description).toString().trim(),
            lines: [
              CmsLine(name: '哔哩直连', episodes: episodes),
            ],
          );
        }
      }
    } catch (_) {}
    return fallback;
  }

  // ---------------------------------------------------------------------------
  // User-configured MacCMS/App endpoints
  // ---------------------------------------------------------------------------

  /// Backend API that served the categories for each site: category IDs are
  /// backend-specific, so category
  /// queries must go to the same backend the home page came from.
  static final Map<String, String> _homeBackendBySite = {};

  static String _backendKey(CmsSite site) => jsonEncode([
    site.subscriptionId, site.sourceKey, site.isEffectivelyPrivate,
    site.api, site.ext,
  ]);

  static List<({String name, String api})> _requireBackends(CmsSite site) {
    final backends = backendsForSite(site);
    if (backends.isEmpty) {
      throw FormatException(site.unsupportedReason);
    }
    return backends;
  }

  static bool _isAppV2Endpoint(String api) {
    final lower = api.toLowerCase();
    return lower.contains('api.php/app') || lower.contains('xgapp.php');
  }

  static Uri _configuredUri(String api, Map<String, String> parameters,
      {String appPath = ''}) {
    final base = Uri.parse(api);
    final path = appPath.isEmpty ? base.path
        : '${base.path.endsWith('/') ? base.path : '${base.path}/'}$appPath';
    return base.replace(path: path,
        queryParameters: {...base.queryParameters, ...parameters});
  }

  static Future<(List<CmsCategory>, CmsListing)> _fetchConfiguredHome(
    CmsSite site,
    CspHttpTextFetcher fetchText,
  ) async {
    final backends = _requireBackends(site);
    for (final backend in backends.take(4)) {
      try {
        final isAppV2 = _isAppV2Endpoint(backend.api);
        final listUri = isAppV2
            ? _configuredUri(backend.api, {}, appPath: 'nav')
            : _configuredUri(backend.api, {'ac': 'list'});
        final detailUri = isAppV2
            ? _configuredUri(backend.api, {'pg': '1'}, appPath: 'video')
            : _configuredUri(backend.api, {'ac': 'detail'});
        final results = await Future.wait([
          fetchText(listUri.toString(), headers: site.headers),
          fetchText(detailUri.toString(), headers: site.headers),
        ]);
        final categories = CmsParser.parseCategories(results[0]);
        final listing = CmsParser.parseListing(results[1]);
        if (categories.isNotEmpty || listing.videos.isNotEmpty) {
          _homeBackendBySite[_backendKey(site)] = backend.api;
          return (categories, listing);
        }
      } catch (_) {}
    }
    throw Exception('无法连接片源服务，请稍后重试');
  }

  static Future<CmsListing> _fetchConfiguredCategory(
    CmsSite site,
    String categoryId,
    int page,
    CspHttpTextFetcher fetchText, [
    List<String> childIds = const [],
  ]) async {
    final all = _requireBackends(site);
    final bound = _homeBackendBySite[_backendKey(site)];
    final backends = [
      if (bound != null) ...all.where((b) => b.api == bound),
      ...all.where((b) => b.api != bound),
    ];
    Future<CmsListing> query(String api, String id) async {
      final pgStr = (page < 1 ? 1 : page).toString();
      if (_isAppV2Endpoint(api)) {
        final uri = _configuredUri(api,
          {'pg': pgStr, if (id.isNotEmpty) 'tid': id}, appPath: 'video',
        );
        return CmsParser.parseListing(await fetchText(uri.toString(), headers: site.headers));
      }
      final params = <String, String>{
        'ac': 'detail',
        'pg': pgStr,
      };
      if (id.isNotEmpty) {
        params['t'] = id;
      }
      final uri = _configuredUri(api, params);
      return CmsParser.parseListing(await fetchText(uri.toString(), headers: site.headers));
    }
    for (final backend in backends.take(3)) {
      try {
        final listing = await query(backend.api, categoryId);
        if (listing.videos.isNotEmpty) return listing;
        if (childIds.isNotEmpty) {
          // Parent category is empty on this backend: merge its leaf categories.
          final children = await Future.wait(
            childIds.take(8).map(
                  (id) => query(backend.api, id)
                      .catchError((_) => const CmsListing()),
                ),
          );
          final merged = mergeChildListings(children, page);
          if (merged.videos.isNotEmpty) return merged;
        }
      } catch (_) {}
      // Category IDs only match the backend that produced them.
      if (bound != null) break;
    }
    return const CmsListing();
  }

  static Future<CmsListing> _fetchConfiguredSearch(
    CmsSite site,
    String keyword,
    int page,
    CspHttpTextFetcher fetchText,
  ) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) return const CmsListing();
    final backends = _requireBackends(site);
    for (final backend in backends.take(3)) {
      try {
        final pgStr = (page < 1 ? 1 : page).toString();
        final isAppV2 = _isAppV2Endpoint(backend.api);
        final uri = isAppV2
            ? _configuredUri(backend.api, {'text': trimmed, 'pg': pgStr}, appPath: 'search')
            : _configuredUri(backend.api, {
                  'ac': 'detail',
                  'wd': trimmed,
                  'pg': pgStr,
                },
              );
        final raw = await fetchText(uri.toString(), headers: site.headers);
        final listing = CmsParser.parseListing(raw);
        if (listing.videos.isNotEmpty) return listing;
      } catch (_) {}
    }
    return const CmsListing();
  }

  /// Listing redirects may contain a catalogue ID before the actual title.
  static String searchTitleForVideo(CmsVideo video) {
    if (video.id.startsWith('msearch:')) {
      final afterPrefix = video.id.substring('msearch:'.length).trim();
      for (final part in afterPrefix.split('###')) {
        final candidate = part.trim();
        if (candidate.isEmpty || RegExp(r'^\d+$').hasMatch(candidate)) continue;
        final scheme = Uri.tryParse(candidate)?.scheme.toLowerCase();
        if (scheme == 'http' || scheme == 'https') continue;
        return candidate;
      }
    }
    // Numeric titles such as 1917 remain valid when supplied as vod_name.
    return video.title.trim();
  }

  static int _rankDirectLineQuality(CmsLine line) {
    final lower = line.name.toLowerCase();
    int score = 0;
    if (lower.contains('4k') || lower.contains('2160') || lower.contains('uhd')) {
      score += 100;
    }
    if (lower.contains('原画') || lower.contains('蓝光') || lower.contains('高码') || lower.contains('hdr')) {
      score += 60;
    }
    if (lower.contains('2k') || lower.contains('1440')) {
      score += 40;
    }
    if (lower.contains('超清') || lower.contains('1080')) {
      score += 20;
    }
    for (final ep in line.episodes.take(3)) {
      final epLower = '${ep.name} ${ep.url}'.toLowerCase();
      if (epLower.contains('4k') || epLower.contains('2160')) score += 50;
      if (epLower.contains('.mp4') || epLower.contains('.mkv')) score += 15;
    }
    return score;
  }

  static List<CmsLine> _prioritizeDirectLinesFor4K(List<CmsLine> lines) {
    if (lines.length <= 1) return lines;
    final indexed = <(int, int, CmsLine)>[
      for (int i = 0; i < lines.length; i++)
        (i, _rankDirectLineQuality(lines[i]), lines[i]),
    ];
    indexed.sort((a, b) {
      final cmp = b.$2.compareTo(a.$2);
      return cmp != 0 ? cmp : a.$1.compareTo(b.$1);
    });
    return [for (final item in indexed) item.$3];
  }

  /// Ranks available lines while preserving their actual source and quality labels.
  /// The legacy method name is retained for existing callers.
  static List<CmsLine> buildNetdisk4KLines(
    List<CmsLine> directLines, {
    String siteHint = '',
    Set<String> excludeNames = const {},
  }) {
    return _prioritizeDirectLinesFor4K(directLines)
        .where((line) => line.episodes.isNotEmpty && !excludeNames.contains(line.name))
        .toList(growable: false);
  }

}
