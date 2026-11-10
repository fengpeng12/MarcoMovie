import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'cms_parser.dart';
import 'quark_account.dart';
import 'trailer_source.dart';
import 'models.dart';

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
  static const String _quarkPcUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch';

  /// Multi-source MacCMS v10 JSON endpoints used as cross-platform portable
  /// backends for TVBox `csp_*` VOD spiders and Douban / search resolution on iOS.
  static const List<({String name, String api})> vodPool = [
    (name: '爱坤', api: 'https://ikunzyapi.com/api.php/provide/vod/'),
    (name: '360', api: 'https://360zy.com/api.php/provide/vod/'),
    (name: '电影天堂', api: 'http://caiji.dyttzyapi.com/api.php/provide/vod/'),
    (name: '极速', api: 'https://jszyapi.com/api.php/provide/vod/'),
    (name: '豪华', api: 'https://hhzyapi.com/api.php/provide/vod/'),
    (name: '最大', api: 'https://zuidazy.me/api.php/provide/vod/'),
    (name: '魔都动漫', api: 'https://caiji.moduapi.cc/api.php/provide/vod/'),
    (name: '速播', api: 'https://subocaiji.com/api.php/provide/vod/'),
    (name: '新浪', api: 'https://api.xinlangapi.com/xinlangapi.php/provide/vod/'),
    (name: '如意', api: 'https://cj.rycjapi.com/api.php/provide/vod/'),
    (name: '非凡', api: 'http://cj.ffzyapi.com/api.php/provide/vod/'),
    (name: '量子', api: 'https://cj.lziapi.com/api.php/provide/vod/'),
    (name: '暴风', api: 'https://bfzyapi.com/api.php/provide/vod/'),
    (name: '天涯', api: 'https://tyyszy.com/api.php/provide/vod/'),
    (name: '索尼', api: 'https://suoniapi.com/api.php/provide/vod/'),
    (name: '红牛', api: 'https://www.hongniuzy2.com/api.php/provide/vod/'),
  ];

  static const int _primaryVodPoolCount = 10;

  static bool isDeadOrStubStreamUrl(String rawUrl) {
    final lower = rawUrl.trim().toLowerCase();
    return lower.contains('feifei-play.com') ||
        lower.contains('ffzy-plays.com') ||
        lower.contains('ffzy-online') ||
        lower.contains('lzcdn') ||
        lower.contains('tyyszywvod.com') ||
        lower.contains('bvvvvvvvvv1f.com') ||
        lower.contains('bfvvs.com');
  }

  static final RegExp _supportedVodCspPattern = RegExp(
    r'^csp_(?!(?:local|unknown$|unknownguard$|test|guard$|live$|sixv|push|mydrive|mypan|panconfig|config$|configcenter$|fakeai115))[a-z0-9_]+$',
    caseSensitive: false,
  );

  static bool canHandleSite(CmsSite site) {
    final lowerApi = site.api.trim().toLowerCase();
    if (lowerApi.startsWith('csp_')) return true;
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

  static bool hasAdapter(CmsSite site) => (guardAdapterFor(site) != null && site.pluginReference.trim().isNotEmpty) || site.isDrpySource || site.isRemoteScriptSource || site.isJavaScriptSource || site.isPythonSource || TrailerSource.matches(site) || hasBuiltinAdapter(site);

  static bool hasBuiltinAdapter(CmsSite site) =>
      !site.api.startsWith('csp_Local') && (isDoubanSite(site) || isMyDriveSite(site) || isBiliSite(site) ||
      isTuxiaobeiSite(site) || isFirstAidSite(site) || isHuyaSite(site) ||
      isDouyuSite(site) || backendsForSite(site).isNotEmpty);

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
        n.contains('请勿付费') ||
        n.contains('点击更新');
  }

  static bool isDoubanSite(CmsSite site) {
    final lowerApi = site.api.toLowerCase();
    final lowerName = site.name.toLowerCase();
    return lowerApi.contains('doudou') ||
        lowerApi.contains('douban') ||
        lowerName.contains('豆豆') ||
        lowerName.contains('豆瓣');
  }

  static bool isMyDriveSite(CmsSite site) {
    final lowerApi = site.api.toLowerCase();
    final lowerName = site.name.toLowerCase();
    final lowerKey = site.key.toLowerCase();
    final hasHttpExt = site.ext.toLowerCase().contains('http');
    return lowerApi.contains('mydrive') ||
        lowerApi.contains('mypan') ||
        lowerApi.contains('panconfig') ||
        lowerApi.contains('panwebshare') ||
        lowerApi == 'csp_config' ||
        lowerApi == 'csp_configcenter' ||
        lowerApi.startsWith('csp_push') ||
        lowerApi.startsWith('csp_fakeai115') ||
        (!hasHttpExt &&
            (lowerApi.startsWith('csp_alist') ||
                lowerApi.startsWith('csp_webdav') ||
                lowerApi.startsWith('csp_emby') ||
                lowerApi.startsWith('csp_diyvod') ||
                lowerApi.startsWith('csp_xpath'))) ||
        lowerKey.contains('mydrive') ||
        lowerKey.contains('mypan') ||
        lowerKey.contains('wexconfig') ||
        lowerKey == 'config' ||
        lowerKey == 'push_agent' ||
        lowerName.contains('我的云盘') ||
        lowerName.contains('我的网盘') ||
        lowerName.contains('我的┃网盘') ||
        lowerName.contains('云盘配置') ||
        lowerName.contains('网盘配置') ||
        lowerName.contains('配置中心') ||
        lowerName.contains('配置┃中心') ||
        lowerName.contains('请勿信视频中任何广告') ||
        (lowerName.contains('请先点击') && lowerName.contains('配置'));
  }

  static bool isNetdiskSite(CmsSite site) {
    final lowerApi = site.api.toLowerCase();
    final lowerKey = site.key.toLowerCase();
    final lowerName = site.name.toLowerCase();
    return isMyDriveSite(site) ||
        lowerApi.contains('wogg') ||
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
        lowerApi.startsWith('csp_ainew') ||
        lowerApi.startsWith('csp_aiqw') ||
        lowerKey.contains('wogg') ||
        lowerKey.contains('seedhub') ||
        lowerKey.contains('pansou') ||
        lowerKey.contains('yiso') ||
        lowerKey.contains('panta') ||
        lowerKey.contains('kkss') ||
        lowerKey.contains('ucss') ||
        lowerKey.contains('uuss') ||
        lowerKey.contains('quark') ||
        lowerKey.contains('baidu') ||
        lowerKey.contains('alipan') ||
        lowerName.contains('玩偶') ||
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
        lowerName.contains('云盘') ||
        lowerName.contains('4k');
  }

  static bool isBiliSite(CmsSite site) {
    final lowerApi = site.api.toLowerCase();
    final lowerKey = site.key.toLowerCase();
    return lowerApi.contains('bili') ||
        lowerKey.contains('bili') ||
        lowerApi.startsWith('csp_music') ||
        lowerApi.startsWith('csp_tingshu') ||
        lowerApi.startsWith('csp_yueting') ||
        lowerApi.startsWith('csp_book') ||
        lowerApi.startsWith('csp_kanqiu') ||
        lowerApi.startsWith('csp_doubao') ||
        lowerApi.startsWith('csp_livegz') ||
        lowerApi.startsWith('csp_sport');
  }

  static bool isTuxiaobeiSite(CmsSite site) {
    final lowerApi = site.api.toLowerCase();
    final lowerKey = site.key.toLowerCase();
    final lowerName = site.name.toLowerCase();
    final lowerExt = site.ext.toLowerCase();
    return lowerApi.startsWith('csp_children') ||
        lowerKey.contains('兔小贝') ||
        lowerName.contains('儿童') ||
        lowerName.contains('儿歌') ||
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
    return lowerApi.startsWith('csp_alllive') ||
        lowerKey.contains('alllive') ||
        lowerName.contains('一直播') ||
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

  static List<({String name, String api})> _orderedVodPoolForSite(CmsSite site) {
    if (vodPool.isEmpty) return const [];
    final lowerApi = site.api.toLowerCase();
    final lowerKey = site.key.toLowerCase();
    final name = site.name;
    final activeCount = vodPool.length < _primaryVodPoolCount
        ? vodPool.length
        : _primaryVodPoolCount;
    int offset;
    if (name.contains('动漫') || lowerKey.contains('gugu') || lowerApi.contains('dm84') || lowerApi.contains('anime')) {
      offset = 6; // 魔都动漫
    } else if (lowerApi.contains('wogg') || name.contains('玩偶')) {
      offset = 0; // 爱坤
    } else if (lowerApi.contains('seedhub') || name.contains('聚剧') || name.contains('四盘')) {
      offset = 1; // 360
    } else if (lowerApi.contains('newcz') || name.contains('厂长')) {
      offset = 2; // 电影天堂
    } else if (lowerApi.contains('hmys') || name.contains('海绵')) {
      offset = 9; // 如意
    } else if (lowerApi.contains('libvio') || name.contains('立播')) {
      offset = 4; // 豪华
    } else if (lowerApi.contains('appgz') || name.contains('瓜子')) {
      offset = 0; // 爱坤
    } else if (lowerApi.contains('nmys') || name.contains('糯米')) {
      offset = 7; // 速播
    } else if (lowerApi.contains('jpys') || name.contains('文采') || name.contains('文才')) {
      offset = 3; // 极速
    } else if (lowerApi.contains('apptt') || name.contains('热播')) {
      offset = 5; // 最大
    } else if (lowerApi.contains('app99') || name.contains('茉莉')) {
      offset = 1; // 360
    } else if (lowerApi.contains('appsx') || name.contains('剧圈')) {
      offset = 4; // 豪华
    } else if (lowerApi.contains('jpj') || name.contains('荐片') || name.contains('贱片')) {
      offset = 3; // 极速
    } else if (lowerApi.contains('aidj') || lowerApi.contains('manju') || lowerApi.contains('duanju') || name.contains('短漫') || name.contains('漫短') || name.contains('漫剧') || name.contains('短剧')) {
      offset = 8; // 新浪
    } else if (lowerApi.contains('bttwoo') || name.contains('比特') || name.contains('光影')) {
      offset = 2; // 电影天堂
    } else if (lowerApi.contains('t4') || name.contains('天微')) {
      offset = 8; // 新浪
    } else if (lowerApi.contains('fy') || name.contains('风云')) {
      offset = 1; // 360
    } else if (lowerApi.contains('auete') || name.contains('奥特')) {
      offset = 5; // 最大
    } else {
      var hash = 0;
      for (final code in '${site.key}:${site.api}'.codeUnits) {
        hash = (hash * 31 + code) & 0x7fffffff;
      }
      offset = hash % activeCount;
    }
    final safeOffset = offset % activeCount;
    final primary = vodPool.sublist(0, activeCount);
    final secondary = vodPool.sublist(activeCount);
    return [
      ...primary.sublist(safeOffset),
      ...primary.sublist(0, safeOffset),
      ...secondary,
    ];
  }

  /// Extracts user-configured HTTP/HTTPS endpoints from `site.api` or `site.ext`,
  /// and appends cross-platform MacCMS VOD pool backends for known TVBox `csp_*` VOD spiders.
  static List<({String name, String api})> backendsForSite(CmsSite site) {
    // Non-MacCMS HTML scrapers / netdisk search / Guard adapters are handled by their own adapters.
    if (guardAdapterFor(site) != null ||
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
    final trimmedApi = site.api.trim();
    final isCspSpider = trimmedApi.toLowerCase().startsWith('csp_');
    final isHtmlSiteExt = RegExp(
      r'^csp_(?:libvio|newcz|sixv|s_zps|wogg|seedhub|ypanso|bpanso|kkss|uuss)(?:guard)?$',
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
      if (isCspSpider &&
          !lower.contains('api.php') &&
          !lower.contains('provide/vod') &&
          !lower.contains('/api') &&
          !lower.contains('cms.')) {
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
    if (vodPool.isNotEmpty &&
        (endpoints.isNotEmpty || _supportedVodCspPattern.hasMatch(trimmedApi))) {
      for (final b in _orderedVodPoolForSite(site)) {
        if (seen.add(b.api)) endpoints.add(b);
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
    return _fetchVodPoolHome(site, fetchText);
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
    return _fetchVodPoolCategory(site, categoryId, page, fetchText, childIds);
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
      return _fetchVodPoolSearch(site, keyword, page, fetchText);
    }
    if (isBiliSite(site)) {
      return _fetchBiliSearch(keyword, page, fetchText);
    }
    if (isTuxiaobeiSite(site)) {
      final (_, homeListing) = await _fetchTuxiaobeiHome(fetchText);
      final filtered = homeListing.videos
          .where((v) => v.title.toLowerCase().contains(keyword.toLowerCase()))
          .toList(growable: false);
      return CmsListing(page: 1, pageCount: 1, videos: filtered);
    }
    if (isFirstAidSite(site)) {
      final (_, homeListing) = await _fetchFirstAidHome(fetchText);
      final filtered = homeListing.videos
          .where((v) => v.title.toLowerCase().contains(keyword.toLowerCase()))
          .toList(growable: false);
      return CmsListing(page: 1, pageCount: 1, videos: filtered);
    }
    return _fetchVodPoolSearch(site, keyword, page, fetchText);
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

    final wantNetdiskLines =
        isDoubanSite(site) || isNetdiskSite(site) || fallback.id.startsWith('msearch:');

    // Standard VOD detail or cross-source resolution (for Douban / msearch / multi-line)
    if (!isDoubanSite(site) && !fallback.id.startsWith('msearch:')) {
      final fallbackDirectLines = [
        for (final l in fallback.lines)
          if (l.episodes.any((e) => e.isDirectPlayable))
            CmsLine(
              name: l.name,
              episodes: l.episodes.where((e) => e.isDirectPlayable).toList(growable: false),
            ),
      ];
      CmsVideo? matchedDetail;
      if (fallbackDirectLines.isNotEmpty) {
        matchedDetail = CmsVideo(
          id: fallback.id,
          title: fallback.title,
          poster: fallback.poster,
          remarks: fallback.remarks,
          year: fallback.year,
          area: fallback.area,
          actor: fallback.actor,
          description: fallback.description,
          tag: fallback.tag,
          lines: fallbackDirectLines,
        );
      } else {
        final directBackends = backendsForSite(site);
        final all = directBackends.isNotEmpty
            ? directBackends
            : (guardAdapterFor(site) != null ? _orderedVodPoolForSite(site) : const <({String name, String api})>[]);
        final bound = _homeBackendBySite[site.key];
        final backends = [
          if (bound != null) ...all.where((b) => b.api == bound),
          ...all.where((b) => b.api != bound),
        ];
        final normFallbackTitle = _normalizeTitleForMatch(fallback.title);
        for (final backend in backends.take(2)) {
          try {
            final isAppV2 = _isAppV2Endpoint(backend.api);
            final baseApi = backend.api.endsWith('/') ? backend.api : '${backend.api}/';
            final uri = isAppV2
                ? Uri.parse('${baseApi}video_detail').replace(queryParameters: {'id': fallback.id})
                : Uri.parse(backend.api).replace(queryParameters: {'ac': 'detail', 'ids': fallback.id});
            final raw = await fetchText(
              uri.toString(),
              headers: site.headers,
              requestTimeout: const Duration(seconds: 6),
            );
            final listing = CmsParser.parseListing(raw);
            if (listing.videos.isNotEmpty && listing.videos.first.lines.isNotEmpty) {
              final candidate = listing.videos.first;
              if (normFallbackTitle.isNotEmpty &&
                  candidate.title.trim().isNotEmpty &&
                  _normalizeTitleForMatch(candidate.title) != normFallbackTitle) {
                continue;
              }
              final directOnly = [
                for (final l in candidate.lines)
                  if (l.episodes.any((e) => e.isDirectPlayable))
                    CmsLine(
                      name: l.name,
                      episodes: l.episodes.where((e) => e.isDirectPlayable).toList(growable: false),
                    ),
              ];
              matchedDetail = CmsVideo(
                id: candidate.id.isEmpty ? fallback.id : candidate.id,
                title: candidate.title.isEmpty ? fallback.title : candidate.title,
                poster: CmsParser.isBrokenPosterUrl(candidate.poster) ? fallback.poster : candidate.poster,
                remarks: candidate.remarks.isEmpty ? fallback.remarks : candidate.remarks,
                year: candidate.year.isEmpty ? fallback.year : candidate.year,
                area: candidate.area.isEmpty ? fallback.area : candidate.area,
                actor: candidate.actor.isEmpty ? fallback.actor : candidate.actor,
                description: candidate.description.isEmpty ? fallback.description : candidate.description,
                tag: candidate.tag.isEmpty ? fallback.tag : candidate.tag,
                lines: directOnly.isNotEmpty ? directOnly : candidate.lines,
              );
              break;
            }
          } catch (_) {}
        }
      }
      if (matchedDetail != null) {
        final v = matchedDetail;
        final targetTitle = v.title.isEmpty ? fallback.title : v.title;
        final hasQuarkLogin = await _hasLoggedInQuarkCookie();
        if ((wantNetdiskLines || hasQuarkLogin) && targetTitle.trim().isNotEmpty) {
          final cross = await resolveCrossSourceVideo(
            v,
            targetTitle,
            fetchText,
            siteHint: site.name.isEmpty ? '夸父4K' : site.name,
          );
          if (cross.lines.isNotEmpty) return cross;
        }
        final extraLines = await resolveCrossSourceLines(
          targetTitle,
          fetchText,
          excludeLineNames: v.lines.map((l) => l.name).toSet(),
        );
        String validPoster = CmsParser.isBrokenPosterUrl(v.poster) ? fallback.poster : v.poster;
        if (CmsParser.isBrokenPosterUrl(validPoster) && targetTitle.trim().isNotEmpty) {
          final cross = await resolveCrossSourceVideo(fallback, targetTitle, fetchText);
          if (!CmsParser.isBrokenPosterUrl(cross.poster)) {
            validPoster = cross.poster;
          }
        }
        return CmsVideo(
          id: v.id,
          title: targetTitle,
          poster: validPoster,
          remarks: v.remarks,
          year: v.year,
          area: v.area,
          actor: v.actor,
          description: v.description,
          tag: v.tag,
          lines: [...v.lines, ...extraLines],
        );
      }
    }

    // Cross-source search by title (used by `豆豆┃片单`, `我的云盘`, and any card needing multi-source lines)
    final searchTitle = searchTitleForVideo(fallback);
    if (searchTitle.isNotEmpty) {
      final resolved = await resolveCrossSourceVideo(
        fallback,
        searchTitle,
        fetchText,
        siteHint: site.name,
      );
      if (resolved.lines.isNotEmpty) return resolved;
    }

    return fallback;
  }

  /// Resolves on-demand wrapper URLs (Tuxiaobei HTML, Youlai HTML, Bilibili playurl JSON, Huya room)
  /// into direct `.mp4` / `.m3u8` media stream URLs right before playback starts.
  static Future<CmsEpisode> resolveEpisodeForPlayback(
    CmsSite site,
    CmsEpisode episode,
    CspHttpTextFetcher fetchText,
  ) async {
    if (TrailerSource.matches(site)) return TrailerSource.resolve(episode, fetchText);
    final rawUrl = episode.url.trim();

    // 0. Real 4K Quark Share episode (`drive-pc.quark.cn/1/clouddrive/share/sharepage/save?...`)
    if (rawUrl.contains('drive-pc.quark.cn/1/clouddrive/share/sharepage/save')) {
      return _resolveQuarkShareEpisode(episode);
    }

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
    final doubanCat = switch (categoryId) {
      'quark' => 'hot_gaia',
      'uc' => 'tv_hot',
      'baidu' => 'rank_list_movie',
      'ali' => 'rank_list_tv',
      _ => 'tv_hot',
    };
    try {
      final doubanListing = await _fetchDoubanCategory(doubanCat, pg, fetchText);
      if (doubanListing.videos.isNotEmpty) {
        final badge = switch (categoryId) {
          'quark' => '夸父4K',
          'uc' => '优汐4K',
          'baidu' => '嘟嘟4K',
          'ali' => '阿狸4K',
          _ => '四盘4K',
        };
        for (final v in doubanListing.videos) {
          cards.add(
            CmsVideo(
              id: v.id,
              title: v.title,
              poster: v.poster,
              remarks: v.remarks.isEmpty ? badge : '$badge · ${v.remarks}',
              year: v.year,
              area: v.area,
              actor: v.actor,
              description: v.description,
            ),
          );
        }
        return CmsListing(
          page: pg,
          pageCount: doubanListing.pageCount,
          videos: cards,
        );
      }
    } catch (_) {}

    final vodListing = await _fetchVodPoolCategory(
      const CmsSite(key: 'mydrive', name: '我的云盘', type: 3, api: 'csp_MyDriveGuard'),
      '',
      pg,
      fetchText,
    );
    cards.addAll(vodListing.videos);
    return CmsListing(
      page: pg,
      pageCount: vodListing.pageCount,
      videos: cards,
    );
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
    return _fetchVodPoolHome(
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
    if (name.contains('跳舞') || name.contains('舞蹈')) {
      return const [
        CmsCategory(id: '广场舞教学超清', name: '广场舞教学'),
        CmsCategory(id: '健身操燃脂教学', name: '燃脂健身操'),
        CmsCategory(id: '古典舞教学完整版', name: '古典舞'),
        CmsCategory(id: '现代舞流行舞教学', name: '流行现代舞'),
      ];
    }
    if (name.contains('戏曲')) {
      return const [
        CmsCategory(id: '经典戏曲名段超清', name: '戏曲名段'),
        CmsCategory(id: '京剧经典全集超清', name: '京剧精选'),
        CmsCategory(id: '黄梅戏经典选段', name: '黄梅戏'),
        CmsCategory(id: '越剧豫剧经典全集', name: '越剧豫剧'),
      ];
    }
    if (name.contains('电台') || name.contains('蜻蜓')) {
      return const [
        CmsCategory(id: '深夜情感电台', name: '情感电台'),
        CmsCategory(id: '相声小品精选全集', name: '相声小品'),
        CmsCategory(id: '历史故事广播剧', name: '历史故事'),
        CmsCategory(id: '睡前故事助眠电台', name: '助眠电台'),
      ];
    }
    if (name.contains('MV') || name.contains('音乐') || name.contains('KTV') || name.contains('舞曲') || name.contains('歌曲')) {
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
    if (name.toUpperCase().contains('WWE')) {
      return const [
        CmsCategory(id: 'WWE经典比赛超清', name: 'WWE精选'),
        CmsCategory(id: 'WWE摔角狂热大赛', name: '摔角狂热'),
        CmsCategory(id: 'UFC格斗比赛集锦', name: '格斗集锦'),
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
    return _fetchVodPoolSearch(
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
  // MacCMS v10 VOD Pool & Cross-Source Resolution
  // ---------------------------------------------------------------------------

  /// Backend API that served the categories for each site: category IDs are
  /// backend-specific (e.g. 非凡 uses 1/2 while 暴风 uses 20/30), so category
  /// queries must go to the same backend the home page came from.
  static final Map<String, String> _homeBackendBySite = {};

  static bool _isAppV2Endpoint(String api) {
    final lower = api.toLowerCase();
    return lower.contains('api.php/app') || lower.contains('xgapp.php');
  }

  static Future<(List<CmsCategory>, CmsListing)> _fetchVodPoolHome(
    CmsSite site,
    CspHttpTextFetcher fetchText,
  ) async {
    final direct = backendsForSite(site);
    final backends = direct.isNotEmpty
        ? direct
        : (guardAdapterFor(site) != null ? _orderedVodPoolForSite(site) : const <({String name, String api})>[]);
    if (backends.isEmpty) {
      throw const FormatException('这个来源需要专用插件运行环境，当前设备没有可调用的接口。可切换到标准点播源，或在支持该扩展的设备上打开。');
    }
    for (final backend in backends.take(4)) {
      try {
        final isAppV2 = _isAppV2Endpoint(backend.api);
        final baseApi = backend.api.endsWith('/') ? backend.api : '${backend.api}/';
        final listUri = isAppV2
            ? Uri.parse('${baseApi}nav')
            : Uri.parse(backend.api).replace(queryParameters: {'ac': 'list'});
        final detailUri = isAppV2
            ? Uri.parse('${baseApi}video').replace(queryParameters: {'pg': '1'})
            : Uri.parse(backend.api).replace(queryParameters: {'ac': 'detail'});
        final results = await Future.wait([
          fetchText(
            listUri.toString(),
            headers: site.headers,
            requestTimeout: const Duration(seconds: 5),
          ),
          fetchText(
            detailUri.toString(),
            headers: site.headers,
            requestTimeout: const Duration(seconds: 5),
          ),
        ]);
        final categories = CmsParser.parseCategories(results[0]);
        final listing = CmsParser.parseListing(results[1]);
        if (categories.isNotEmpty || listing.videos.isNotEmpty) {
          _homeBackendBySite[site.key] = backend.api;
          return (categories, listing);
        }
      } catch (_) {}
    }
    throw Exception('无法连接片源服务，请稍后重试');
  }

  static Future<CmsListing> _fetchVodPoolCategory(
    CmsSite site,
    String categoryId,
    int page,
    CspHttpTextFetcher fetchText, [
    List<String> childIds = const [],
  ]) async {
    final direct = backendsForSite(site);
    final all = direct.isNotEmpty
        ? direct
        : (guardAdapterFor(site) != null ? _orderedVodPoolForSite(site) : const <({String name, String api})>[]);
    final bound = _homeBackendBySite[site.key];
    final backends = [
      if (bound != null) ...all.where((b) => b.api == bound),
      ...all.where((b) => b.api != bound),
    ];
    Future<CmsListing> query(String api, String id) async {
      final pgStr = (page < 1 ? 1 : page).toString();
      if (_isAppV2Endpoint(api)) {
        final baseApi = api.endsWith('/') ? api : '$api/';
        final uri = Uri.parse('${baseApi}video').replace(
          queryParameters: {'pg': pgStr, if (id.isNotEmpty) 'tid': id},
        );
        return CmsParser.parseListing(
          await fetchText(
            uri.toString(),
            headers: site.headers,
            requestTimeout: const Duration(seconds: 5),
          ),
        );
      }
      final params = <String, String>{
        'ac': 'detail',
        'pg': pgStr,
      };
      if (id.isNotEmpty) {
        params['t'] = id;
      }
      final uri = Uri.parse(api).replace(queryParameters: params);
      return CmsParser.parseListing(
        await fetchText(
          uri.toString(),
          headers: site.headers,
          requestTimeout: const Duration(seconds: 5),
        ),
      );
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

  static Future<CmsListing> _fetchVodPoolSearch(
    CmsSite site,
    String keyword,
    int page,
    CspHttpTextFetcher fetchText,
  ) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) return const CmsListing();
    final direct = backendsForSite(site);
    final backends = direct.isNotEmpty
        ? direct
        : (guardAdapterFor(site) != null ? _orderedVodPoolForSite(site) : const <({String name, String api})>[]);
    for (final backend in backends.take(3)) {
      try {
        final pgStr = (page < 1 ? 1 : page).toString();
        final isAppV2 = _isAppV2Endpoint(backend.api);
        final baseApi = backend.api.endsWith('/') ? backend.api : '${backend.api}/';
        final uri = isAppV2
            ? Uri.parse('${baseApi}search').replace(queryParameters: {'text': trimmed, 'pg': pgStr})
            : Uri.parse(backend.api).replace(
                queryParameters: {
                  'ac': 'detail',
                  'wd': trimmed,
                  'pg': pgStr,
                },
              );
        final raw = await fetchText(
          uri.toString(),
          headers: site.headers,
          requestTimeout: const Duration(seconds: 4),
        );
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

  static String _normalizeTitleForMatch(String raw) {
    var s = raw
        .replaceAll(RegExp(r'[\(（\[【].*?[\)）\]】]'), '')
        .replaceAll(RegExp(r'(?:19|20)\d{2}版?$'), '')
        .replaceAll(RegExp(r'[\s:：·\-_—!！?？,，.。]'), '')
        .toLowerCase()
        .trim();
    return s.isEmpty ? raw.trim().toLowerCase() : s;
  }

  static Future<CmsVideo> resolveCrossSourceVideo(
    CmsVideo fallback,
    String searchTitle,
    CspHttpTextFetcher fetchText, {
    String siteHint = '',
  }) async {
    final cleanTitle = searchTitle
        .replaceAll(RegExp(r'[\(（\[【].*?[\)）\]】]'), '')
        .trim();
    final strippedYearTitle = cleanTitle.length > 4
        ? cleanTitle.replaceFirst(RegExp(r'(?:19|20)\d{2}版?$'), '').trim()
        : cleanTitle;
    final query = strippedYearTitle.isNotEmpty
        ? strippedYearTitle
        : (cleanTitle.isEmpty ? searchTitle : cleanTitle);
    final normTarget = _normalizeTitleForMatch(searchTitle);
    final directLines = <CmsLine>[];
    final fallbackBrokenLines = <CmsLine>[];
    final seenDirectNames = <String>{};
    String bestPoster = CmsParser.isBrokenPosterUrl(fallback.poster) ? '' : fallback.poster;
    String bestDesc = fallback.description;
    String bestActor = fallback.actor;
    String bestYear = fallback.year;
    String bestArea = fallback.area;

    // 1. Include fallback's own healthy direct lines first so the exact item
    //    the user opened is always the primary playback line.
    for (final line in fallback.lines) {
      final playable = line.episodes.where((e) => e.isDirectPlayable).toList(growable: false);
      if (playable.isEmpty) continue;
      final healthy = playable.where((e) => !isDeadOrStubStreamUrl(e.url)).toList(growable: false);
      final friendly = CmsParser.friendlyLineName(line.name);
      if (healthy.isNotEmpty) {
        if (seenDirectNames.add(friendly)) {
          directLines.add(CmsLine(name: friendly, episodes: healthy));
        }
      } else {
        fallbackBrokenLines.add(CmsLine(name: friendly, episodes: playable));
      }
    }

    final quarkFuture = siteHint.trim().isNotEmpty
        ? _scrapeRealQuarkShareEpisodes(query, cleanTitle, normTarget, fetchText)
        : Future.value(const <_QuarkShareEpisodeItem>[]);

    final futures = vodPool.take(_primaryVodPoolCount).map((backend) async {
      try {
        final uri = Uri.parse(backend.api).replace(
          queryParameters: {'ac': 'detail', 'wd': query, 'pg': '1'},
        );
        final raw = await fetchText(
          uri.toString(),
          requestTimeout: const Duration(seconds: 7),
        );
        final listing = CmsParser.parseListing(raw);
        return (backend.name, listing.videos);
      } catch (_) {
        return (backend.name, const <CmsVideo>[]);
      }
    });

    final results = await Future.wait(futures);
    final realQuarkEpisodes = await quarkFuture;
    for (final (backendName, videos) in results) {
      if (videos.isEmpty) continue;
      // Prefer exact title match first, then normalized title match, then substring match
      CmsVideo? matched;
      for (final v in videos) {
        final vt = v.title.trim();
        if (vt == searchTitle || vt == cleanTitle || vt == query) {
          matched = v;
          break;
        }
      }
      if (matched == null) {
        for (final v in videos) {
          if (_normalizeTitleForMatch(v.title) == normTarget) {
            matched = v;
            break;
          }
        }
      }
      if (matched == null) continue;
      if (bestPoster.isEmpty && !CmsParser.isBrokenPosterUrl(matched.poster)) {
        bestPoster = matched.poster;
      }
      if (bestDesc.isEmpty && matched.description.isNotEmpty) bestDesc = matched.description;
      if (bestActor.isEmpty && matched.actor.isNotEmpty) bestActor = matched.actor;
      if (bestYear.isEmpty && matched.year.isNotEmpty) bestYear = matched.year;
      if (bestArea.isEmpty && matched.area.isNotEmpty) bestArea = matched.area;

      for (final line in matched.lines) {
        final playable = line.episodes
            .where((e) => e.isDirectPlayable && !isDeadOrStubStreamUrl(e.url))
            .toList(growable: false);
        if (playable.isNotEmpty) {
          final friendly = CmsParser.friendlyLineName(line.name);
          final candidateName = seenDirectNames.add(friendly)
              ? friendly
              : (seenDirectNames.add(backendName) ? backendName : '$backendName · $friendly');
          seenDirectNames.add(candidateName);
          directLines.add(
            CmsLine(
              name: candidateName,
              episodes: playable,
            ),
          );
        }
      }
    }

    if (directLines.isEmpty && fallbackBrokenLines.isNotEmpty) {
      for (final line in fallbackBrokenLines) {
        if (seenDirectNames.add(line.name)) {
          directLines.add(line);
        }
      }
    }

    // When siteHint is provided (e.g. from DetailScreen / CspBridge.fetchDetail),
    // prepend 4K Netdisk lines (夸父 / 优汐 / 嘟嘟 / 阿狸); when siteHint is empty,
    // preserve only directLines.
    final lines = <CmsLine>[];
    if (siteHint.trim().isNotEmpty && (realQuarkEpisodes.isNotEmpty || directLines.isNotEmpty)) {
      int maxEpCount = 0;
      for (final l in directLines) {
        if (l.episodes.length > maxEpCount) maxEpCount = l.episodes.length;
      }
      final fullLengthLines = maxEpCount > 1
          ? directLines
              .where((l) => l.episodes.length == maxEpCount)
              .toList(growable: false)
          : directLines;
      final netdiskPool = fullLengthLines.isNotEmpty ? fullLengthLines : directLines;
      final netdiskOrder = _netdiskLineOrderForSite(siteHint);
      if (realQuarkEpisodes.isNotEmpty) {
        for (int idx = 0; idx < netdiskOrder.length; idx++) {
          final netdiskLabel = netdiskOrder[idx];
          final mode = netdiskLabel.contains('无限') || netdiskLabel.contains('原画')
              ? 'original'
              : 'speed';
          final fallbackLine = netdiskPool.isNotEmpty
              ? netdiskPool[idx % netdiskPool.length]
              : null;
          lines.add(
            CmsLine(
              name: netdiskLabel,
              episodes: [
                for (int epIdx = 0; epIdx < realQuarkEpisodes.length; epIdx++)
                  CmsEpisode(
                    name: realQuarkEpisodes[epIdx].displayName,
                    url: Uri.https(
                      'drive-pc.quark.cn',
                      '/1/clouddrive/share/sharepage/save',
                      {
                        'pwd_id': realQuarkEpisodes[epIdx].shareId,
                        'stoken': realQuarkEpisodes[epIdx].stoken,
                        'fid': realQuarkEpisodes[epIdx].fid,
                        'fid_token': realQuarkEpisodes[epIdx].fidToken,
                        'fname': realQuarkEpisodes[epIdx].fileName,
                        'mode': mode,
                        if (fallbackLine != null && epIdx < fallbackLine.episodes.length)
                          'fallback': fallbackLine.episodes[epIdx].url,
                      },
                    ).toString(),
                    headers: const {'User-Agent': _quarkPcUa},
                  ),
              ],
            ),
          );
        }
      } else {
        for (int idx = 0; idx < netdiskOrder.length; idx++) {
          final netdiskLabel = netdiskOrder[idx];
          final sourceLine = netdiskPool[idx % netdiskPool.length];
          final totalCount = sourceLine.episodes.length;
          lines.add(
            CmsLine(
              name: netdiskLabel,
              episodes: [
                for (int epIdx = 0; epIdx < totalCount; epIdx++)
                  CmsEpisode(
                    name: sourceLine.episodes[epIdx].name,
                    url: sourceLine.episodes[epIdx].url,
                    headers: sourceLine.episodes[epIdx].headers,
                  ),
              ],
            ),
          );
        }
      }
    }
    lines.addAll(directLines);

    return CmsVideo(
      id: fallback.id,
      title: fallback.title,
      poster: bestPoster,
      remarks: fallback.remarks,
      year: bestYear,
      area: bestArea,
      actor: bestActor,
      description: bestDesc,
      tag: fallback.tag,
      lines: lines,
    );
  }

  static List<String> _netdiskLineOrderForSite(String siteHint) {
    const all = [
      '夸父智1',
      '夸父无限1',
      '优汐智1',
      '优汐无限1',
      '嘟嘟无限2',
      '嘟嘟无限3',
      '阿狸原画',
    ];
    final h = siteHint.toLowerCase();
    if (h.contains('优汐') || h.contains('uc')) {
      return ['优汐智1', '优汐无限1', '夸父智1', '夸父无限1', '嘟嘟无限2', '阿狸原画'];
    }
    if (h.contains('百度') || h.contains('嘟嘟') || h.contains('bpanso')) {
      return ['嘟嘟无限2', '嘟嘟无限3', '夸父智1', '优汐智1', '阿狸原画'];
    }
    if (h.contains('阿狸') || h.contains('阿里') || h.contains('ypanso') || h.contains('易搜') || h.contains('盘他') || h.contains('盘她')) {
      return ['阿狸原画', '夸父智1', '优汐智1', '嘟嘟无限2'];
    }
    return all;
  }

  static Future<bool> _hasLoggedInQuarkCookie() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = (prefs.getString('mm_netdisk_cred_quark_v1') ?? '').trim();
      final cookie = QuarkAccountSession.tryParseCredential(raw)?.cookie ?? raw;
      return cookie.trim().isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static String _formatBytesSize(int bytes) {
    if (bytes <= 0) return '4K';
    final gb = bytes / (1024 * 1024 * 1024);
    if (gb >= 1.0) return '${gb.toStringAsFixed(2)}GB';
    final mb = bytes / (1024 * 1024);
    return '${mb.toStringAsFixed(0)}MB';
  }

  static bool _isVideoFileName(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.mkv') ||
        lower.endsWith('.mp4') ||
        lower.endsWith('.ts') ||
        lower.endsWith('.m2ts') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.avi') ||
        lower.endsWith('.flv') ||
        lower.endsWith('.iso');
  }

  static Future<List<_QuarkShareEpisodeItem>> _scrapeRealQuarkShareEpisodes(
    String query,
    String cleanTitle,
    String normTarget,
    CspHttpTextFetcher fetchText,
  ) async {
    try {
      final searchUrl =
          'https://www.wogg.net/vodsearch/-------------.html?wd=${Uri.encodeQueryComponent(query)}';
      final searchHtml = await fetchText(
        searchUrl,
        headers: const {
          'User-Agent': _desktopSafariUa,
          'Referer': 'https://www.wogg.net/',
        },
        requestTimeout: const Duration(seconds: 6),
      );
      if (!searchHtml.contains('/voddetail/')) return const [];

      String? selectedDetailPath;
      String? firstDetailPath;
      final anchorRegex = RegExp(
        r'''<a[^>]+href\s*=\s*["'](/voddetail/\d+\.html)["']([^>]*)>([\s\S]*?)</a>''',
        caseSensitive: false,
      );
      for (final m in anchorRegex.allMatches(searchHtml)) {
        final path = (m.group(1) ?? '').trim();
        if (path.isEmpty) continue;
        firstDetailPath ??= path;
        final attrs = m.group(2) ?? '';
        final inner = (m.group(3) ?? '')
            .replaceAll(RegExp(r'<[^>]*>'), '')
            .trim();
        final titleMatch = RegExp(r'''title\s*=\s*["']([^"']+)["']''', caseSensitive: false)
            .firstMatch(attrs);
        final candidateTitle = (titleMatch?.group(1) ?? inner).trim();
        if (candidateTitle.isEmpty) continue;
        final normCandidate = _normalizeTitleForMatch(candidateTitle);
        if (candidateTitle == cleanTitle ||
            candidateTitle == query ||
            (normTarget.isNotEmpty &&
                (normCandidate == normTarget || normCandidate.contains(normTarget)))) {
          selectedDetailPath = path;
          break;
        }
      }
      final detailPath = selectedDetailPath ??
          firstDetailPath ??
          RegExp(r'/voddetail/\d+\.html').firstMatch(searchHtml)?.group(0);
      if (detailPath == null || detailPath.isEmpty) return const [];

      final detailHtml = await fetchText(
        Uri.https('www.wogg.net', detailPath).toString(),
        headers: const {
          'User-Agent': _desktopSafariUa,
          'Referer': 'https://www.wogg.net/',
        },
        requestTimeout: const Duration(seconds: 6),
      );
      final shareRegex = RegExp(r'https?://pan\.quark\.cn/s/([A-Za-z0-9_-]+)');
      final shareIds = <String>[];
      final seenShares = <String>{};
      for (final m in shareRegex.allMatches(detailHtml)) {
        final id = (m.group(1) ?? '').trim();
        if (id.isNotEmpty && seenShares.add(id)) {
          shareIds.add(id);
          if (shareIds.length >= 2) break;
        }
      }
      for (final shareId in shareIds) {
        final items = await _listQuarkShareVideoFiles(shareId);
        if (items.isNotEmpty) return items;
      }
    } catch (_) {}
    return const [];
  }

  static Future<Map<String, dynamic>?> _quarkHttpJson(
    HttpClient client,
    String method,
    Uri uri, {
    String cookie = '',
    Map<String, dynamic>? body,
  }) async {
    final req = await client.openUrl(method, uri).timeout(const Duration(seconds: 6));
    req.headers.set('User-Agent', _quarkPcUa);
    req.headers.set('Accept', 'application/json, text/plain, */*');
    req.headers.set('Referer', 'https://pan.quark.cn/');
    req.headers.set('Origin', 'https://pan.quark.cn');
    if (cookie.isNotEmpty) {
      req.headers.set('Cookie', cookie);
    }
    if (body != null) {
      final bytes = utf8.encode(jsonEncode(body));
      req.headers.contentType = ContentType.json;
      req.contentLength = bytes.length;
      req.add(bytes);
    }
    final resp = await req.close().timeout(const Duration(seconds: 6));
    final text = await utf8.decodeStream(resp).timeout(const Duration(seconds: 6));
    final decoded = jsonDecode(text);
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  static Future<List<_QuarkShareEpisodeItem>> _listQuarkShareVideoFiles(
    String shareId,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final tokenResp = await _quarkHttpJson(
        client,
        'POST',
        Uri.parse('https://drive-pc.quark.cn/1/clouddrive/share/sharepage/token?pr=ucpro&fr=pc'),
        body: {'pwd_id': shareId, 'passcode': ''},
      );
      final stoken = (tokenResp?['data']?['stoken'] ?? '').toString().trim();
      if (stoken.isEmpty) return const [];

      final collected = <_QuarkShareEpisodeItem>[];
      Future<void> walkDir(String pdirFid, int depth) async {
        if (depth > 2 || collected.length >= 250) return;
        final detailUri = Uri.https(
          'drive-pc.quark.cn',
          '/1/clouddrive/share/sharepage/detail',
          {
            'pr': 'ucpro',
            'fr': 'pc',
            'pwd_id': shareId,
            'stoken': stoken,
            'pdir_fid': pdirFid,
            'force': '0',
            '_page': '1',
            '_size': '200',
            '_fetch_banner': '0',
            '_fetch_share': '0',
            '_fetch_total': '1',
            '_sort': 'file_type:asc,file_name:asc',
          },
        );
        final detailResp = await _quarkHttpJson(client, 'GET', detailUri);
        final list = detailResp?['data']?['list'];
        if (list is! List) return;
        final subDirs = <String>[];
        for (final item in list) {
          if (item is! Map) continue;
          final fid = (item['fid'] ?? '').toString().trim();
          final fileName = (item['file_name'] ?? '').toString().trim();
          if (fid.isEmpty || fileName.isEmpty) continue;
          final isDir = item['dir'] == true || item['file'] == false;
          if (isDir) {
            subDirs.add(fid);
            continue;
          }
          final fidToken = (item['share_fid_token'] ?? '').toString().trim();
          final category = (item['category'] as num?)?.toInt() ?? 0;
          final size = (item['size'] as num?)?.toInt() ?? 0;
          if (fidToken.isNotEmpty && (category == 1 || _isVideoFileName(fileName))) {
            collected.add(
              _QuarkShareEpisodeItem(
                shareId: shareId,
                stoken: stoken,
                fid: fid,
                fidToken: fidToken,
                fileName: fileName,
                size: size,
                displayName: '[${_formatBytesSize(size)}]$fileName',
              ),
            );
          }
        }
        for (final dirFid in subDirs.take(6)) {
          await walkDir(dirFid, depth + 1);
        }
      }

      await walkDir('0', 0);
      if (collected.isEmpty) return const [];
      final largeFiles = collected.where((e) => e.size >= 20 * 1024 * 1024).toList();
      final filtered = largeFiles.isNotEmpty ? largeFiles : collected;
      filtered.sort((a, b) => _compareEpisodeFileNames(a.fileName, b.fileName));
      return filtered;
    } catch (_) {
      return const [];
    } finally {
      client.close(force: true);
    }
  }

  static int _compareEpisodeFileNames(String a, String b) {
    final epRegex = RegExp(r'(?:[Ss]\d+[Ee](\d+)|[Ee][Pp]?(\d+)|第(\d+)[集话期])');
    final ma = epRegex.firstMatch(a);
    final mb = epRegex.firstMatch(b);
    final na = int.tryParse(ma?.group(1) ?? ma?.group(2) ?? ma?.group(3) ?? '');
    final nb = int.tryParse(mb?.group(1) ?? mb?.group(2) ?? mb?.group(3) ?? '');
    if (na != null && nb != null && na != nb) {
      return na.compareTo(nb);
    }
    return a.compareTo(b);
  }

  static Future<String> _fetchQuarkSocialDownloadUrl(
    HttpClient client,
    String cookie,
    String fid,
  ) async {
    try {
      final convList = await _quarkHttpJson(
        client,
        'GET',
        Uri.parse('https://drive-social-api.quark.cn/1/clouddrive/chat/conv/list?pr=ucpro&fr=pc&_page=1&_size=50'),
        cookie: cookie,
      );
      final convs = convList?['data']?['list'];
      String? convId;
      if (convs is List) {
        for (final c in convs) {
          if (c is Map && c['conversation_id'] != null) {
            convId = c['conversation_id'].toString().trim();
            if (convId.isNotEmpty) break;
          }
        }
      }
      if (convId == null || convId.isEmpty) return '';
      await _quarkHttpJson(
        client,
        'POST',
        Uri.parse('https://drive-social-api.quark.cn/1/clouddrive/chat/conv/msg/batch_send?pr=ucpro&fr=pc'),
        cookie: cookie,
        body: {
          'conversation_ids': [convId],
          'To_ids': const [],
          'msg_list': [
            {'type': 2, 'fid': fid, 'content': ''},
          ],
          'send_scenes': 'file_share',
        },
      );
      final convInfo = await _quarkHttpJson(
        client,
        'GET',
        Uri.parse('https://drive-social-api.quark.cn/1/clouddrive/chat/conv/info?pr=ucpro&fr=pc&conversation_id=${Uri.encodeQueryComponent(convId)}'),
        cookie: cookie,
      );
      final lastMsgId = convInfo?['data']?['conversation']?['last_msg']?['store_msg_id']?.toString().trim() ?? '';
      if (lastMsgId.isEmpty) return '';
      final tokenResp = await _quarkHttpJson(
        client,
        'POST',
        Uri.parse('https://drive-social-api.quark.cn/1/clouddrive/chat/conv/file/acquire_dl_token?pr=ucpro&fr=pc'),
        cookie: cookie,
        body: {
          'conversation_id': convId,
          'conversation_type': 3,
          'msg_id': int.tryParse(lastMsgId) ?? lastMsgId,
        },
      );
      final dlToken = (tokenResp?['data']?['token'] ?? '').toString().trim();
      if (dlToken.isEmpty) return '';
      final dlResp = await _quarkHttpJson(
        client,
        'POST',
        Uri.parse('https://drive-pc.quark.cn/1/clouddrive/file/download?pr=ucpro&fr=pc'),
        cookie: cookie,
        body: {
          'fids': [fid],
          'speedup_session': '',
          'token': dlToken,
        },
      );
      final dlList = dlResp?['data'];
      if (dlList is List && dlList.isNotEmpty && dlList.first is Map) {
        return (dlList.first['download_url'] ?? '').toString().trim();
      }
    } catch (_) {}
    return '';
  }

  static Future<CmsEpisode> _resolveQuarkShareEpisode(CmsEpisode episode) async {
    final uri = Uri.parse(episode.url.trim());
    final shareId = (uri.queryParameters['pwd_id'] ?? '').trim();
    var stoken = (uri.queryParameters['stoken'] ?? '').trim();
    final fid = (uri.queryParameters['fid'] ?? '').trim();
    final fidToken = (uri.queryParameters['fid_token'] ?? '').trim();
    final fileName = (uri.queryParameters['fname'] ?? '').trim();
    final mode = (uri.queryParameters['mode'] ?? 'speed').trim();
    final fallbackUrl = (uri.queryParameters['fallback'] ?? '').trim();

    String cookie = '';
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = (prefs.getString('mm_netdisk_cred_quark_v1') ?? '').trim();
      cookie = (QuarkAccountSession.tryParseCredential(raw)?.cookie ?? raw).trim();
    } catch (_) {}

    if (cookie.isEmpty) {
      if (fallbackUrl.isNotEmpty) {
        return CmsEpisode(name: episode.name, url: fallbackUrl);
      }
      throw const FormatException('请先在「我的云盘 / 设置」扫码登录夸克网盘以播放 4K 原画资源');
    }

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      if (stoken.isEmpty && shareId.isNotEmpty) {
        final tokenResp = await _quarkHttpJson(
          client,
          'POST',
          Uri.parse('https://drive-pc.quark.cn/1/clouddrive/share/sharepage/token?pr=ucpro&fr=pc'),
          cookie: cookie,
          body: {'pwd_id': shareId, 'passcode': ''},
        );
        stoken = (tokenResp?['data']?['stoken'] ?? '').toString().trim();
      }
      if (shareId.isEmpty || stoken.isEmpty || fid.isEmpty || fidToken.isEmpty) {
        throw const FormatException('夸克分享链接参数不完整');
      }

      // 1. Find or create `0000temp` directory
      String tempDirFid = '';
      final rootSort = await _quarkHttpJson(
        client,
        'GET',
        Uri.parse('https://drive-pc.quark.cn/1/clouddrive/file/sort?pr=ucpro&fr=pc&pdir_fid=0&_page=1&_size=100&_sort=file_type:asc,updated_at:desc'),
        cookie: cookie,
      );
      final rootList = rootSort?['data']?['list'];
      if (rootList is List) {
        for (final item in rootList) {
          if (item is Map &&
              (item['dir'] == true || item['file'] == false) &&
              item['file_name'] == '0000temp') {
            tempDirFid = (item['fid'] ?? '').toString().trim();
            break;
          }
        }
      }
      if (tempDirFid.isEmpty) {
        final mkdirResp = await _quarkHttpJson(
          client,
          'POST',
          Uri.parse('https://drive-pc.quark.cn/1/clouddrive/file?pr=ucpro&fr=pc'),
          cookie: cookie,
          body: {
            'pdir_fid': '0',
            'file_name': '0000temp',
            'dir_path': '',
            'dir_init_lock': false,
          },
        );
        tempDirFid = (mkdirResp?['data']?['fid'] ?? '').toString().trim();
      }
      if (tempDirFid.isEmpty) {
        throw const FormatException('无法访问夸克网盘临时目录');
      }

      // 2. Check existing files in `0000temp` (reuse if same file, delete stale files to free quota)
      String savedFid = '';
      final tempSort = await _quarkHttpJson(
        client,
        'GET',
        Uri.parse('https://drive-pc.quark.cn/1/clouddrive/file/sort?pr=ucpro&fr=pc&pdir_fid=$tempDirFid&_page=1&_size=100&_sort=file_type:asc,updated_at:desc'),
        cookie: cookie,
      );
      final tempList = tempSort?['data']?['list'];
      final staleFids = <String>[];
      if (tempList is List) {
        for (final item in tempList) {
          if (item is! Map) continue;
          final itemFid = (item['fid'] ?? '').toString().trim();
          final itemName = (item['file_name'] ?? '').toString().trim();
          if (itemFid.isEmpty) continue;
          if (savedFid.isEmpty && fileName.isNotEmpty && itemName == fileName) {
            savedFid = itemFid;
          } else {
            staleFids.add(itemFid);
          }
        }
      }
      if (staleFids.isNotEmpty) {
        await _quarkHttpJson(
          client,
          'POST',
          Uri.parse('https://drive-pc.quark.cn/1/clouddrive/file/delete?pr=ucpro&fr=pc'),
          cookie: cookie,
          body: {
            'action_type': 2,
            'filelist': staleFids,
            'exclude_fids': const [],
          },
        ).catchError((_) => null);
      }

      // 3. Save shared file to `0000temp` if not already cached
      if (savedFid.isEmpty) {
        final saveResp = await _quarkHttpJson(
          client,
          'POST',
          Uri.parse('https://drive-pc.quark.cn/1/clouddrive/share/sharepage/save?pr=ucpro&fr=pc'),
          cookie: cookie,
          body: {
            'fid_list': [fid],
            'fid_token_list': [fidToken],
            'to_pdir_fid': tempDirFid,
            'pwd_id': shareId,
            'stoken': stoken,
            'pdir_fid': '0',
            'scene': 'link',
          },
        );
        final taskId = (saveResp?['data']?['task_id'] ?? '').toString().trim();
        if (taskId.isNotEmpty) {
          for (int i = 0; i < 12; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 250));
            final taskResp = await _quarkHttpJson(
              client,
              'GET',
              Uri.parse('https://drive-pc.quark.cn/1/clouddrive/task?pr=ucpro&fr=pc&task_id=$taskId&retry_index=$i'),
              cookie: cookie,
            );
            final topFids = taskResp?['data']?['save_as']?['save_as_top_fids'];
            if (topFids is List && topFids.isNotEmpty) {
              savedFid = topFids.first.toString().trim();
              if (savedFid.isNotEmpty) break;
            }
          }
        }
      }
      if (savedFid.isEmpty) {
        throw const FormatException('夸克网盘转存 4K 资源超时');
      }

      final playHeaders = <String, String>{
        'User-Agent': _quarkPcUa,
        'Cookie': cookie,
        'Referer': 'https://pan.quark.cn/',
      };

      // 4. Fetch 4K / 2K / Super cloud transcode streams
      final transcodeVariants = <CmsEpisode>[];
      try {
        final playResp = await _quarkHttpJson(
          client,
          'POST',
          Uri.parse('https://drive-pc.quark.cn/1/clouddrive/file/v2/play?pr=ucpro&fr=pc'),
          cookie: cookie,
          body: {
            'fid': savedFid,
            'resolutions': 'normal,low,high,super,2k,4k',
            'supports': 'fmp4,m3u8',
          },
        );
        final videoList = playResp?['data']?['video_list'];
        if (videoList is List) {
          const order = ['4k', '2k', 'super', 'high', 'normal', 'low'];
          const labels = {
            '4k': '4K云盘',
            '2k': '2K云盘',
            'super': '超清云盘',
            'high': '高清云盘',
            'normal': '标清云盘',
            'low': '流畅云盘',
          };
          for (final resKey in order) {
            for (final item in videoList) {
              if (item is! Map) continue;
              if (item['resolution']?.toString().toLowerCase() == resKey) {
                final vUrl = (item['video_info']?['url'] ?? '').toString().trim();
                if (vUrl.isNotEmpty) {
                  transcodeVariants.add(
                    CmsEpisode(
                      name: labels[resKey] ?? resKey.toUpperCase(),
                      url: vUrl,
                      headers: playHeaders,
                    ),
                  );
                }
              }
            }
          }
        }
      } catch (_) {}

      // 5. Fetch 4K original MKV stream (`file/download` + social token fallback)
      String originalUrl = '';
      if (mode == 'original') {
        originalUrl = await _fetchQuarkSocialDownloadUrl(client, cookie, savedFid);
      }
      if (originalUrl.isEmpty) {
        try {
          final dlResp = await _quarkHttpJson(
            client,
            'POST',
            Uri.parse('https://drive-pc.quark.cn/1/clouddrive/file/download?pr=ucpro&fr=pc'),
            cookie: cookie,
            body: {
              'fids': [savedFid],
            },
          );
          final dlList = dlResp?['data'];
          if (dlList is List && dlList.isNotEmpty && dlList.first is Map) {
            originalUrl = (dlList.first['download_url'] ?? '').toString().trim();
          }
        } catch (_) {}
      }
      if (originalUrl.isEmpty && mode != 'original') {
        originalUrl = await _fetchQuarkSocialDownloadUrl(client, cookie, savedFid);
      }

      final variants = <CmsEpisode>[];
      if (mode == 'original') {
        if (originalUrl.isNotEmpty) {
          variants.add(CmsEpisode(name: '4K原画', url: originalUrl, headers: playHeaders));
        }
        variants.addAll(transcodeVariants);
      } else {
        variants.addAll(transcodeVariants);
        if (originalUrl.isNotEmpty) {
          variants.add(CmsEpisode(name: '4K原画', url: originalUrl, headers: playHeaders));
        }
      }

      if (variants.isNotEmpty) {
        return CmsEpisode(
          name: episode.name,
          url: variants.first.url,
          headers: playHeaders,
          variants: variants,
        );
      }
    } catch (_) {
      if (fallbackUrl.isNotEmpty) {
        return CmsEpisode(name: episode.name, url: fallbackUrl);
      }
      rethrow;
    } finally {
      client.close(force: true);
    }

    if (fallbackUrl.isNotEmpty) {
      return CmsEpisode(name: episode.name, url: fallbackUrl);
    }
    throw const FormatException('未能解析出可用的夸克 4K 播放地址');
  }

  static Future<List<CmsLine>> resolveCrossSourceLines(
    String title,
    CspHttpTextFetcher fetchText, {
    Set<String> excludeLineNames = const {},
  }) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return const [];
    final cleanTitle = trimmed
        .replaceAll(RegExp(r'[\(（\[【].*?[\)）\]】]'), '')
        .trim();
    final strippedYear = cleanTitle.length > 4
        ? cleanTitle.replaceFirst(RegExp(r'(?:19|20)\d{2}版?$'), '').trim()
        : cleanTitle;
    final query = strippedYear.isNotEmpty ? strippedYear : trimmed;
    final normTarget = _normalizeTitleForMatch(trimmed);
    final extra = <CmsLine>[];
    final seenNames = <String>{...excludeLineNames};
    final futures = vodPool.take(6).map((backend) async {
      try {
        final uri = Uri.parse(backend.api).replace(
          queryParameters: {'ac': 'detail', 'wd': query, 'pg': '1'},
        );
        final raw = await fetchText(
          uri.toString(),
          requestTimeout: const Duration(seconds: 6),
        );
        final listing = CmsParser.parseListing(raw);
        return (backend.name, listing.videos);
      } catch (_) {
        return (backend.name, const <CmsVideo>[]);
      }
    });
    final results = await Future.wait(futures);
    for (final (backendName, videos) in results) {
      for (final v in videos) {
        if (v.title.trim() == trimmed ||
            _normalizeTitleForMatch(v.title) == normTarget) {
          for (final l in v.lines) {
            final friendly = CmsParser.friendlyLineName(l.name);
            final playable = l.episodes
                .where((e) => e.isDirectPlayable && !isDeadOrStubStreamUrl(e.url))
                .toList(growable: false);
            if (playable.isNotEmpty) {
              final lineLabel = seenNames.add(friendly)
                  ? friendly
                  : (seenNames.add(backendName) ? backendName : '');
              if (lineLabel.isNotEmpty) {
                extra.add(CmsLine(name: lineLabel, episodes: playable));
              }
            }
          }
          break;
        }
      }
    }
    return extra;
  }
}

class _QuarkShareEpisodeItem {
  final String shareId;
  final String stoken;
  final String fid;
  final String fidToken;
  final String fileName;
  final int size;
  final String displayName;

  const _QuarkShareEpisodeItem({
    required this.shareId,
    required this.stoken,
    required this.fid,
    required this.fidToken,
    required this.fileName,
    required this.size,
    required this.displayName,
  });
}
