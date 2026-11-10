import 'dart:async';
import '../core/emby_library.dart';
import '../core/catpaw_host.dart';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Real per-episode metadata resolved from open domestic encyclopedias & media APIs
/// (360 Baike `tvplot`, Bilibili PGC `media_bangumi`/`media_ft`, and Bangumi `/v0/episodes`).
class EpisodeRealMeta {
  final int episodeNumber; // 1-based episode number
  final String title; // Real episode title, e.g. "范闲制造假死瞒天过海"
  final String summary; // Real episode plot synopsis
  final String coverUrl; // Real 16:9 episode still URL

  const EpisodeRealMeta({
    required this.episodeNumber,
    this.title = '',
    this.summary = '',
    this.coverUrl = '',
  });

  EpisodeRealMeta mergeWith({
    String? title,
    String? summary,
    String? coverUrl,
  }) {
    return EpisodeRealMeta(
      episodeNumber: episodeNumber,
      title: (title != null && title.trim().isNotEmpty)
          ? title.trim()
          : this.title,
      summary: (summary != null && summary.trim().isNotEmpty)
          ? summary.trim()
          : this.summary,
      coverUrl: (coverUrl != null && coverUrl.trim().isNotEmpty)
          ? coverUrl.trim()
          : this.coverUrl,
    );
  }
}

/// Robust cross-platform HD poster & episode still loader (Windows / macOS / iOS / iPadOS).
///
/// Key resilience & HD quality mechanisms:
/// 1. Broadcasts `cacheRevision` & `metadataRevision` whenever any poster or
///    episode still lands in memory so visible cards in scrolling lists/grids
///    repaint immediately without requiring a tab/page switch.
/// 2. Verifies actual decoded pixel dimensions (`isTrueHdPoster`: width >= 580 &&
///    height >= 780) on hero posters so low-resolution CMS thumbnails are
///    always upgraded to true 1080p/2K vertical posters.
/// 3. Resolves true HD vertical posters across Bangumi (`api.bgm.tv` `images.large`),
///    Baidu Baike OpenAPI (`BaikeLemmaCardApi` raw `bcebos.com` poster),
///    Bilibili PGC (`api.bilibili.com`), Douban (`l_ratio_poster` with `bid` cookie),
///    and Bing original `murl` high-res sources.
/// 4. Resolves real per-episode synopses (`分集剧情`), episode titles, and 16:9
///    episode frame covers via 360 Baike `tvplot`, Bilibili PGC `eps`, Bangumi
///    `/v0/episodes`, and Bing widescreen scene stills.
class PosterLoader {
  PosterLoader._();

  static const String _mobileSafariUa =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';
  static const String _desktopSafariUa =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15';
  static const String _desktopChromeUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
  static const String _tvBoxUa = 'okhttp/3.15';
  static const String _biliCookie =
      'buvid3=58D32EBE-894C-69EE-AE53-607BE1EC3CC597728infoc; b_nut=1793900397';
  static const int _maxImageBytes = 15 * 1024 * 1024;
  static const int _maxMemoryBytes = 112 * 1024 * 1024;
  static const int _maxConcurrent = 32;

  static final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(milliseconds: 3200)
    ..idleTimeout = const Duration(seconds: 25)
    ..maxConnectionsPerHost = 18
    ..userAgent = null
    ..autoUncompress = true;

  /// Increments whenever any poster image bytes are written into [_memory].
  /// Active [PosterImage] widgets listen to this notifier so scrolling lists
  /// refresh immediately in place.
  static final ValueNotifier<int> cacheRevision = ValueNotifier<int>(0);

  /// Increments whenever series synopses, episode plots, or episode stills finish
  /// loading into memory.
  static final ValueNotifier<int> metadataRevision = ValueNotifier<int>(0);

  static final LinkedHashMap<String, Uint8List> _memory =
      LinkedHashMap<String, Uint8List>();
  static int _memoryBytes = 0;
  static final Map<String, Future<Uint8List>> _inflight = {};
  static final Map<String, Future<Uint8List>> _inflightTitleBytes = {};
  static final Map<String, Future<Uint8List>> _inflightHdTitleBytes = {};
  static final Map<String, List<String>> _titleCoverUrlsCache = {};
  static final Map<String, List<String>> _verifiedTitleCoverUrlsCache = {};
  static final Map<String, String> _titleSynopsisCache = {};
  static final Map<String, List<String>> _seriesEpisodeStillsCache = {};
  static final Map<String, List<String>> _seriesEpisodeCaptionsCache = {};
  static final Map<String, Map<int, EpisodeRealMeta>> _seriesEpisodeMetaCache =
      {};
  static final Map<String, Future<List<String>>> _inflightSeriesStills = {};
  static final Map<String, Future<Map<int, EpisodeRealMeta>>>
      _inflightEpisodeMeta = {};
  static final Map<int, Color> _ambientColorCache = {};
  static final Map<int, bool> _hdDimensionCache = {};
  static int _active = 0;
  static final Queue<Completer<void>> _waiters = Queue<Completer<void>>();
  static Directory? _diskDir;
  static bool _diskReady = false;
  static final math.Random _rng = math.Random();

  static String _randomDoubanBid() {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final sb = StringBuffer();
    for (int i = 0; i < 11; i++) {
      sb.write(chars[_rng.nextInt(chars.length)]);
    }
    return sb.toString();
  }

  /// Human-readable summary of in-memory poster cache usage for Settings UI.
  static String get memoryCacheSizeLabel {
    final mb = _memoryBytes / (1024 * 1024);
    if (_memory.isEmpty) return '0.0 MB (0 张)';
    return '${mb.toStringAsFixed(1)} MB (${_memory.length} 张)';
  }

  /// Clears both in-memory LRU cache and on-disk temporary poster files.
  static Future<void> clearCache() async {
    _memory.clear();
    _memoryBytes = 0;
    _titleCoverUrlsCache.clear();
    _verifiedTitleCoverUrlsCache.clear();
    _titleSynopsisCache.clear();
    _seriesEpisodeStillsCache.clear();
    _seriesEpisodeCaptionsCache.clear();
    _seriesEpisodeMetaCache.clear();
    _ambientColorCache.clear();
    _hdDimensionCache.clear();
    cacheRevision.value++;
    metadataRevision.value++;
    try {
      final dir = _diskDir ??
          Directory(
            '${Directory.systemTemp.path}${Platform.pathSeparator}marco_poster_cache_v4',
          );
      if (await dir.exists()) {
        await for (final entity in dir.list()) {
          if (entity is File) {
            try {
              await entity.delete();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
  }

  /// Upgrades known thumbnail poster URLs to their 1080p HD counterparts.
  static String upgradeUrlToHd(String rawUrl) {
    var u = rawUrl.trim();
    if (u.isEmpty) return '';
    if (u.startsWith('//')) u = 'https:$u';
    if (u.startsWith('http://lain.bgm.tv/')) {
      u = u.replaceFirst('http://', 'https://');
    }
    if (u.contains('lain.bgm.tv/pic/cover/')) {
      u = u.replaceFirst(
        RegExp(r'/pic/cover/[csgm]/'),
        '/pic/cover/l/',
      );
    } else if (u.contains('doubanio.com')) {
      u = u
          .replaceFirst('img9.doubanio.com', 'img3.doubanio.com')
          .replaceFirst('/s_ratio_poster/', '/l_ratio_poster/')
          .replaceFirst('/m_ratio_poster/', '/l_ratio_poster/')
          .replaceFirst('/view/photo/spic/', '/view/photo/lpic/')
          .replaceFirst('/view/photo/mpic/', '/view/photo/lpic/')
          .replaceFirst('/view/subject/s/', '/view/subject/l/')
          .replaceFirst('/view/subject/m/', '/view/subject/l/');
      if (u.endsWith('.webp')) {
        u = '${u.substring(0, u.length - 5)}.jpg';
      }
    } else if (u.contains('hdslb.com') || u.contains('biliimg.com')) {
      if (u.startsWith('http://')) {
        u = u.replaceFirst('http://', 'https://');
      }
      final atResize = RegExp(r'@\d+w_\d+h.*$').firstMatch(u);
      if (atResize != null) {
        u = u.substring(0, atResize.start);
      }
    } else if (u.contains('bkimg.cdn.bcebos.com/pic/')) {
      final qIdx = u.indexOf('?');
      if (qIdx > 0) {
        u = u.substring(0, qIdx);
      }
    }
    return u;
  }

  static String cleanTitleForQuery(String rawTitle) => _cleanTitle(rawTitle);

  static String _cleanTitle(String rawTitle) {
    return rawTitle
        .replaceAll(RegExp(r'[\(（\[【].*?[\)）\]】]'), '')
        .replaceAll(RegExp(r'第[0-9一二三四五六七八九十百]+[季部集期篇章]'), '')
        .replaceAll(
          RegExp(
            r'\b(4K|1080[pP]|2160[pP]|720[pP]|HD|BD|国语|粤语|中字|更新至.*|全\d+集)\b',
          ),
          '',
        )
        .replaceAll(RegExp(r'(?:19|20)\d{2}\s*$'), '')
        .trim();
  }

  static int? _extractSeasonNumber(String rawTitle) {
    final cnMap = <String, int>{
      '一': 1,
      '二': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
      '十': 10,
    };
    final mCn =
        RegExp(r'第\s*([0-9一二三四五六七八九十]+)\s*[季部]').firstMatch(rawTitle);
    if (mCn != null) {
      final token = mCn.group(1)!;
      final asInt = int.tryParse(token);
      if (asInt != null) return asInt;
      if (cnMap.containsKey(token)) return cnMap[token];
    }
    final mEn =
        RegExp(r'\bSeason\s*(\d+)\b', caseSensitive: false).firstMatch(rawTitle);
    if (mEn != null) {
      return int.tryParse(mEn.group(1)!);
    }
    return null;
  }

  /// Strict work-title matcher so external encyclopedias (360 Baike, Baidu Baike,
  /// Bilibili PGC, Bangumi) never attach an unrelated drama/anime synopsis or
  /// per-episode plot to a variety show or different title.
  static bool _isSameWorkTitle(String candidateRaw, String targetRaw) {
    final candNoHtml = candidateRaw
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll(RegExp(r'_360百科.*$|-360百科.*$|_百度百科.*$'), '')
        .trim();
    if (candNoHtml.isEmpty || targetRaw.trim().isEmpty) return false;

    final candSeason = _extractSeasonNumber(candNoHtml);
    final targetSeason = _extractSeasonNumber(targetRaw);
    if (candSeason != null &&
        targetSeason != null &&
        candSeason != targetSeason) {
      return false;
    }

    String normalizeCore(String s) {
      return _cleanTitle(s)
          .replaceAll(RegExp(r'[《》〈〉「」『』"“”\x27‘’：:·—\-\s_!！?？,，.。]'), '')
          .toLowerCase();
    }

    final cNorm = normalizeCore(candNoHtml);
    final tNorm = normalizeCore(targetRaw);
    if (cNorm.isEmpty || tNorm.isEmpty) return false;
    if (cNorm == tNorm) return true;

    // Also allow matching against subtitle/base variants when sufficiently specific (>= 4 chars)
    final variants = _queryVariantsForTitle(targetRaw)
        .map(normalizeCore)
        .where((v) => v.length >= 3)
        .toList();
    for (final v in variants) {
      if (cNorm == v) return true;
      if (v.length >= 4 && (cNorm.startsWith(v) || v.startsWith(cNorm))) {
        final shorter = cNorm.length < v.length ? cNorm.length : v.length;
        final longer = cNorm.length > v.length ? cNorm.length : v.length;
        if (shorter / longer >= 0.72) return true;
      }
    }
    return false;
  }

  /// Verifies that an encyclopedia description/abstract actually describes a
  /// film, TV drama, anime, variety show, or documentary — rejecting homonym
  /// entries such as the 24 Solar Terms (`二十四节气·谷雨/惊蛰/清明/白露/立春`),
  /// novels, dictionary words, poems, plants, or administrative regions.
  static bool _isFilmOrTvEntryText(String text) {
    final t = text.trim();
    if (t.isEmpty) return false;
    // Reject solar terms, novels, idioms, plants, and geography definitions
    if (RegExp(
      r'二十四节气|太阳到达黄经|节气之一|春季的最后一个节气|雨生百谷|春茶|'
      r'所著的.*小说|连载于.*小说|网络小说|起点中文网|晋江文学城|'
      r'汉语词语|成语|唐代诗人|宋代词人|草本植物|中药材|行政区划|下辖',
    ).hasMatch(t)) {
      return false;
    }
    return RegExp(
      r'电视剧|剧集|网剧|网络剧|短剧|连续剧|电视连续剧|'
      r'电影|影片|院线|故事片|纪录片|'
      r'动画|动漫|番剧|电视动画|动画片|'
      r'综艺|真人秀|节目|'
      r'执导|导演|主演|领衔主演|出演|饰演|编剧|制片|出品|播出|首播|上映|定档|杀青',
    ).hasMatch(t);
  }

  /// Filters out non-entertainment Bing image search results (solar-term posters,
  /// graphic design templates, stock material, wallpapers, tea/poetry posters).
  static bool _isNonEntertainmentBingCaption(String text) {
    return RegExp(
      r'节气|二十四节气|雨生百谷|春山雨前|春茶|茗茶|茶叶|养生|诗词|古诗|'
      r'手抄报|模板|素材|设计|海报设计|展板|易拉宝|宣传画|公众号首图|'
      r'千图|昵图|包图|花瓣|站酷|红动中国|图怪兽|稿定设计|壁纸|插画|矢量|PPT',
      caseSensitive: false,
    ).hasMatch(text);
  }

  /// Generates ordered search query variants from most specific to core title,
  /// e.g. `斗罗大陆2：绝世唐门2023` -> `['斗罗大陆2：绝世唐门', '斗罗大陆2绝世唐门', '绝世唐门', '斗罗大陆']`.
  static List<String> _queryVariantsForTitle(String rawTitle) {
    final clean = _cleanTitle(rawTitle);
    if (clean.isEmpty) return const [];
    final out = <String>[clean];
    final compact = clean
        .replaceAll(RegExp(r'[：:·—\-\s]+'), '')
        .trim();
    if (compact.isNotEmpty && !out.contains(compact)) {
      out.add(compact);
    }
    final normalizedSpace = clean
        .replaceAll(RegExp(r'[：:·—\-]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (normalizedSpace.isNotEmpty && !out.contains(normalizedSpace)) {
      out.add(normalizedSpace);
    }
    final parts = clean
        .split(
          RegExp(
            r'[：:·—\-\s]+|(?<=[\u4e00-\u9fa5])(?:[0-9]+|[IⅠVⅤXⅩ]{1,4})[：:·—\-\s]*(?=[\u4e00-\u9fa5])',
          ),
        )
        .map((s) => s.trim())
        .where((s) => s.length >= 2)
        .toList();
    if (parts.length >= 2) {
      final subtitle = parts.last;
      final baseTitle = parts.first;
      if (!out.contains(subtitle)) out.add(subtitle);
      if (!out.contains(baseTitle)) out.add(baseTitle);
    }
    return out;
  }

  static String _cacheKeyFor(String rawUrl, String title) {
    final u = upgradeUrlToHd(rawUrl);
    if (u.isNotEmpty) return u;
    final t = _cleanTitle(title);
    return t.isEmpty ? '' : 'title:$t';
  }

  /// Decodes the image header to verify whether [bytes] is a true high-definition
  /// vertical poster (`width >= 560 && height >= 760` or `>= 450K` pixels, or `>= 180KB`).
  static Future<bool> isTrueHdPoster(Uint8List bytes) async {
    if (bytes.length < 28 * 1024) return false;
    if (bytes.length >= 220 * 1024) return true;
    final fp = _bytesFingerprint(bytes);
    final cached = _hdDimensionCache[fp];
    if (cached != null) return cached;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final w = frame.image.width;
      final h = frame.image.height;
      frame.image.dispose();
      final isHd = (w >= 560 && h >= 760) || (w * h >= 450000);
      _hdDimensionCache[fp] = isHd;
      return isHd;
    } catch (_) {
      final fallback = bytes.length >= 110 * 1024;
      _hdDimensionCache[fp] = fallback;
      return fallback;
    }
  }

  /// Synchronously peeks in-memory LRU cache so already-loaded posters render
  /// on the very first frame without any async gap.
  static Uint8List? peekMemory(
    String rawUrl, {
    String title = '',
    bool preferHd = false,
  }) {
    if (EmbyLibrary.isImage(rawUrl)) return _memory[rawUrl];
    final clean = _cleanTitle(title);
    if (preferHd && clean.isNotEmpty) {
      final hdKey = 'title_hd:$clean';
      final hdHit = _memory.remove(hdKey);
      if (hdHit != null) {
        _memory[hdKey] = hdHit;
        return hdHit;
      }
    }
    final u = upgradeUrlToHd(rawUrl);
    if (u.isNotEmpty) {
      final hit = _memory.remove(u);
      if (hit != null) {
        _memory[u] = hit;
        return hit;
      }
    }
    if (clean.isNotEmpty) {
      final hdKey = 'title_hd:$clean';
      final hdHit = _memory.remove(hdKey);
      if (hdHit != null) {
        _memory[hdKey] = hdHit;
        return hdHit;
      }
      final tKey = 'title:$clean';
      final hit = _memory.remove(tKey);
      if (hit != null) {
        _memory[tKey] = hit;
        return hit;
      }
    }
    return null;
  }

  /// Synchronously peeks only the verified HD title cache (`title_hd:<clean>`).
  static Uint8List? peekHdMemory(String title) {
    final clean = _cleanTitle(title);
    if (clean.isEmpty) return null;
    final hdKey = 'title_hd:$clean';
    final hdHit = _memory.remove(hdKey);
    if (hdHit != null) {
      _memory[hdKey] = hdHit;
      return hdHit;
    }
    return null;
  }

  /// Loads poster bytes, de-duplicating concurrent requests and racing slow
  /// overseas URLs against fast domestic HD cover resolution by [title].
  static Future<Uint8List> load(String raw, {String title = ''}) {
    if (EmbyLibrary.isImage(raw)) {
      final cached = _memory[raw];
      if (cached != null) return SynchronousFuture(cached);
      return _inflight.putIfAbsent(raw, () => _fetch(raw, const {}, timeout: const Duration(seconds: 8))
        .then((bytes) { _remember(raw, bytes); return bytes; })
        .whenComplete(() { _inflight.remove(raw); }));
    }
    final immediate = peekMemory(raw, title: title);
    if (immediate != null) {
      return SynchronousFuture<Uint8List>(immediate);
    }
    final upgradedUrl = upgradeUrlToHd(raw);
    final key = _cacheKeyFor(upgradedUrl, title);
    if (key.isEmpty) {
      return Future<Uint8List>.error(const FormatException('空海报地址'));
    }
    final pending = _inflight[key];
    if (pending != null) return pending;
    final future = _loadUncached(upgradedUrl, title.trim(), key)
        .whenComplete(() { _inflight.remove(key); });
    _inflight[key] = future;
    return future;
  }

  /// Explicitly resolves an official 1080p/2K high-definition domestic poster by
  /// [rawTitle] (via Bangumi `images.large`, film-verified Baidu Baike raw `bcebos`,
  /// title-verified Bilibili PGC, and title-verified Douban `l_ratio_poster`),
  /// verifying actual pixel resolution before persisting across memory and disk cache.
  /// When [rawUrl] is provided by the CMS, unverified generic search results (Bing)
  /// are NEVER allowed to overwrite the CMS poster.
  static Future<Uint8List> loadHdByTitle(
    String rawTitle, {
    String rawUrl = '',
  }) {
    final clean = _cleanTitle(rawTitle);
    if (clean.isEmpty) {
      return Future<Uint8List>.error(const FormatException('空片名'));
    }
    final hdKey = 'title_hd:$clean';
    final hit = _memory[hdKey];
    if (hit != null && hit.length >= 68 * 1024) {
      return SynchronousFuture<Uint8List>(hit);
    }
    final pending = _inflightHdTitleBytes[clean];
    if (pending != null) return pending;

    final future = () async {
      // Check disk cache for hdKey first and verify pixel dimensions
      final hdDisk = await _diskFileFor(hdKey);
      if (hdDisk != null) {
        try {
          if (await hdDisk.exists()) {
            final diskBytes = await hdDisk.readAsBytes();
            if (_looksLikeImage(diskBytes) &&
                await isTrueHdPoster(diskBytes)) {
              _remember(hdKey, diskBytes);
              _remember('title:$clean', diskBytes);
              final u = upgradeUrlToHd(rawUrl);
              if (u.isNotEmpty) _remember(u, diskBytes);
              return diskBytes;
            }
          }
        } catch (_) {}
      }

      // If the CMS provided a valid poster URL, check if its upgraded URL is
      // already a true HD poster first!
      final hasValidCmsUrl =
          rawUrl.trim().isNotEmpty && !_isKnownDeadPosterHost(rawUrl);
      if (hasValidCmsUrl) {
        final upgradedCms = upgradeUrlToHd(rawUrl);
        final inMemCms = _memory[upgradedCms];
        if (inMemCms != null && await isTrueHdPoster(inMemCms)) {
          await _persistHdResult(clean, rawUrl, inMemCms);
          return inMemCms;
        }
      }

      // Resolve candidate URLs: when CMS already has a valid poster URL, ONLY
      // allow verified film/TV databases (`verifiedOnly: true`) to upgrade it!
      final urls = await _resolveCoverUrlsByTitle(
        clean,
        forceRefreshHd: true,
        verifiedOnly: hasValidCmsUrl,
      );
      Uint8List? bestBytes;
      int bestScore = 0;

      for (final candidateUrl in urls) {
        for (final attempt in _attemptsFor(candidateUrl)) {
          try {
            final bytes = await _fetch(
              attempt.$1,
              attempt.$2,
              timeout: const Duration(milliseconds: 3800),
            );
            final isTrueHd = await isTrueHdPoster(bytes);
            final score = bytes.length + (isTrueHd ? 500000 : 0);
            if (bestBytes == null || score > bestScore) {
              bestBytes = bytes;
              bestScore = score;
            }
            if (isTrueHd && bytes.length >= 68 * 1024) {
              await _persistHdResult(clean, rawUrl, bytes);
              return bytes;
            }
          } catch (_) {}
        }
      }
      if (bestBytes != null && await isTrueHdPoster(bestBytes)) {
        await _persistHdResult(clean, rawUrl, bestBytes);
        return bestBytes;
      }
      if (bestBytes != null && bestBytes.length >= 85 * 1024) {
        await _persistHdResult(clean, rawUrl, bestBytes);
        return bestBytes;
      }
      throw Exception('未找到「$clean」高清封面');
    }()
        .whenComplete(() { _inflightHdTitleBytes.remove(clean); });

    _inflightHdTitleBytes[clean] = future;
    return future;
  }

  static Future<void> _persistHdResult(
    String cleanTitle,
    String rawUrl,
    Uint8List bytes,
  ) async {
    final hdKey = 'title_hd:$cleanTitle';
    final tKey = 'title:$cleanTitle';
    _remember(hdKey, bytes);
    _remember(tKey, bytes);
    final u = upgradeUrlToHd(rawUrl);
    if (u.isNotEmpty) {
      _remember(u, bytes);
      final urlDisk = await _diskFileFor(u);
      if (urlDisk != null) unawaited(_writeDisk(urlDisk, bytes));
    }
    final hdDisk = await _diskFileFor(hdKey);
    if (hdDisk != null) unawaited(_writeDisk(hdDisk, bytes));
    final titleDisk = await _diskFileFor(tKey);
    if (titleDisk != null) unawaited(_writeDisk(titleDisk, bytes));
  }

  /// Synchronously peeks cached ambient color extracted from poster [bytes].
  static Color? peekAmbientColor(Uint8List bytes) {
    return _ambientColorCache[_bytesFingerprint(bytes)];
  }

  /// Extracts a rich, cinema-grade dark ambient background color matching the
  /// poster's top/bottom edge palette so the Detail Screen background and
  /// top/bottom poster gradients blend seamlessly with zero visual seam.
  static Future<Color> extractEdgeAmbientColor(Uint8List bytes) async {
    final fp = _bytesFingerprint(bytes);
    final cached = _ambientColorCache[fp];
    if (cached != null) return cached;
    try {
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 24,
        targetHeight: 36,
      );
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final byteData = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      image.dispose();
      if (byteData != null) {
        final data = byteData.buffer.asUint8List();
        const w = 24;
        const h = 36;
        double rSum = 0;
        double gSum = 0;
        double bSum = 0;
        double weightSum = 0;
        for (int y = 0; y < h; y++) {
          final isBottomBand = y >= (h * 0.62);
          final isTopBand = y <= (h * 0.18);
          final rowWeight = isBottomBand ? 2.6 : (isTopBand ? 1.4 : 0.6);
          for (int x = 0; x < w; x++) {
            final idx = (y * w + x) * 4;
            if (idx + 3 >= data.length) continue;
            final r = data[idx].toDouble();
            final g = data[idx + 1].toDouble();
            final b = data[idx + 2].toDouble();
            final a = data[idx + 3].toDouble() / 255.0;
            if (a < 0.2) continue;
            final maxC = r > g ? (r > b ? r : b) : (g > b ? g : b);
            final minC = r < g ? (r < b ? r : b) : (g < b ? g : b);
            final sat = maxC > 0 ? (maxC - minC) / maxC : 0.0;
            final wgt = rowWeight * (0.65 + sat * 0.85) * a;
            rSum += r * wgt;
            gSum += g * wgt;
            bSum += b * wgt;
            weightSum += wgt;
          }
        }
        if (weightSum > 0) {
          var rAvg = rSum / weightSum;
          var gAvg = gSum / weightSum;
          var bAvg = bSum / weightSum;
          final luma = 0.299 * rAvg + 0.587 * gAvg + 0.114 * bAvg;
          if (luma > 44.0) {
            final scale = 40.0 / luma;
            rAvg *= scale;
            gAvg *= scale;
            bAvg *= scale;
          } else if (luma < 16.0 && luma > 0.5) {
            final scale = 20.0 / luma;
            rAvg = (rAvg * scale).clamp(12.0, 58.0);
            gAvg = (gAvg * scale).clamp(10.0, 54.0);
            bAvg = (bAvg * scale).clamp(12.0, 62.0);
          }
          final color = Color.fromARGB(
            255,
            rAvg.round().clamp(10, 68),
            gAvg.round().clamp(9, 62),
            bAvg.round().clamp(10, 72),
          );
          _ambientColorCache[fp] = color;
          return color;
        }
      }
    } catch (_) {}
    const fallback = Color(0xFF1A1512);
    _ambientColorCache[fp] = fallback;
    return fallback;
  }

  static int _bytesFingerprint(Uint8List b) {
    if (b.isEmpty) return 0;
    int h = b.length;
    final step = (b.length ~/ 16).clamp(1, 4096);
    for (int i = 0; i < b.length; i += step) {
      h = ((h ^ b[i]) * 0x01000193) & 0x7fffffff;
    }
    return h;
  }

  /// Returns cached series synopsis if already resolved.
  static String peekSeriesSynopsis(String rawTitle) {
    final clean = _cleanTitle(rawTitle);
    return _titleSynopsisCache[clean] ?? '';
  }

  /// Returns cached or fetched series synopsis from Baidu Baike / Bangumi / Douban.
  static Future<String> fetchSeriesSynopsis(String rawTitle) async {
    final clean = _cleanTitle(rawTitle);
    if (clean.isEmpty) return '';
    final cached = _titleSynopsisCache[clean];
    if (cached != null && cached.isNotEmpty) return cached;
    await _resolveCoverUrlsByTitle(clean);
    return _titleSynopsisCache[clean] ?? '';
  }

  /// Synchronously peeks cached real metadata for 1-based [episodeNumber].
  static EpisodeRealMeta? peekEpisodeMeta(
    String rawTitle,
    int episodeNumber,
  ) {
    final clean = _cleanTitle(rawTitle);
    if (clean.isEmpty) return null;
    return _seriesEpisodeMetaCache[clean]?[episodeNumber];
  }

  /// Synchronously peeks all cached real episode metadata for [rawTitle].
  static Map<int, EpisodeRealMeta> peekAllEpisodeMeta(String rawTitle) {
    final clean = _cleanTitle(rawTitle);
    if (clean.isEmpty) return const {};
    return _seriesEpisodeMetaCache[clean] ?? const {};
  }

  /// Returns cached per-episode scene captions if available.
  static List<String> peekSeriesEpisodeCaptions(String rawTitle) {
    final clean = _cleanTitle(rawTitle);
    return _seriesEpisodeCaptionsCache[clean] ?? const [];
  }

  /// Resolves real per-episode plot summaries (`分集剧情`), real episode titles,
  /// and real 16:9 episode frame covers from:
  /// 1. 360 Baike `tvplot` (`baike.so.com` structured `<dl><dt>第X集</dt><dd>...</dd>`)
  /// 2. Bilibili PGC (`api.bilibili.com/x/web-interface/search/type` `media_bangumi` & `media_ft`)
  /// 3. Bangumi Official Open API (`api.bgm.tv/v0/episodes`)
  static Future<Map<int, EpisodeRealMeta>> fetchSeriesEpisodeMetadata(
    String rawTitle,
  ) {
    final clean = _cleanTitle(rawTitle);
    if (clean.isEmpty) {
      return SynchronousFuture<Map<int, EpisodeRealMeta>>(const {});
    }
    final cached = _seriesEpisodeMetaCache[clean];
    if (cached != null && cached.isNotEmpty) {
      return SynchronousFuture<Map<int, EpisodeRealMeta>>(cached);
    }
    final pending = _inflightEpisodeMeta[clean];
    if (pending != null) return pending;

    final future = () async {
      final result = <int, EpisodeRealMeta>{};
      void upsert(
        int epNum, {
        String? title,
        String? summary,
        String? coverUrl,
      }) {
        if (epNum <= 0) return;
        final existing = result[epNum] ?? EpisodeRealMeta(episodeNumber: epNum);
        result[epNum] = existing.mergeWith(
          title: title,
          summary: summary,
          coverUrl: coverUrl,
        );
      }

      final variants = _queryVariantsForTitle(clean);
      final primary = variants.isNotEmpty ? variants.first : clean;

      await Future.wait([
        // Source 1: 360 Baike `tvplot` (Real per-episode titles & plot summaries)
        () async {
          final searchQueries = <String>[
            '$primary 分集剧情',
            primary,
            if (variants.length >= 2) '${variants[1]} 分集剧情',
          ];
          for (final sq in searchQueries) {
            if (result.length >= 5) break;
            HttpClientRequest? req;
            try {
              final uri = Uri.parse(
                'https://baike.so.com/search/?q=${Uri.encodeQueryComponent(sq)}',
              );
              req = await _client
                  .getUrl(uri)
                  .timeout(const Duration(milliseconds: 2800));
              req.headers.set('User-Agent', _desktopChromeUa);
              req.headers.set('Accept', 'text/html,*/*;q=0.8');
              final resp = await req
                  .close()
                  .timeout(const Duration(milliseconds: 2800));
              if (resp.statusCode >= 200 && resp.statusCode < 300) {
                final searchHtml = await utf8.decoder
                    .bind(resp)
                    .join()
                    .timeout(const Duration(milliseconds: 2800));
                final docLinks = RegExp(
                  r'https?://baike\.so\.com/doc/\d+-\d+\.html',
                )
                    .allMatches(searchHtml)
                    .map((m) => m.group(0)!)
                    .toSet()
                    .take(2)
                    .toList();
                for (final docUrl in docLinks) {
                  await _parse360BaikeDoc(docUrl, clean, upsert);
                  if (result.isNotEmpty) break;
                }
              } else {
                await resp.drain<void>();
              }
            } catch (_) {
              try {
                req?.abort();
              } catch (_) {}
            }
          }
        }(),

        // Source 2: Bilibili PGC Search (`media_bangumi` & `media_ft`) for real 16:9 episode covers & titles
        () async {
          for (final stype in const ['media_bangumi', 'media_ft']) {
            for (final qv in variants.take(2)) {
              HttpClientRequest? req;
              try {
                final uri = Uri.parse(
                  'https://api.bilibili.com/x/web-interface/search/type?search_type=$stype&keyword=${Uri.encodeQueryComponent(qv)}',
                );
                req = await _client
                    .getUrl(uri)
                    .timeout(const Duration(milliseconds: 2800));
                req.headers.set('User-Agent', _desktopChromeUa);
                req.headers.set('Referer', 'https://search.bilibili.com/');
                req.headers.set('Cookie', _biliCookie);
                req.headers.set('Accept', 'application/json, text/plain, */*');
                final resp = await req
                    .close()
                    .timeout(const Duration(milliseconds: 2800));
                if (resp.statusCode >= 200 && resp.statusCode < 300) {
                  final body = await utf8.decoder
                      .bind(resp)
                      .join()
                      .timeout(const Duration(milliseconds: 2800));
                  final decoded = jsonDecode(body);
                  if (decoded is Map) {
                    final data = decoded['data'];
                    final list = data is Map ? data['result'] : null;
                    if (list is List && list.isNotEmpty) {
                      Map? matchedItem;
                      for (final item in list) {
                        if (item is Map) {
                          final rawItemTitle =
                              (item['title'] ?? '').toString().trim();
                          if (_isSameWorkTitle(rawItemTitle, rawTitle) ||
                              _isSameWorkTitle(rawItemTitle, clean)) {
                            matchedItem = item;
                            break;
                          }
                        }
                      }
                      if (matchedItem != null) {
                        final evaluate =
                            (matchedItem['desc'] ?? '').toString().trim();
                        if (evaluate.length >= 16 &&
                            !_titleSynopsisCache.containsKey(clean)) {
                          _titleSynopsisCache[clean] = evaluate;
                        }
                        final eps = matchedItem['eps'];
                        if (eps is List && eps.isNotEmpty) {
                          for (int i = 0; i < eps.length; i++) {
                            final ep = eps[i];
                            if (ep is Map) {
                              final rawIdx =
                                  (ep['title'] ?? ep['index_title'] ?? '')
                                      .toString()
                                      .trim();
                              final parsedNum = int.tryParse(
                                    RegExp(r'\d+')
                                            .firstMatch(rawIdx)
                                            ?.group(0) ??
                                        '',
                                  ) ??
                                  (i + 1);
                              final longTitle = (ep['long_title'] ?? '')
                                  .toString()
                                  .replaceAll(RegExp(r'<[^>]+>'), '')
                                  .trim();
                              final cover = upgradeUrlToHd(
                                (ep['cover'] ?? '').toString().trim(),
                              );
                              upsert(
                                parsedNum,
                                title: longTitle,
                                coverUrl: cover,
                              );
                            }
                          }
                          break;
                        }
                      }
                    }
                  }
                } else {
                  await resp.drain<void>();
                }
              } catch (_) {
                try {
                  req?.abort();
                } catch (_) {}
              }
            }
          }
        }(),

        // Source 3: Bangumi Official API (`/search/subject` + `/v0/episodes`)
        () async {
          HttpClientRequest? req;
          try {
            final q = Uri.encodeQueryComponent(primary);
            final uri = Uri.parse(
              'https://api.bgm.tv/search/subject/$q?responseGroup=large',
            );
            req = await _client
                .getUrl(uri)
                .timeout(const Duration(milliseconds: 2800));
            req.headers.set('User-Agent', _desktopChromeUa);
            req.headers.set('Accept', 'application/json');
            final resp =
                await req.close().timeout(const Duration(milliseconds: 2800));
            if (resp.statusCode >= 200 && resp.statusCode < 300) {
              final body = await utf8.decoder
                  .bind(resp)
                  .join()
                  .timeout(const Duration(milliseconds: 2800));
              final decoded = jsonDecode(body);
              if (decoded is Map && decoded['list'] is List) {
                final list = decoded['list'] as List;
                Map? matchedSubject;
                for (final item in list) {
                  if (item is Map) {
                    final t = item['type'];
                    if (t != 2 && t != 6) continue;
                    final nameCn = (item['name_cn'] ?? '').toString().trim();
                    final name = (item['name'] ?? '').toString().trim();
                    if (_isSameWorkTitle(nameCn, rawTitle) ||
                        _isSameWorkTitle(name, rawTitle) ||
                        _isSameWorkTitle(nameCn, clean) ||
                        _isSameWorkTitle(name, clean)) {
                      matchedSubject = item;
                      break;
                    }
                  }
                }
                if (matchedSubject != null) {
                  final summary =
                      (matchedSubject['summary'] ?? '').toString().trim();
                  if (summary.length >= 16 &&
                      !_titleSynopsisCache.containsKey(clean)) {
                    _titleSynopsisCache[clean] = summary;
                  }
                  final sid = matchedSubject['id'];
                  if (sid != null) {
                    await _fetchBangumiEpisodes(sid, upsert);
                  }
                }
              }
            } else {
              await resp.drain<void>();
            }
          } catch (_) {
            try {
              req?.abort();
            } catch (_) {}
          }
        }(),
      ]);

      if (result.isNotEmpty) {
        _seriesEpisodeMetaCache[clean] = result;
      }
      metadataRevision.value++;
      return result;
    }()
        .whenComplete(() { _inflightEpisodeMeta.remove(clean); });

    _inflightEpisodeMeta[clean] = future;
    return future;
  }

  static Future<void> _fetchBangumiEpisodes(
    Object subjectId,
    void Function(int, {String? title, String? summary, String? coverUrl})
        upsert,
  ) async {
    HttpClientRequest? req;
    try {
      final uri = Uri.parse(
        'https://api.bgm.tv/v0/episodes?subject_id=$subjectId&limit=100&offset=0',
      );
      req = await _client
          .getUrl(uri)
          .timeout(const Duration(milliseconds: 2600));
      req.headers.set('User-Agent', _desktopChromeUa);
      req.headers.set('Accept', 'application/json');
      final resp =
          await req.close().timeout(const Duration(milliseconds: 2600));
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final body = await utf8.decoder
            .bind(resp)
            .join()
            .timeout(const Duration(milliseconds: 2600));
        final decoded = jsonDecode(body);
        if (decoded is Map && decoded['data'] is List) {
          final eps = decoded['data'] as List;
          for (int i = 0; i < eps.length; i++) {
            final ep = eps[i];
            if (ep is Map) {
              final epNum = (ep['ep'] is int && (ep['ep'] as int) > 0)
                  ? ep['ep'] as int
                  : ((ep['sort'] is num && (ep['sort'] as num) > 0)
                      ? (ep['sort'] as num).toInt()
                      : (i + 1));
              final nameCn = (ep['name_cn'] ?? '').toString().trim();
              final name = (ep['name'] ?? '').toString().trim();
              final desc = (ep['desc'] ?? '').toString().trim();
              upsert(
                epNum,
                title: nameCn.isNotEmpty ? nameCn : name,
                summary: desc.length >= 8 ? desc : null,
              );
            }
          }
        }
      } else {
        await resp.drain<void>();
      }
    } catch (_) {
      try {
        req?.abort();
      } catch (_) {}
    }
  }

  static Future<void> _parse360BaikeDoc(
    String docUrl,
    String cleanTitle,
    void Function(int, {String? title, String? summary, String? coverUrl})
        upsert,
  ) async {
    HttpClientRequest? req;
    try {
      final uri = Uri.parse(
        docUrl.startsWith('http://')
            ? docUrl.replaceFirst('http://', 'https://')
            : docUrl,
      );
      req = await _client
          .getUrl(uri)
          .timeout(const Duration(milliseconds: 3000));
      req.headers.set('User-Agent', _desktopChromeUa);
      req.headers.set('Accept', 'text/html,*/*;q=0.8');
      final resp =
          await req.close().timeout(const Duration(milliseconds: 3000));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        await resp.drain<void>();
        return;
      }
      final doc = await utf8.decoder
          .bind(resp)
          .join()
          .timeout(const Duration(milliseconds: 3000));

      // Verify that this 360 Baike document is actually for [cleanTitle]
      // (prevents variety shows without `tvplot` from matching a random TV drama)
      final titleTagMatch =
          RegExp(r'<title>(.*?)</title>', dotAll: true).firstMatch(doc);
      final h1Match =
          RegExp(r'<h1[^>]*>(.*?)</h1>', dotAll: true).firstMatch(doc);
      final docTitleText =
          (titleTagMatch?.group(1) ?? h1Match?.group(1) ?? '').trim();
      if (docTitleText.isEmpty ||
          !_isSameWorkTitle(docTitleText, cleanTitle)) {
        return;
      }
      final tvplotIdx = doc.indexOf('id=tvplot');
      if (tvplotIdx < 0 && !_isFilmOrTvEntryText(doc)) {
        return;
      }

      // Collect anti-scrape hidden CSS class names from <style> blocks
      final hiddenClasses = <String>{};
      final styleBlocks = RegExp(
        r'<style[^>]*>(.*?)</style>',
        dotAll: true,
      ).allMatches(doc);
      for (final sb in styleBlocks) {
        final css = sb.group(1) ?? '';
        for (final rule in css.split('}')) {
          if (rule.contains('display:none') ||
              rule.contains('font-size: 0') ||
              rule.contains('font-size:0') ||
              rule.contains('height:0') ||
              rule.contains('width:0') ||
              rule.contains('visibility:hidden') ||
              rule.contains('opacity:0')) {
            final selectorPart = rule.split('{').first;
            for (final cm
                in RegExp(r'\.([a-zA-Z0-9_-]+)').allMatches(selectorPart)) {
              hiddenClasses.add(cm.group(1)!);
            }
          }
        }
      }

      String cleanBaikeFragment(String frag) {
        var cur = frag;
        String? prev;
        final tagPattern = RegExp(
          r'<(span|em|b|strong|i)\s+class=["\x27]?([a-zA-Z0-9_-]+)["\x27]?[^>]*>(.*?)</\1>',
          dotAll: true,
        );
        int guard = 0;
        while (prev != cur && guard < 6) {
          prev = cur;
          guard++;
          cur = cur.replaceAllMapped(tagPattern, (m) {
            final cls = m.group(2)!;
            final inner = m.group(3)!;
            return hiddenClasses.contains(cls) ? '' : inner;
          });
        }
        return cur
            .replaceAll(RegExp(r'<[^>]+>'), '')
            .replaceAll('&nbsp;', ' ')
            .replaceAll('&quot;', '"')
            .replaceAll('&amp;', '&')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
      }

      final plotRegion = tvplotIdx >= 0 ? doc.substring(tvplotIdx) : doc;
      final dlMatches = RegExp(
        r'<dt>(.*?)</dt>\s*<dd>(.*?)</dd>',
        dotAll: true,
      ).allMatches(plotRegion);

      for (final dm in dlMatches) {
        final dtText = cleanBaikeFragment(dm.group(1) ?? '');
        final ddText = cleanBaikeFragment(dm.group(2) ?? '');
        final epMatch =
            RegExp(r'第\s*(\d+)\s*集\s*(.*)$').firstMatch(dtText);
        if (epMatch != null && ddText.length >= 12) {
          final epNum = int.tryParse(epMatch.group(1)!) ?? 0;
          final epSubTitle = epMatch
              .group(2)!
              .replaceAll(RegExp(r'^[：:·\-\s]+'), '')
              .trim();
          upsert(
            epNum,
            title: epSubTitle,
            summary: ddText,
          );
        }
      }
    } catch (_) {
      try {
        req?.abort();
      } catch (_) {}
    }
  }

  /// Resolves up to 35 distinct 16:9 widescreen scene stills (`剧照 / 画面`)
  /// for [rawTitle] so each episode card in the horizontal episode strip shows
  /// a distinct scene frame from the drama instead of repeating the main cover.
  static Future<List<String>> fetchSeriesEpisodeStills(String rawTitle) {
    final clean = _cleanTitle(rawTitle);
    if (clean.isEmpty) return SynchronousFuture<List<String>>(const []);
    final cached = _seriesEpisodeStillsCache[clean];
    if (cached != null && cached.isNotEmpty) {
      return SynchronousFuture<List<String>>(cached);
    }
    final pending = _inflightSeriesStills[clean];
    if (pending != null) return pending;

    final future = () async {
      // Also kick off real episode metadata resolution in parallel
      unawaited(fetchSeriesEpisodeMetadata(rawTitle));

      final stills = <String>[];
      final captions = <String>[];
      final seenUrls = <String>{};
      final seenCoreIds = <String>{};
      final variants = _queryVariantsForTitle(clean);
      final primaryQuery = variants.isNotEmpty ? variants.first : clean;
      final isShortAmbiguousTitle = clean.length <= 2;
      final queries = <String>[
        '$primaryQuery 电视剧 剧照 画面 -节气 -模板 -素材',
        if (variants.length >= 2)
          '${variants[1]} 电视剧 剧照 画面 -节气 -模板 -素材',
      ];

      for (final qText in queries) {
        if (stills.length >= 28) break;
        HttpClientRequest? req;
        try {
          final q = Uri.encodeQueryComponent(qText);
          final uri = Uri.parse(
            'https://cn.bing.com/images/async?q=$q&first=1&count=35&qft=+filterui:aspect-wide',
          );
          req = await _client
              .getUrl(uri)
              .timeout(const Duration(milliseconds: 2800));
          req.headers.set('User-Agent', _desktopChromeUa);
          req.headers.set('Referer', 'https://cn.bing.com/');
          req.headers.set(
            'Accept',
            'text/html,application/xhtml+xml,*/*;q=0.8',
          );
          final resp =
              await req.close().timeout(const Duration(milliseconds: 2800));
          if (resp.statusCode >= 200 && resp.statusCode < 300) {
            final html = await utf8.decoder
                .bind(resp)
                .join()
                .timeout(const Duration(milliseconds: 2800));
            // Parse each Bing image card (`m="{...}"`) so we can verify its caption
            // before accepting its OIP or murl still
            final cardMatches = RegExp(
              r'm=&quot;(\{[^"]*?\})&quot;',
            ).allMatches(html);
            for (final cm in cardMatches) {
              final cardJsonAttr = cm.group(1) ?? '';
              final tMatch = RegExp(
                r't&quot;:&quot;([^&]{2,80})&quot;',
              ).firstMatch(cardJsonAttr);
              final rawCap = (tMatch?.group(1) ?? '')
                  .replaceAll(RegExp(r'[\u0000-\u001f]'), '')
                  .trim();
              if (_isNonEntertainmentBingCaption(rawCap) ||
                  _isNonEntertainmentBingCaption(cardJsonAttr)) {
                continue;
              }
              if (isShortAmbiguousTitle) {
                final hasDramaContext = rawCap.contains(clean) &&
                    RegExp(
                      r'剧|集|饰|演|导|电影|电视|片|幕|角色|预告|开机|杀青|官宣|剧照|番|动画|综',
                    ).hasMatch(rawCap);
                if (!hasDramaContext) continue;
              }
              final oipMatch = RegExp(
                r'OIP(?:-C)?\.([A-Za-z0-9_-]+)',
              ).firstMatch(cardJsonAttr);
              if (oipMatch != null) {
                final fullId = oipMatch.group(0)!;
                final coreId = oipMatch.group(1)!;
                if (!RegExp(r'Ha[KNLMP][A-Za-z0-9]$').hasMatch(coreId) &&
                    seenCoreIds.add(coreId)) {
                  final u =
                      'https://tse1-mm.cn.bing.net/th/id/$fullId?w=640&h=360&c=7&r=0&o=5&pid=1.7';
                  if (seenUrls.add(u)) {
                    stills.add(u);
                  }
                }
              }
              final murlMatch = RegExp(
                r'murl&quot;:&quot;(https?://[^&"\x27]+?)&quot;',
              ).firstMatch(cardJsonAttr);
              if (murlMatch != null) {
                final rawMurl = upgradeUrlToHd(murlMatch.group(1)!);
                if (_isFastDomesticHost(rawMurl) && seenUrls.add(rawMurl)) {
                  stills.add(rawMurl);
                }
              }
              final cleanCap = rawCap.replaceAll(RegExp(r'[_｜|—\-].*$'), '').trim();
              if (cleanCap.length >= 4 && !captions.contains(cleanCap)) {
                captions.add(cleanCap);
              }
            }
          } else {
            await resp.drain<void>();
          }
        } catch (_) {
          try {
            req?.abort();
          } catch (_) {}
        }
      }

      if (captions.isNotEmpty) {
        _seriesEpisodeCaptionsCache[clean] = captions;
      }
      if (stills.isNotEmpty) {
        _seriesEpisodeStillsCache[clean] = stills;
      }
      metadataRevision.value++;
      return stills;
    }()
        .whenComplete(() { _inflightSeriesStills.remove(clean); });

    _inflightSeriesStills[clean] = future;
    return future;
  }

  static bool _isKnownDeadPosterHost(String url) {
    final lower = url.toLowerCase();
    return lower.contains('mdzypic.com') ||
        lower.contains('pic.ry-pic.com') ||
        lower.contains('macci.cc');
  }

  static bool _isFastDomesticHost(String url) {
    final lower = url.toLowerCase();
    return lower.contains('doubanio.com') ||
        lower.contains('lain.bgm.tv') ||
        lower.contains('bcebos.com') ||
        lower.contains('hdslb.com') ||
        lower.contains('biliimg.com') ||
        lower.contains('qpic.cn') ||
        lower.contains('sinaimg.cn') ||
        lower.contains('bing.net') ||
        lower.contains('tuxiaobei.com') ||
        lower.contains('huya.com') ||
        lower.contains('douyucdn.cn');
  }

  static Future<Uint8List> _loadUncached(
    String rawUrl,
    String rawTitle,
    String cacheKey,
  ) async {
    final cleanTitle = _cleanTitle(rawTitle);
    final titleCacheKey = cleanTitle.isNotEmpty ? 'title:$cleanTitle' : '';
    final hdTitleKey = cleanTitle.isNotEmpty ? 'title_hd:$cleanTitle' : '';

    // 0. If we already have an HD title cover in memory, return it immediately
    if (hdTitleKey.isNotEmpty) {
      final inMemHd = _memory[hdTitleKey];
      if (inMemHd != null) {
        _remember(cacheKey, inMemHd);
        return inMemHd;
      }
    }

    // 1. Check disk cache for HD title cover, URL key, or title key
    if (hdTitleKey.isNotEmpty) {
      final hdDiskFile = await _diskFileFor(hdTitleKey);
      if (hdDiskFile != null) {
        try {
          if (await hdDiskFile.exists()) {
            final bytes = await hdDiskFile.readAsBytes();
            if (_looksLikeImage(bytes)) {
              _remember(hdTitleKey, bytes);
              _remember(cacheKey, bytes);
              if (titleCacheKey.isNotEmpty) _remember(titleCacheKey, bytes);
              return bytes;
            }
          }
        } catch (_) {}
      }
    }

    final diskFile = await _diskFileFor(cacheKey);
    if (diskFile != null) {
      try {
        if (await diskFile.exists()) {
          final bytes = await diskFile.readAsBytes();
          if (_looksLikeImage(bytes)) {
            _remember(cacheKey, bytes);
            if (titleCacheKey.isNotEmpty) _remember(titleCacheKey, bytes);
            return bytes;
          }
        }
      } catch (_) {}
    }
    if (titleCacheKey.isNotEmpty && titleCacheKey != cacheKey) {
      final inMemTitle = _memory[titleCacheKey];
      if (inMemTitle != null) {
        _remember(cacheKey, inMemTitle);
        return inMemTitle;
      }
      final titleDiskFile = await _diskFileFor(titleCacheKey);
      if (titleDiskFile != null) {
        try {
          if (await titleDiskFile.exists()) {
            final bytes = await titleDiskFile.readAsBytes();
            if (_looksLikeImage(bytes)) {
              _remember(cacheKey, bytes);
              _remember(titleCacheKey, bytes);
              return bytes;
            }
          }
        } catch (_) {}
      }
    }

    // 2. If rawUrl is empty or a known dead host, resolve directly by title
    if ((rawUrl.isEmpty || _isKnownDeadPosterHost(rawUrl)) &&
        cleanTitle.isNotEmpty) {
      final bytes = await _resolveTitleCoverBytes(
        cleanTitle,
        cacheKey: titleCacheKey,
      );
      _remember(cacheKey, bytes);
      if (diskFile != null) {
        unawaited(_writeDisk(diskFile, bytes));
      }
      return bytes;
    }

    // 3. If rawUrl is a slow/unverified third-party host and we have a title,
    // race the primary URL against a verified domestic film-DB lookup (starting
    // after 900ms if the primary URL hasn't finished yet). Unverified Bing search
    // is only used if rawUrl completely fails.
    if (rawUrl.isNotEmpty &&
        cleanTitle.isNotEmpty &&
        !_isFastDomesticHost(rawUrl)) {
      final completer = Completer<Uint8List>();
      Object? lastErr;
      int remaining = 2;

      void handleSuccess(Uint8List bytes) {
        if (!completer.isCompleted) {
          _remember(cacheKey, bytes);
          if (titleCacheKey.isNotEmpty) _remember(titleCacheKey, bytes);
          if (diskFile != null) {
            unawaited(_writeDisk(diskFile, bytes));
          }
          completer.complete(bytes);
        }
      }

      void handleError(Object e) {
        lastErr = e;
        remaining--;
        if (remaining <= 0 && !completer.isCompleted) {
          completer.completeError(
            Exception('海报加载失败：${lastErr ?? cacheKey}'),
          );
        }
      }

      unawaited(
        _tryPrimaryUrlAttempts(
          rawUrl,
          maxAttempts: 2,
          perAttemptTimeout: const Duration(milliseconds: 2600),
        ).then(handleSuccess, onError: handleError),
      );

      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 900)).then((_) async {
          if (completer.isCompleted) {
            remaining--;
            return;
          }
          try {
            final bytes = await _resolveTitleCoverBytes(
              cleanTitle,
              cacheKey: titleCacheKey,
              verifiedOnly: true,
            );
            handleSuccess(bytes);
          } catch (e) {
            handleError(e);
          }
        }),
      );

      return completer.future;
    }

    // 4. Standard path for fast domestic URLs or untitled URLs
    try {
      final bytes = await _tryPrimaryUrlAttempts(
        rawUrl,
        maxAttempts: cleanTitle.isNotEmpty ? 2 : 4,
        perAttemptTimeout: const Duration(milliseconds: 3600),
      );
      _remember(cacheKey, bytes);
      if (titleCacheKey.isNotEmpty) _remember(titleCacheKey, bytes);
      if (diskFile != null) {
        unawaited(_writeDisk(diskFile, bytes));
      }
      return bytes;
    } catch (e) {
      if (cleanTitle.isNotEmpty) {
        final bytes = await _resolveTitleCoverBytes(
          cleanTitle,
          cacheKey: titleCacheKey,
        );
        _remember(cacheKey, bytes);
        if (diskFile != null) {
          unawaited(_writeDisk(diskFile, bytes));
        }
        return bytes;
      }
      rethrow;
    }
  }

  static Future<Uint8List> _tryPrimaryUrlAttempts(
    String rawUrl, {
    required int maxAttempts,
    required Duration perAttemptTimeout,
  }) async {
    await _acquire();
    try {
      final attempts = _attemptsFor(rawUrl);
      if (attempts.isEmpty) {
        throw const FormatException('无效的海报地址');
      }
      Object? lastError;
      final count =
          attempts.length < maxAttempts ? attempts.length : maxAttempts;
      for (int i = 0; i < count; i++) {
        final attempt = attempts[i];
        try {
          return await _fetch(
            attempt.$1,
            attempt.$2,
            timeout: perAttemptTimeout,
          );
        } catch (e) {
          lastError = e;
        }
      }
      throw lastError ?? const HttpException('海报请求失败');
    } finally {
      _release();
    }
  }

  /// Deduplicated title-to-bytes resolver.
  static Future<Uint8List> _resolveTitleCoverBytes(
    String cleanTitle, {
    required String cacheKey,
    bool verifiedOnly = false,
  }) {
    final inflightKey = verifiedOnly ? 'verified:$cleanTitle' : cleanTitle;
    final existing = _inflightTitleBytes[inflightKey];
    if (existing != null) return existing;

    final future = () async {
      final urls = await _resolveCoverUrlsByTitle(
        cleanTitle,
        verifiedOnly: verifiedOnly,
      );
      Object? lastError;
      for (final candidateUrl in urls) {
        for (final attempt in _attemptsFor(candidateUrl)) {
          try {
            final bytes = await _fetch(
              attempt.$1,
              attempt.$2,
              timeout: const Duration(milliseconds: 3500),
            );
            final tKey = 'title:$cleanTitle';
            _remember(tKey, bytes);
            if (await isTrueHdPoster(bytes)) {
              _remember('title_hd:$cleanTitle', bytes);
              final hdDisk = await _diskFileFor('title_hd:$cleanTitle');
              if (hdDisk != null) unawaited(_writeDisk(hdDisk, bytes));
            }
            if (cacheKey.isNotEmpty) {
              _remember(cacheKey, bytes);
              final titleDiskFile = await _diskFileFor(cacheKey);
              if (titleDiskFile != null) {
                unawaited(_writeDisk(titleDiskFile, bytes));
              }
            }
            return bytes;
          } catch (e) {
            lastError = e;
          }
        }
      }
      throw lastError ?? Exception('未找到「$cleanTitle」海报');
    }()
        .whenComplete(() { _inflightTitleBytes.remove(inflightKey); });

    _inflightTitleBytes[inflightKey] = future;
    return future;
  }

  /// Resolves candidate 1080p/2K vertical poster URLs for [cleanTitle] across:
  /// 1. Bangumi Official Open API (`api.bgm.tv` `images.large` 1080p/2K covers)
  /// 2. Baidu Baike OpenAPI (`BaikeLemmaCardApi` raw `bcebos.com` official covers, film/TV verified)
  /// 3. Bilibili PGC Search (`api.bilibili.com` `media_bangumi` & `media_ft` raw covers, title verified)
  /// 4. Douban Web Search & `subject_suggest` with `Cookie: bid=...` (`l_ratio_poster`, title verified)
  /// 5. Bing China `cn.bing.com/images/async` original `murl` high-res vertical covers (ONLY when `!verifiedOnly`)
  static Future<List<String>> _resolveCoverUrlsByTitle(
    String cleanTitle, {
    bool forceRefreshHd = false,
    bool verifiedOnly = false,
  }) async {
    if (!forceRefreshHd) {
      if (verifiedOnly) {
        final cachedVerified = _verifiedTitleCoverUrlsCache[cleanTitle];
        if (cachedVerified != null && cachedVerified.isNotEmpty) {
          return cachedVerified;
        }
      } else {
        final cached = _titleCoverUrlsCache[cleanTitle];
        if (cached != null && cached.isNotEmpty) return cached;
      }
    }

    final primaryHdResults = <String>[];
    final murlHdResults = <String>[];
    final bingOipFallbackResults = <String>[];
    final seen = <String>{};

    void addPrimaryHd(String raw) {
      final hd = upgradeUrlToHd(raw);
      if (hd.startsWith('http') && seen.add(hd)) {
        primaryHdResults.add(hd);
      }
    }

    void addMurlHd(String raw) {
      final hd = upgradeUrlToHd(raw);
      if (hd.startsWith('http') && seen.add(hd)) {
        murlHdResults.add(hd);
      }
    }

    void addBingOip(String raw) {
      final hd = upgradeUrlToHd(raw);
      if (hd.startsWith('http') && seen.add(hd)) {
        bingOipFallbackResults.add(hd);
      }
    }

    final variants = _queryVariantsForTitle(cleanTitle);
    final primary = variants.isNotEmpty ? variants.first : cleanTitle;
    final bidCookie = 'bid=${_randomDoubanBid()}';

    await Future.wait([
      // Source 1: Bangumi Official Open API (`api.bgm.tv/search/subject/...`) — 1080p/2K `images.large`
      () async {
        for (final qv in variants.take(2)) {
          if (primaryHdResults.isNotEmpty) break;
          HttpClientRequest? req;
          try {
            final q = Uri.encodeQueryComponent(qv);
            final uri = Uri.parse(
              'https://api.bgm.tv/search/subject/$q?responseGroup=large',
            );
            req = await _client
                .getUrl(uri)
                .timeout(const Duration(milliseconds: 2600));
            req.headers.set('User-Agent', _desktopChromeUa);
            req.headers.set('Accept', 'application/json');
            final resp =
                await req.close().timeout(const Duration(milliseconds: 2600));
            if (resp.statusCode >= 200 && resp.statusCode < 300) {
              final body = await utf8.decoder
                  .bind(resp)
                  .join()
                  .timeout(const Duration(milliseconds: 2600));
              final decoded = jsonDecode(body);
              if (decoded is Map && decoded['list'] is List) {
                final list = decoded['list'] as List;
                for (final item in list) {
                  if (item is Map) {
                    final t = item['type'];
                    // Prefer anime (type=2) and TV/film (type=6), skip books (type=1)
                    if (t != 2 && t != 6) continue;
                    final nameCn = (item['name_cn'] ?? '').toString().trim();
                    final name = (item['name'] ?? '').toString().trim();
                    if (!_isSameWorkTitle(nameCn, cleanTitle) &&
                        !_isSameWorkTitle(name, cleanTitle)) {
                      continue;
                    }
                    final images = item['images'];
                    if (images is Map) {
                      final large = (images['large'] ?? '').toString().trim();
                      if (large.startsWith('http')) {
                        addPrimaryHd(large);
                      }
                    }
                    final summary = (item['summary'] ?? '').toString().trim();
                    if (summary.length >= 16 &&
                        !_titleSynopsisCache.containsKey(cleanTitle)) {
                      _titleSynopsisCache[cleanTitle] = summary;
                      metadataRevision.value++;
                    }
                  }
                }
              }
            } else {
              await resp.drain<void>();
            }
          } catch (_) {
            try {
              req?.abort();
            } catch (_) {}
          }
        }
      }(),

      // Source 2: Baidu Baike OpenAPI LemmaCard (`BaikeLemmaCardApi` raw `bcebos.com` poster + official synopsis)
      // Explicitly verifies film/TV/anime/variety attributes so homonyms like《谷雨》(solar term)
      // are never mistaken for TV drama posters.
      () async {
        final baikeKeys = <String>[
          for (final qv in variants.take(2)) ...[
            qv,
            '${qv}电视剧',
            '${qv}电影',
          ],
        ];
        for (final bkKey in baikeKeys) {
          HttpClientRequest? req;
          try {
            final q = Uri.encodeQueryComponent(bkKey);
            final uri = Uri.parse(
              'https://baike.baidu.com/api/openapi/BaikeLemmaCardApi?scope=103&format=json&appid=379020&bk_key=$q&bk_length=600',
            );
            req = await _client
                .getUrl(uri)
                .timeout(const Duration(milliseconds: 2500));
            req.headers.set('User-Agent', _desktopChromeUa);
            req.headers.set('Accept', 'application/json, text/plain, */*');
            final resp =
                await req.close().timeout(const Duration(milliseconds: 2500));
            if (resp.statusCode >= 200 && resp.statusCode < 300) {
              final body = await utf8.decoder
                  .bind(resp)
                  .join()
                  .timeout(const Duration(milliseconds: 2500));
              final decoded = jsonDecode(body);
              if (decoded is Map) {
                final lemmaTitle = (decoded['title'] ?? '')
                    .toString()
                    .replaceAll(RegExp(r'(?:电视剧|电影)$'), '')
                    .trim();
                final titleMatches = lemmaTitle.isEmpty ||
                    _isSameWorkTitle(lemmaTitle, cleanTitle);
                final abstractText =
                    (decoded['abstract'] ?? '').toString().trim();
                final descText = (decoded['desc'] ?? '').toString().trim();
                final isFilmOrTv =
                    _isFilmOrTvEntryText('$abstractText $descText');
                if (titleMatches &&
                    isFilmOrTv &&
                    abstractText.length >= 18) {
                  _titleSynopsisCache[cleanTitle] = abstractText;
                  metadataRevision.value++;
                }
                final rawImg = (decoded['image'] ?? '').toString().trim();
                if (titleMatches && isFilmOrTv && rawImg.startsWith('http')) {
                  addPrimaryHd(rawImg);
                  break;
                }
              }
            } else {
              await resp.drain<void>();
            }
          } catch (_) {
            try {
              req?.abort();
            } catch (_) {}
          }
        }
      }(),

      // Source 3: Bilibili PGC Search (`media_bangumi` & `media_ft`) — strict title verification
      () async {
        for (final stype in const ['media_bangumi', 'media_ft']) {
          HttpClientRequest? req;
          try {
            final q = Uri.encodeQueryComponent(primary);
            final uri = Uri.parse(
              'https://api.bilibili.com/x/web-interface/search/type?search_type=$stype&keyword=$q',
            );
            req = await _client
                .getUrl(uri)
                .timeout(const Duration(milliseconds: 2500));
            req.headers.set('User-Agent', _desktopChromeUa);
            req.headers.set('Referer', 'https://search.bilibili.com/');
            req.headers.set('Cookie', _biliCookie);
            req.headers.set('Accept', 'application/json');
            final resp =
                await req.close().timeout(const Duration(milliseconds: 2500));
            if (resp.statusCode >= 200 && resp.statusCode < 300) {
              final body = await utf8.decoder
                  .bind(resp)
                  .join()
                  .timeout(const Duration(milliseconds: 2500));
              final decoded = jsonDecode(body);
              if (decoded is Map) {
                final data = decoded['data'];
                final list = data is Map ? data['result'] : null;
                if (list is List && list.isNotEmpty) {
                  for (final item in list.take(4)) {
                    if (item is Map) {
                      final rawItemTitle = (item['title'] ?? '')
                          .toString()
                          .replaceAll(RegExp(r'<[^>]+>'), '')
                          .trim();
                      if (!_isSameWorkTitle(rawItemTitle, cleanTitle)) {
                        continue;
                      }
                      final cover = (item['cover'] ?? '').toString().trim();
                      if (cover.isNotEmpty) {
                        addPrimaryHd(cover);
                      }
                    }
                  }
                }
              }
            } else {
              await resp.drain<void>();
            }
          } catch (_) {
            try {
              req?.abort();
            } catch (_) {}
          }
        }
      }(),

      // Source 4: Douban Subject Suggest & Search with `Cookie: bid=...` — strict title verification
      () async {
        for (final variant in variants.take(2)) {
          HttpClientRequest? req;
          try {
            final q = Uri.encodeQueryComponent(variant);
            final uri = Uri.parse(
              'https://movie.douban.com/j/subject_suggest?q=$q',
            );
            req = await _client
                .getUrl(uri)
                .timeout(const Duration(milliseconds: 2200));
            req.headers.set('User-Agent', _desktopChromeUa);
            req.headers.set('Referer', 'https://movie.douban.com/');
            req.headers.set('Cookie', bidCookie);
            req.headers.set('Accept', 'application/json, text/plain, */*');
            final resp =
                await req.close().timeout(const Duration(milliseconds: 2200));
            if (resp.statusCode >= 200 && resp.statusCode < 300) {
              final body = await utf8.decoder
                  .bind(resp)
                  .join()
                  .timeout(const Duration(milliseconds: 2200));
              final decoded = jsonDecode(body);
              if (decoded is List && decoded.isNotEmpty) {
                for (final item in decoded) {
                  if (item is Map) {
                    final itemTitle =
                        (item['title'] ?? '').toString().trim();
                    final itemSubTitle =
                        (item['sub_title'] ?? '').toString().trim();
                    if (!_isSameWorkTitle(itemTitle, cleanTitle) &&
                        !_isSameWorkTitle(itemSubTitle, cleanTitle)) {
                      continue;
                    }
                    final img = (item['img'] ?? '').toString().trim();
                    if (img.startsWith('http')) {
                      addPrimaryHd(img);
                    }
                  }
                }
                if (primaryHdResults.isNotEmpty) break;
              }
            } else {
              await resp.drain<void>();
            }
          } catch (_) {
            try {
              req?.abort();
            } catch (_) {}
          }
        }
      }(),

      // Source 5: Bing China Original High-Res `murl` Vertical Posters + OIP fallback
      // (Only queried when `!verifiedOnly`, and strictly filtered against solar terms / templates)
      if (!verifiedOnly)
        () async {
          HttpClientRequest? req;
          try {
            final query = Uri.encodeQueryComponent(
              '$primary 电视剧 电影 官方海报 竖版 -节气 -二十四节气 -模板 -素材',
            );
            final uri = Uri.parse(
              'https://cn.bing.com/images/async?q=$query&first=0&count=12&qft=+filterui:aspect-tall',
            );
            req = await _client
                .getUrl(uri)
                .timeout(const Duration(milliseconds: 2400));
            req.headers.set('User-Agent', _desktopChromeUa);
            req.headers.set('Referer', 'https://cn.bing.com/');
            req.headers.set(
              'Accept',
              'text/html,application/xhtml+xml,*/*;q=0.8',
            );
            final resp =
                await req.close().timeout(const Duration(milliseconds: 2400));
            if (resp.statusCode >= 200 && resp.statusCode < 300) {
              final html = await utf8.decoder
                  .bind(resp)
                  .join()
                  .timeout(const Duration(milliseconds: 2400));
              final cardMatches = RegExp(
                r'm=&quot;(\{[^"]*?\})&quot;',
              ).allMatches(html);
              for (final cm in cardMatches) {
                final cardJsonAttr = cm.group(1) ?? '';
                final tMatch = RegExp(
                  r't&quot;:&quot;([^&]{2,80})&quot;',
                ).firstMatch(cardJsonAttr);
                final rawCap = (tMatch?.group(1) ?? '').trim();
                if (_isNonEntertainmentBingCaption(rawCap) ||
                    _isNonEntertainmentBingCaption(cardJsonAttr)) {
                  continue;
                }
                if (cleanTitle.length <= 2) {
                  final hasFilmContext = rawCap.contains(cleanTitle) &&
                      RegExp(
                        r'剧|集|饰|演|导|电影|电视|片|角色|海报|预告|官宣|番|动画|综',
                      ).hasMatch(rawCap);
                  if (!hasFilmContext) continue;
                }
                final mm = RegExp(
                  r'murl&quot;:&quot;(https?://[^&"\x27]+?)&quot;',
                ).firstMatch(cardJsonAttr);
                if (mm != null && murlHdResults.length < 5) {
                  addMurlHd(mm.group(1)!);
                }
                final om = RegExp(
                  r'OIP(?:-C)?\.[A-Za-z0-9_-]+',
                ).firstMatch(cardJsonAttr);
                if (om != null && bingOipFallbackResults.length < 3) {
                  final oipId = om.group(0)!;
                  addBingOip(
                    'https://tse1-mm.cn.bing.net/th/id/$oipId?w=720&h=1080&c=7&r=0&o=5&pid=1.7',
                  );
                }
              }
            } else {
              await resp.drain<void>();
            }
          } catch (_) {
            try {
              req?.abort();
            } catch (_) {}
          }
        }(),
    ]);

    if (primaryHdResults.isNotEmpty) {
      _verifiedTitleCoverUrlsCache[cleanTitle] =
          List<String>.unmodifiable(primaryHdResults);
    }
    if (verifiedOnly) {
      return primaryHdResults;
    }

    final results = <String>[
      ...primaryHdResults,
      ...murlHdResults,
      ...bingOipFallbackResults,
    ];
    if (results.isNotEmpty) {
      _titleCoverUrlsCache[cleanTitle] = results;
    }
    return results;
  }

  static Future<void> _acquire() async {
    if (_active < _maxConcurrent) {
      _active++;
      return;
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    await waiter.future;
    _active++;
  }

  static void _release() {
    _active--;
    if (_waiters.isNotEmpty) {
      _waiters.removeLast().complete();
    }
  }

  static void _remember(String key, Uint8List bytes) {
    if (key.isEmpty) return;
    final old = _memory.remove(key);
    if (old != null) _memoryBytes -= old.length;
    _memory[key] = bytes;
    _memoryBytes += bytes.length;
    while (_memoryBytes > _maxMemoryBytes && _memory.isNotEmpty) {
      final oldestKey = _memory.keys.first;
      final removed = _memory.remove(oldestKey);
      if (removed != null) _memoryBytes -= removed.length;
    }
    // Broadcast to all mounted PosterImage widgets so scrolling lists refresh immediately
    cacheRevision.value++;
  }

  /// Builds an ordered list of `(url, headers)` attempts for one poster.
  static List<(String, Map<String, String>)> _attemptsFor(String raw) {
    if (CatPawHost.matches(raw)) return [(raw, const <String,String>{})];
    var url = raw;
    final embedded = <String, String>{};
    final marker = RegExp(r'@(Referer|User-Agent|referer|user-agent)=');
    final matches = marker.allMatches(raw).toList();
    if (matches.isNotEmpty) {
      url = raw.substring(0, matches.first.start);
      for (int i = 0; i < matches.length; i++) {
        final m = matches[i];
        final end = i + 1 < matches.length ? matches[i + 1].start : raw.length;
        final name =
            m.group(1)!.toLowerCase() == 'referer' ? 'Referer' : 'User-Agent';
        final value = raw.substring(m.end, end).trim();
        if (value.isNotEmpty && !value.contains('\n')) embedded[name] = value;
      }
    }
    url = upgradeUrlToHd(url);
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      return const [];
    }
    final host = uri.host.toLowerCase();
    final attempts = <(String, Map<String, String>)>[];
    final seen = <String>{};
    void add(String u, Map<String, String> h) {
      final sig = '$u|${h['User-Agent']}|${h['Referer']}';
      if (seen.add(sig)) attempts.add((u, h));
    }

    if (host.endsWith('doubanio.com')) {
      final nodes = <String>[
        if (host != 'img9.doubanio.com') host,
        'img3.doubanio.com',
        'img1.doubanio.com',
        'img2.doubanio.com',
      ];
      for (final node in nodes) {
        final swapped = uri.replace(host: node, scheme: 'https').toString();
        add(swapped, const {
          'User-Agent': _desktopChromeUa,
          'Referer': 'https://movie.douban.com/',
          'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
        });
        add(swapped, const {
          'User-Agent': _mobileSafariUa,
          'Referer': 'https://m.douban.com/',
          'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
        });
      }
      if (url.contains('/l_ratio_poster/')) {
        final mUrl = uri
            .replace(
              host: 'img3.doubanio.com',
              scheme: 'https',
              path:
                  uri.path.replaceFirst('/l_ratio_poster/', '/m_ratio_poster/'),
            )
            .toString();
        add(mUrl, const {
          'User-Agent': _desktopChromeUa,
          'Referer': 'https://movie.douban.com/',
          'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
        });
      }
      return attempts;
    }
    if (host.endsWith('bgm.tv')) {
      add(uri.replace(scheme: 'https').toString(), const {
        'User-Agent': _desktopChromeUa,
        'Referer': 'https://bgm.tv/',
        'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
      });
      return attempts;
    }
    if (host.endsWith('bcebos.com')) {
      add(uri.replace(scheme: 'https').toString(), const {
        'User-Agent': _desktopChromeUa,
        'Referer': 'https://baike.baidu.com/',
        'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
      });
      return attempts;
    }
    if (host.endsWith('qpic.cn')) {
      add(uri.replace(scheme: 'https').toString(), const {
        'User-Agent': _desktopChromeUa,
        'Referer': 'https://v.qq.com/',
        'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
      });
      return attempts;
    }
    if (host.endsWith('sinaimg.cn')) {
      add(uri.replace(scheme: 'https').toString(), const {
        'User-Agent': _desktopChromeUa,
        'Referer': 'https://weibo.com/',
        'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
      });
      return attempts;
    }
    if (host.endsWith('bing.net')) {
      add(uri.replace(scheme: 'https').toString(), const {
        'User-Agent': _desktopSafariUa,
        'Referer': 'https://cn.bing.com/',
        'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
      });
      return attempts;
    }
    if (host.endsWith('hdslb.com') ||
        host.endsWith('bilibili.com') ||
        host.endsWith('biliimg.com')) {
      add(uri.replace(scheme: 'https').toString(), const {
        'User-Agent': _desktopChromeUa,
        'Referer': 'https://www.bilibili.com/',
      });
    }
    const accept = 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8';
    final origin =
        '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}/';
    if (embedded.isNotEmpty) {
      add(url, {
        'User-Agent': embedded['User-Agent'] ?? _tvBoxUa,
        if (embedded['Referer'] != null) 'Referer': embedded['Referer']!,
        'Accept': accept,
      });
    }
    add(
      url,
      {'User-Agent': _mobileSafariUa, 'Referer': origin, 'Accept': accept},
    );
    add(url, const {'User-Agent': _tvBoxUa, 'Accept': accept});
    add(url, const {'User-Agent': _desktopSafariUa, 'Accept': accept});
    final altScheme = uri.scheme == 'https' ? 'http' : 'https';
    add(uri.replace(scheme: altScheme).toString(), const {
      'User-Agent': _tvBoxUa,
      'Accept': accept,
    });
    return attempts;
  }

  static Future<Uint8List> _fetch(
    String url,
    Map<String, String> headers, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    HttpClientRequest? request;
    try {
      if (CatPawHost.matches(url)) url = (await CatPawHost.instance.resolve(url)).toString();
      final privateImage = EmbyLibrary.isImage(url);
      final scopedHeaders = privateImage ? await EmbyLibrary.imageHeaders(url) : const <String,String>{};
      request = await _client.getUrl(Uri.parse(url).removeFragment()).timeout(timeout);
      request.followRedirects = !privateImage;
      request.maxRedirects = 6;
      headers.forEach((k, v) => request!.headers.set(k, v));
      scopedHeaders.forEach((k,v) => request!.headers.set(k,v));
      final response = await request.close().timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.drain<void>();
        throw HttpException(
          'HTTP ${response.statusCode}',
          uri: Uri.tryParse(url),
        );
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(timeout)) {
        builder.add(chunk);
        if (builder.length > _maxImageBytes) {
          throw const HttpException('图片超过大小上限');
        }
      }
      final bytes = builder.takeBytes();
      if (!_looksLikeImage(bytes)) {
        throw const FormatException('服务器返回的不是图片');
      }
      return bytes;
    } catch (e) {
      try {
        request?.abort();
      } catch (_) {}
      rethrow;
    }
  }

  static bool _looksLikeImage(Uint8List b) {
    if (b.length < 12) return false;
    if (b[0] == 0xFF && b[1] == 0xD8) return true; // JPEG
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
      return true; // PNG
    }
    if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return true; // GIF
    if (b[0] == 0x52 &&
        b[1] == 0x49 &&
        b[2] == 0x46 &&
        b[3] == 0x46 &&
        b[8] == 0x57 &&
        b[9] == 0x45 &&
        b[10] == 0x42 &&
        b[11] == 0x50) {
      return true; // WEBP
    }
    if (b[0] == 0x42 && b[1] == 0x4D) return true; // BMP
    if (b[4] == 0x66 && b[5] == 0x74 && b[6] == 0x79 && b[7] == 0x70) {
      return true; // AVIF/HEIC
    }
    return false;
  }

  static Future<File?> _diskFileFor(String key) async {
    if (!_diskReady) {
      _diskReady = true;
      try {
        final dir = Directory(
          '${Directory.systemTemp.path}${Platform.pathSeparator}marco_poster_cache_v4',
        );
        if (!await dir.exists()) await dir.create(recursive: true);
        _diskDir = dir;
      } catch (_) {
        _diskDir = null;
      }
    }
    final dir = _diskDir;
    if (dir == null) return null;
    return File('${dir.path}${Platform.pathSeparator}${_fnv1a64(key)}.img');
  }

  static Future<void> _writeDisk(File file, Uint8List bytes) async {
    try {
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file.path);
    } catch (_) {}
  }

  static String _fnv1a64(String input) {
    int h1 = 0x811C9DC5;
    int h2 = 0x050C5D1F;
    for (final unit in input.codeUnits) {
      h1 = ((h1 ^ unit) * 0x01000193) & 0xFFFFFFFF;
      h2 = ((h2 ^ (unit + 31)) * 0x01000193) & 0xFFFFFFFF;
    }
    return '${h1.toRadixString(16).padLeft(8, '0')}${h2.toRadixString(16).padLeft(8, '0')}';
  }
}

/// [ImageProvider] backed by [PosterLoader] for direct provider consumers.
@immutable
class MarcoPosterProvider extends ImageProvider<MarcoPosterProvider> {
  final String url;
  final String title;
  const MarcoPosterProvider(this.url, {this.title = ''});

  @override
  Future<MarcoPosterProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<MarcoPosterProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    MarcoPosterProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadCodec(key, decode),
      scale: 1.0,
      debugLabel: key.url,
    );
  }

  Future<ui.Codec> _loadCodec(
    MarcoPosterProvider key,
    ImageDecoderCallback decode,
  ) async {
    try {
      final bytes = await PosterLoader.load(key.url, title: key.title);
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      return decode(buffer);
    } catch (e) {
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is MarcoPosterProvider &&
      other.url == url &&
      other.title == title;

  @override
  int get hashCode => Object.hash(url, title);

  @override
  String toString() => 'MarcoPosterProvider("$url", title: "$title")';
}

/// Stateful poster widget that loads verified image bytes via [PosterLoader],
/// listens to [PosterLoader.cacheRevision] so scrolling lists refresh in real time,
/// keeps loaded cards alive during scroll, and upgrades low-res thumbnails to
/// true 1080p/2K posters when [highRes] is enabled.
class PosterImage extends StatefulWidget {
  final String url;
  final String title;
  final BoxFit fit;
  final AlignmentGeometry alignment;
  final Widget placeholder;
  final bool fadeIn;
  final bool highRes;
  final ValueChanged<Uint8List>? onBytesLoaded;

  const PosterImage({
    super.key,
    required this.url,
    required this.placeholder,
    this.title = '',
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.fadeIn = true,
    this.highRes = false,
    this.onBytesLoaded,
  });

  @override
  State<PosterImage> createState() => _PosterImageState();
}

class _PosterImageState extends State<PosterImage>
    with AutomaticKeepAliveClientMixin {
  Uint8List? _bytes;
  bool _loadedSync = false;
  int _retryCount = 0;
  Timer? _retryTimer;

  @override
  bool get wantKeepAlive => _bytes != null;

  @override
  void initState() {
    super.initState();
    PosterLoader.cacheRevision.addListener(_onGlobalCacheUpdated);
    _initLoad();
  }

  @override
  void didUpdateWidget(covariant PosterImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url.trim() != widget.url.trim() ||
        oldWidget.title.trim() != widget.title.trim() ||
        oldWidget.highRes != widget.highRes) {
      _retryTimer?.cancel();
      _retryCount = 0;
      _initLoad();
    }
  }

  @override
  void dispose() {
    PosterLoader.cacheRevision.removeListener(_onGlobalCacheUpdated);
    _retryTimer?.cancel();
    super.dispose();
  }

  void _onGlobalCacheUpdated() {
    if (!mounted) return;
    if (_bytes == null) {
      final hit = PosterLoader.peekMemory(
        widget.url,
        title: widget.title,
        preferHd: widget.highRes,
      );
      if (hit != null) {
        setState(() {
          _bytes = hit;
        });
        updateKeepAlive();
        _notifyBytes(hit);
      }
      return;
    }
    if (widget.highRes && widget.title.trim().isNotEmpty) {
      final hdHit = PosterLoader.peekHdMemory(widget.title);
      if (hdHit != null && !identical(hdHit, _bytes)) {
        setState(() {
          _bytes = hdHit;
        });
        updateKeepAlive();
        _notifyBytes(hdHit);
      }
    }
  }

  void _notifyBytes(Uint8List data) {
    final cb = widget.onBytesLoaded;
    if (cb != null) {
      scheduleMicrotask(() {
        if (mounted) cb(data);
      });
    }
  }

  void _initLoad() {
    final immediate = PosterLoader.peekMemory(
      widget.url,
      title: widget.title,
      preferHd: widget.highRes,
    );
    if (immediate != null) {
      _bytes = immediate;
      _loadedSync = true;
      updateKeepAlive();
      _notifyBytes(immediate);
      if (widget.highRes && widget.title.trim().isNotEmpty) {
        unawaited(_verifyAndUpgradeIfLowRes(immediate, widget.title.trim()));
      }
      return;
    }
    _bytes = null;
    _loadedSync = false;
    updateKeepAlive();
    _fetchBytes();
  }

  Future<void> _verifyAndUpgradeIfLowRes(
    Uint8List currentBytes,
    String requestedTitle,
  ) async {
    final isHd = await PosterLoader.isTrueHdPoster(currentBytes);
    if (!mounted || widget.title.trim() != requestedTitle) return;
    if (!isHd) {
      await _tryUpgradeToHd(requestedTitle, currentBytes.length);
    }
  }

  Future<void> _tryUpgradeToHd(
    String requestedTitle,
    int currentBytesLen,
  ) async {
    if (EmbyLibrary.isImage(widget.url)) return;
    try {
      final hdBytes = await PosterLoader.loadHdByTitle(
        requestedTitle,
        rawUrl: widget.url,
      );
      if (!mounted || widget.title.trim() != requestedTitle) return;
      final isHd = await PosterLoader.isTrueHdPoster(hdBytes);
      if (!mounted) return;
      if (isHd || hdBytes.length > currentBytesLen) {
        setState(() {
          _bytes = hdBytes;
        });
        updateKeepAlive();
        _notifyBytes(hdBytes);
      }
    } catch (_) {}
  }

  Future<void> _fetchBytes() async {
    if (widget.url.trim().isEmpty && widget.title.trim().isEmpty) return;
    final requestedUrl = widget.url.trim();
    final requestedTitle = widget.title.trim();
    try {
      if (widget.highRes && requestedTitle.isNotEmpty && !EmbyLibrary.isImage(requestedUrl)) {
        unawaited(_tryUpgradeToHd(requestedTitle, _bytes?.length ?? 0));
      }
      final data = await PosterLoader.load(
        requestedUrl,
        title: requestedTitle,
      );
      if (!mounted) return;
      if (widget.url.trim() != requestedUrl ||
          widget.title.trim() != requestedTitle) {
        return;
      }
      if (_bytes == null || data.length > _bytes!.length) {
        setState(() {
          _bytes = data;
        });
        updateKeepAlive();
        _notifyBytes(data);
      }
      if (widget.highRes && requestedTitle.isNotEmpty && !EmbyLibrary.isImage(requestedUrl)) {
        unawaited(_verifyAndUpgradeIfLowRes(data, requestedTitle));
      }
    } catch (_) {
      if (!mounted) return;
      if (_retryCount < 2) {
        _retryCount++;
        final delayMs = _retryCount == 1 ? 800 : 2000;
        _retryTimer?.cancel();
        _retryTimer = Timer(Duration(milliseconds: delayMs), () {
          if (mounted && _bytes == null) _fetchBytes();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final bytes = _bytes;
    if (bytes == null) {
      return widget.placeholder;
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final dpr = (MediaQuery.maybeDevicePixelRatioOf(context) ?? 2.0)
            .clamp(2.0, 3.5);
        final isLargeSurface = widget.highRes ||
            (constraints.maxWidth.isFinite && constraints.maxWidth >= 210) ||
            (constraints.maxHeight.isFinite && constraints.maxHeight >= 260);
        int? cacheWidth;
        if (!isLargeSurface &&
            constraints.maxWidth.isFinite &&
            constraints.maxWidth > 0) {
          final effectiveWidth = constraints.maxHeight.isFinite &&
                  constraints.maxHeight * 0.72 > constraints.maxWidth
              ? constraints.maxHeight * 0.72
              : constraints.maxWidth;
          final px = (effectiveWidth * dpr).ceil();
          cacheWidth = ((px + 239) ~/ 240) * 240;
        }
        final ImageProvider provider = isLargeSurface
            ? MemoryImage(bytes)
            : ResizeImage.resizeIfNeeded(
                cacheWidth,
                null,
                MemoryImage(bytes),
              );
        final img = Image(
          image: provider,
          fit: widget.fit,
          alignment: widget.alignment,
          width: constraints.maxWidth.isFinite ? constraints.maxWidth : null,
          height: constraints.maxHeight.isFinite ? constraints.maxHeight : null,
          gaplessPlayback: true,
          isAntiAlias: true,
          filterQuality:
              isLargeSurface ? FilterQuality.high : FilterQuality.medium,
          errorBuilder: (_, __, ___) => widget.placeholder,
        );
        if (_loadedSync || !widget.fadeIn) {
          return img;
        }
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0.0, end: 1.0),
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          builder: (context, opacity, child) => Stack(
            fit: StackFit.passthrough,
            children: [
              if (opacity < 0.99) Positioned.fill(child: widget.placeholder),
              Opacity(opacity: opacity, child: child),
            ],
          ),
          child: img,
        );
      },
    );
  }
}

/// Renders a distinct 16:9 widescreen scene still (`剧照 / 画面`) for a specific
/// [episodeIndex] of [seriesTitle], prioritizing real per-episode Bilibili PGC
/// 16:9 frame covers when available and listening to [PosterLoader.metadataRevision]
/// so scrolling episode strips update immediately.
class EpisodeStillImage extends StatefulWidget {
  final String seriesTitle;
  final int episodeIndex;
  final String fallbackPosterUrl;
  final Widget placeholder;

  const EpisodeStillImage({
    super.key,
    required this.seriesTitle,
    required this.episodeIndex,
    required this.fallbackPosterUrl,
    required this.placeholder,
  });

  @override
  State<EpisodeStillImage> createState() => _EpisodeStillImageState();
}

class _EpisodeStillImageState extends State<EpisodeStillImage>
    with AutomaticKeepAliveClientMixin {
  String? _stillUrl;

  @override
  bool get wantKeepAlive => _stillUrl != null;

  @override
  void initState() {
    super.initState();
    PosterLoader.metadataRevision.addListener(_onMetadataUpdated);
    _resolveStill();
  }

  @override
  void didUpdateWidget(covariant EpisodeStillImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.seriesTitle != widget.seriesTitle ||
        oldWidget.episodeIndex != widget.episodeIndex) {
      _resolveStill();
    }
  }

  @override
  void dispose() {
    PosterLoader.metadataRevision.removeListener(_onMetadataUpdated);
    super.dispose();
  }

  void _onMetadataUpdated() {
    if (!mounted) return;
    _pickFromCaches();
  }

  void _pickFromCaches() {
    final title = widget.seriesTitle.trim();
    if (title.isEmpty) return;
    final epMeta =
        PosterLoader.peekEpisodeMeta(title, widget.episodeIndex + 1);
    if (epMeta != null && epMeta.coverUrl.isNotEmpty) {
      if (_stillUrl != epMeta.coverUrl) {
        setState(() {
          _stillUrl = epMeta.coverUrl;
        });
        updateKeepAlive();
      }
      return;
    }
    final clean = PosterLoader.cleanTitleForQuery(title);
    final cachedStills = PosterLoader._seriesEpisodeStillsCache[clean];
    if (cachedStills != null && cachedStills.isNotEmpty) {
      final picked =
          cachedStills[widget.episodeIndex.abs() % cachedStills.length];
      if (_stillUrl != picked) {
        setState(() {
          _stillUrl = picked;
        });
        updateKeepAlive();
      }
    }
  }

  Future<void> _resolveStill() async {
    _pickFromCaches();
    if (_stillUrl != null && _stillUrl!.isNotEmpty) return;
    final title = widget.seriesTitle.trim();
    if (title.isEmpty) return;
    try {
      await Future.wait([
        PosterLoader.fetchSeriesEpisodeMetadata(title),
        PosterLoader.fetchSeriesEpisodeStills(title),
      ]);
      if (!mounted) return;
      _pickFromCaches();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final still = _stillUrl;
    final double alignY =
        -0.72 + ((widget.episodeIndex * 3) % 7) * 0.22; // -0.72 .. +0.60
    final fallbackPosterWidget = PosterImage(
      url: widget.fallbackPosterUrl,
      title: widget.seriesTitle,
      fit: BoxFit.cover,
      alignment: Alignment(0.0, alignY),
      highRes: true,
      placeholder: widget.placeholder,
    );
    if (still != null && still.isNotEmpty) {
      return PosterImage(
        key: ValueKey(
          'still_${widget.seriesTitle}_${widget.episodeIndex}_$still',
        ),
        url: still,
        title: '',
        fit: BoxFit.cover,
        highRes: true,
        placeholder: fallbackPosterWidget,
      );
    }
    return fallbackPosterWidget;
  }
}
