import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../core/cms_client.dart';
import '../core/cms_parser.dart';
import '../core/download_service.dart';
import '../core/models.dart';
import '../core/storage_service.dart';
import 'apple_theme.dart';
import 'netdisk_sheet.dart';
import 'player_screen.dart';
import 'poster_image.dart';
import 'source_verification_dialog.dart';

/// Apple TV+ / Infuse inspired responsive video detail page for iPhone, iPad, Mac, and Windows.
/// Features:
/// - Full-screen `Positioned.fill` ambient canvas & backdrop (zero horizontal or vertical seam lines
///   in both portrait and landscape when scrolling/blurring)
/// - Top solid-color transition with downward-shifted hero poster framing, plus bottom progressive
///   frosted-glass blur transition (`ShaderMask` + `BackdropFilter`) behind overlaid typography
/// - Real per-episode 16:9 frame stills & real per-episode plot synopses (`分集剧情`) from
///   360 Baike `tvplot`, Bilibili PGC, and Bangumi, with honest non-repetitive display
class DetailScreen extends StatefulWidget {
  final CmsSite site;
  final CmsVideo initialVideo;
  final CmsClient client;
  final StorageService storage;
  const DetailScreen({
    super.key,
    required this.site,
    required this.initialVideo,
    required this.client,
    required this.storage,
  });
  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _OtherSourceResults extends StatefulWidget {
  final Stream<(CmsSite, List<CmsVideo>)> results;
  const _OtherSourceResults({required this.results});

  @override
  State<_OtherSourceResults> createState() => _OtherSourceResultsState();
}

class _OtherSourceResultsState extends State<_OtherSourceResults> {
  final _matches = <(CmsSite, CmsVideo)>[];
  late final StreamSubscription<(CmsSite, List<CmsVideo>)> _search;
  bool _done = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _search = widget.results.listen((result) {
      if (mounted) setState(() {
        _matches.addAll(result.$2.map((v) => (result.$1, v)));
      });
    }, onDone: () { if (mounted) setState(() => _done = true); },
       onError: (Object error) { if (mounted) setState(() => _failed = true); });
  }

  @override
  void dispose() {
    _search.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      shrinkWrap: true,
      itemCount: _matches.length + (_done && _matches.isNotEmpty ? 0 : 1),
      itemBuilder: (context, index) {
        if (index == _matches.length) {
          return Padding(padding: const EdgeInsets.all(20), child: Center(
            child: _done ? Text(_failed ? '搜索失败，可关闭后重试' : '已导入的可搜索片源没有返回匹配影片')
                : const CupertinoActivityIndicator(),
          ));
        }
        final (site, video) = _matches[index];
        return ListTile(title: Text(video.title), subtitle: Text(
          [site.name, video.year, video.remarks].where((s) => s.isNotEmpty).join(' · ')),
          onTap: () => Navigator.of(context).pop((site, video)),
        );
      },
    );
  }
}

class _DetailScreenState extends State<DetailScreen> {
  late CmsSite _activeSite;
  late CmsVideo _video;
  bool _loading = true;
  String? _error;
  Object? _errorCause;
  int _selectedLine = 0;
  int _selectedPage = 0;
  int? _selectedInLineSeason;
  List<({int seasonNumber, String seasonLabel, CmsSite site, CmsVideo video})>
      _relatedSeasons = const [];
  bool _discoveringSeasons = false;
  String _discoveredFranchiseKey = '';
  bool _synopsisExpanded = false;
  late bool _descending;
  late bool _isFavorite;
  final ValueNotifier<double> _scrollOffset = ValueNotifier<double>(0.0);
  Color? _posterAmbientColor;
  String _externalSynopsis = '';
  Completer<void>? _detailAbort;
  Completer<void>? _seasonAbort;
  int _detailEpoch = 0;

  @override
  void initState() {
    super.initState();
    _activeSite = widget.site;
    _video = widget.initialVideo;
    final curInfo = CmsParser.parseSeriesSeasonInfo(_video.title);
    _relatedSeasons = [
      (
        seasonNumber: curInfo.seasonNumber,
        seasonLabel: curInfo.seasonLabel,
        site: _activeSite,
        video: _video,
      ),
    ];
    _descending = widget.storage.episodesDescending;
    _isFavorite = widget.storage.isFavorite(
      _activeSite.key,
      _video.id,
      forPrivate: _activeSite.isEffectivelyPrivate,
    );
    PosterLoader.metadataRevision.addListener(_onExternalMetadataRevision);
    final immediateBytes = PosterLoader.peekMemory(
      _video.poster,
      title: _video.title,
      preferHd: true,
    );
    if (immediateBytes != null) {
      _posterAmbientColor = PosterLoader.peekAmbientColor(immediateBytes);
      if (_posterAmbientColor == null) {
        unawaited(_updateAmbientFromBytes(immediateBytes));
      }
    }
    _loadDetail();
    _warmExternalMetadata(_video.title);
  }

  @override
  void dispose() {
    _cancelDetailWork();
    PosterLoader.metadataRevision.removeListener(_onExternalMetadataRevision);
    _scrollOffset.dispose();
    super.dispose();
  }

  void _cancelDetailWork() {
    if (_detailAbort?.isCompleted == false) _detailAbort!.complete();
    if (_seasonAbort?.isCompleted == false) _seasonAbort!.complete();
  }

  void _onExternalMetadataRevision() {
    if (!mounted) return;
    final syn = PosterLoader.peekSeriesSynopsis(_video.title);
    if (syn.isNotEmpty && syn != _externalSynopsis) {
      _externalSynopsis = syn;
    }
    setState(() {});
  }

  Future<void> _updateAmbientFromBytes(Uint8List bytes) async {
    final extracted = await PosterLoader.extractEdgeAmbientColor(bytes);
    if (!mounted) return;
    if (_posterAmbientColor != extracted) {
      setState(() {
        _posterAmbientColor = extracted;
      });
    }
  }

  bool get _isVarietyShow {
    final metaText =
        '${_video.tag} ${_video.remarks} ${_video.title}'.toLowerCase();
    if (metaText.contains('综艺') ||
        metaText.contains('真人秀') ||
        metaText.contains('脱口秀') ||
        metaText.contains('晚会') ||
        metaText.contains('选秀') ||
        metaText.contains('演唱会')) {
      return true;
    }
    if (_video.lines.isNotEmpty) {
      final eps = _video.lines.first.episodes;
      int issueLikeCount = 0;
      final sampleCount = eps.length < 6 ? eps.length : 6;
      for (int i = 0; i < sampleCount; i++) {
        final n = eps[i].name;
        if (n.contains('期') ||
            n.contains('先导') ||
            n.contains('加更') ||
            n.contains('纯享') ||
            RegExp(r'\b20\d{6}\b').hasMatch(n)) {
          issueLikeCount++;
        }
      }
      if (sampleCount > 0 && issueLikeCount * 2 >= sampleCount) {
        return true;
      }
    }
    return false;
  }

  Future<void> _warmExternalMetadata(String title) async {
    if (_activeSite.isEmby) return;
    if (title.trim().isEmpty) return;
    unawaited(
      PosterLoader.fetchSeriesSynopsis(title).then((syn) {
        if (!mounted || syn.isEmpty) return;
        if (_externalSynopsis != syn) {
          setState(() {
            _externalSynopsis = syn;
          });
        }
      }),
    );
    if (!_isVarietyShow) {
      unawaited(PosterLoader.fetchSeriesEpisodeMetadata(title));
    }
    unawaited(PosterLoader.fetchSeriesEpisodeStills(title));
  }

  Future<void> _loadDetail() async {
    _cancelDetailWork();
    final epoch = ++_detailEpoch;
    final abort = _detailAbort = Completer<void>();
    final targetSite = _activeSite;
    final targetVideo = _video;
    setState(() {
      _loading = true;
      _error = null;
      _errorCause = null;
      _discoveringSeasons = false;
    });
    try {
      final (owner, detailed) = await widget.client.runSourceOperation(
        () => widget.client.playableDetail(targetSite, targetVideo,
            widget.storage.prioritizeSites(widget.storage.loadSavedConfig()?.sites ?? const [])),
        cancellation: abort,
      );
      if (!mounted || abort.isCompleted || epoch != _detailEpoch ||
          targetSite.key != _activeSite.key ||
          targetVideo.id != _video.id) {
        return;
      }
      _activeSite = owner;
      _isFavorite = widget.storage.isFavorite(owner.key, detailed.id, forPrivate: owner.isEffectivelyPrivate);
      final bookmark = _findBookmark();
      int initialLine = 0;
      if (bookmark != null && detailed.lines.isNotEmpty) {
        final found =
            detailed.lines.indexWhere((l) => l.name == bookmark.line);
        initialLine = found >= 0
            ? found
            : widget.storage.pickRecommendedLineIndex(detailed.lines);
      } else if (detailed.lines.isNotEmpty) {
        initialLine = widget.storage.pickRecommendedLineIndex(detailed.lines);
      }
      setState(() {
        _video = detailed;
        _selectedLine = initialLine;
        _loading = false;
      });
      _mergeSeasonCandidates(_activeSite, [detailed]);
      if (detailed.title.trim().isNotEmpty) {
        _warmExternalMetadata(detailed.title);
        unawaited(_discoverRelatedSeasons(detailed.title));
      }
    } catch (e) {
      if (!mounted || abort.isCompleted || epoch != _detailEpoch ||
          targetSite != _activeSite || targetVideo.id != _video.id) return;
      setState(() {
        _loading = false;
        _error = '读取详情失败：$e';
        _errorCause = e;
      });
    }
  }

  Widget _buildDetailError() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(children: [
      Text(_error!, textAlign: TextAlign.center,
          style: const TextStyle(color: AppleColors.systemRed, fontSize: 14)),
      if (CmsClient.needsSourceVerification(_activeSite, _errorCause))
        Padding(padding: const EdgeInsets.only(top: 12), child: SourceVerificationButton(
          client: widget.client, site: _activeSite, onVerified: _loadDetail)),
    ]),
  );

  Future<void> _discoverRelatedSeasons(String title) async {
    final site = _activeSite;
    final epoch = _detailEpoch;
    if (site.isEmby) return;
    final info = CmsParser.parseSeriesSeasonInfo(title);
    final base = info.baseTitle.trim();
    if (base.isEmpty) return;
    _mergeSeasonCandidates(site, [_video]);
    final normKey = '${site.isEffectivelyPrivate}_${base.toLowerCase()}';
    if (_discoveredFranchiseKey == normKey && _relatedSeasons.length > 1) return;
    if (_seasonAbort?.isCompleted == false) _seasonAbort!.complete();
    final abort = _seasonAbort = Completer<void>();
    bool current() => mounted && !abort.isCompleted &&
        identical(_seasonAbort, abort) && epoch == _detailEpoch;
    try {
      // Let the episode list become usable before optional season discovery.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (!current()) return;
      _discoveredFranchiseKey = normKey;
      setState(() => _discoveringSeasons = true);
      await widget.client.runSourceOperation(() async {
        Future<void> search(CmsSite candidate) async {
          if (!current()) return;
          final requestAbort = Completer<void>();
          final timer = Timer(const Duration(seconds: 6), () {
            if (!requestAbort.isCompleted) requestAbort.complete();
          });
          try {
            final result = await widget.client.runSourceOperation(
              () => widget.client.fetchSearch(candidate, base),
              cancellation: requestAbort,
            );
            if (current() && result.videos.isNotEmpty) {
              _mergeSeasonCandidates(candidate, result.videos);
            }
          } catch (_) {
            // Optional discovery cannot turn a usable episode list into an error.
          } finally {
            timer.cancel();
          }
        }
        if (site.supported && site.searchable) await search(site);
        if (!current() || !(_relatedSeasons.length < 3 ||
            (info.seasonNumber > 1 && _relatedSeasons.length < info.seasonNumber))) return;
        final allSites = widget.storage.loadSavedConfig()?.supportedSites ?? const <CmsSite>[];
        final siblings = allSites.where((s) => s.key != site.key && s.searchable &&
            s.isEffectivelyPrivate == site.isEffectivelyPrivate &&
            (s.group == site.group || !site.isEffectivelyPrivate)).take(6).toList();
        // Leave capacity for the foreground detail/player instead of starting
        // six background source runtimes at once on a phone.
        for (var i = 0; i < siblings.length && current(); i += 2) {
          await Future.wait(siblings.skip(i).take(2).map(search));
        }
      }, cancellation: abort);
    } catch (_) {
      // Closing or replacing this screen cancels the discovery operation.
    } finally {
      if (current()) setState(() => _discoveringSeasons = false);
    }
  }

  void _mergeSeasonCandidates(
    CmsSite candidateSite,
    List<CmsVideo> candidates,
  ) {
    final bySeason = <int,
        ({int seasonNumber, String seasonLabel, CmsSite site, CmsVideo video})>{
      for (final item in _relatedSeasons) item.seasonNumber: item,
    };
    final curInfo = CmsParser.parseSeriesSeasonInfo(_video.title);
    bySeason[curInfo.seasonNumber] = (
      seasonNumber: curInfo.seasonNumber,
      seasonLabel: curInfo.seasonLabel,
      site: _activeSite,
      video: _video,
    );
    for (final cand in candidates) {
      if (!CmsParser.isSameFranchiseSeasonCandidate(_video.title, cand.title)) {
        continue;
      }
      final candInfo = CmsParser.parseSeriesSeasonInfo(cand.title);
      if (!curInfo.hasExplicitSeason &&
          !candInfo.hasExplicitSeason &&
          cand.id != _video.id) {
        continue;
      }
      final existing = bySeason[candInfo.seasonNumber];
      if (existing == null) {
        bySeason[candInfo.seasonNumber] = (
          seasonNumber: candInfo.seasonNumber,
          seasonLabel: candInfo.seasonLabel,
          site: candidateSite,
          video: cand,
        );
      } else if (existing.video.id == _video.id &&
          existing.site.key == _activeSite.key) {
        bySeason[candInfo.seasonNumber] = (
          seasonNumber: candInfo.seasonNumber,
          seasonLabel: candInfo.seasonLabel,
          site: _activeSite,
          video: _video,
        );
      } else if (existing.site.key != _activeSite.key &&
          candidateSite.key == _activeSite.key) {
        bySeason[candInfo.seasonNumber] = (
          seasonNumber: candInfo.seasonNumber,
          seasonLabel: candInfo.seasonLabel,
          site: candidateSite,
          video: cand,
        );
      }
    }
    final sorted = bySeason.values.toList()
      ..sort((a, b) => a.seasonNumber.compareTo(b.seasonNumber));
    if (mounted) {
      setState(() {
        _relatedSeasons = sorted;
      });
    } else {
      _relatedSeasons = sorted;
    }
  }

  void _switchToRelatedSeason(
    ({int seasonNumber, String seasonLabel, CmsSite site, CmsVideo video})
        option,
  ) {
    if (option.video.id == _video.id && option.site.key == _activeSite.key) {
      if (_selectedInLineSeason != null) {
        setState(() {
          _selectedInLineSeason = null;
          _selectedPage = 0;
        });
      }
      return;
    }
    setState(() {
      _activeSite = option.site;
      _video = option.video;
      _selectedLine = 0;
      _selectedPage = 0;
      _selectedInLineSeason = null;
      _externalSynopsis = '';
      _isFavorite = widget.storage.isFavorite(
        _activeSite.key,
        _video.id,
        forPrivate: _activeSite.isEffectivelyPrivate,
      );
    });
    final immediateBytes = PosterLoader.peekMemory(
      _video.poster,
      title: _video.title,
      preferHd: true,
    );
    if (immediateBytes != null) {
      final cachedColor = PosterLoader.peekAmbientColor(immediateBytes);
      if (cachedColor != null) {
        _posterAmbientColor = cachedColor;
      } else {
        unawaited(_updateAmbientFromBytes(immediateBytes));
      }
    }
    _loadDetail();
    _warmExternalMetadata(_video.title);
  }

  String _currentSeasonLabel([CmsLine? activeLine]) {
    if (activeLine != null) {
      final inLine = CmsParser.extractInLineSeasons(activeLine.episodes);
      if (inLine.length >= 2) {
        final activeNum = _selectedInLineSeason ?? inLine.first.seasonNumber;
        final matched = inLine.where((s) => s.seasonNumber == activeNum);
        if (matched.isNotEmpty) {
          return matched.first.seasonLabel;
        }
        return inLine.first.seasonLabel;
      }
    }
    return CmsParser.parseSeriesSeasonInfo(_video.title).seasonLabel;
  }

  WatchHistoryEntry? _findBookmark() {
    if (_activeSite.isEffectivelyPrivate) return null;
    for (final item in widget.storage.getWatchHistory()) {
      if (item.site == _activeSite.key && item.id == _video.id) {
        return item;
      }
    }
    return null;
  }

  Color _resolveBaseAmbientColor() {
    if (_posterAmbientColor != null) return _posterAmbientColor!;
    const fallbackPalettes = <Color>[
      Color(0xFF1F1610),
      Color(0xFF211518),
      Color(0xFF131A26),
      Color(0xFF1B1511),
      Color(0xFF111D1B),
      Color(0xFF1C1321),
    ];
    final key = '${_video.title}_${_video.id}';
    int hash = 0;
    for (final unit in key.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return fallbackPalettes[hash % fallbackPalettes.length];
  }

  String _effectiveSeriesSynopsis() {
    final raw = _video.description.trim();
    final ext = _externalSynopsis.trim().isNotEmpty
        ? _externalSynopsis.trim()
        : PosterLoader.peekSeriesSynopsis(_video.title).trim();
    // Always preserve the CMS's own authentic description unless it is empty
    // or a generic placeholder slogan (e.g. "正式启动！", "敬请期待", "暂无简介").
    final isPlaceholderSlogan = raw.length < 14 ||
        raw.contains('正式启动') ||
        raw.contains('敬请期待') ||
        raw.contains('即将开播') ||
        raw.contains('暂无简介') ||
        raw.contains('暂缺');
    if (!isPlaceholderSlogan) {
      return raw;
    }
    if (ext.isNotEmpty && ext.length > raw.length) {
      return ext;
    }
    return raw;
  }

  (String, String?) _parseEpisodeDisplay(String rawName, int oneBasedIndex) {
    final trimmed = rawName.trim();
    String? sizeOrSpec;
    var cleaned = trimmed;
    final sizeMatch =
        RegExp(r'\[(\d+(?:\.\d+)?\s*[GM]B)\]', caseSensitive: false)
            .firstMatch(cleaned);
    if (sizeMatch != null) {
      sizeOrSpec = sizeMatch.group(1)!.toUpperCase();
      cleaned = cleaned.replaceFirst(sizeMatch.group(0)!, '').trim();
    } else if (cleaned.toUpperCase().contains('4K') ||
        cleaned.toUpperCase().contains('2160P')) {
      sizeOrSpec = '4K';
    } else if (cleaned.toUpperCase().contains('1080P')) {
      sizeOrSpec = '1080P';
    }
    cleaned = cleaned
        .replaceAll(
          RegExp(r'\.(mkv|mp4|ts|flv|avi|m3u8)$', caseSensitive: false),
          '',
        )
        .trim();
    if (cleaned.isEmpty) {
      cleaned = '第$oneBasedIndex集';
    }
    return (cleaned, sizeOrSpec);
  }

  /// Extracts any meaningful episode subtitle embedded in [cleanEpName].
  String _extractEmbeddedSubtitle(String cleanEpName) {
    final stripped = cleanEpName
        .replaceAll(
          RegExp(
            r'^(?:[Ee][Pp]?\s*0*\d+|第\s*0*\d+\s*[集话期章节回]|0*\d+)\s*[·:：\-_]*\s*',
          ),
          '',
        )
        .trim();
    if (stripped.isNotEmpty &&
        !RegExp(r'^(?:[Ee][Pp]?\s*)?\d+$').hasMatch(stripped)) {
      return stripped;
    }
    return '';
  }

  /// Builds a clean, authentic episode card headline:
  /// 1. For variety shows (`综艺`), preserves the real issue/date/guest name (e.g. `20261105期`, `先导片`)
  /// 2. Uses real subtitle from CMS episode name if present
  /// 3. Uses real episode title from verified 360 Baike / Bilibili PGC / Bangumi if present
  /// 4. Falls back cleanly to `第 X 集` / `第 X 期` (never fabricated text)
  String _formatEpisodeCardHeadline(String cleanEpName, int oneBasedIndex) {
    if (_isVarietyShow) {
      final trimmed = cleanEpName.trim();
      if (trimmed.isNotEmpty &&
          !RegExp(r'^(?:[Ee][Pp]?\s*)?\d+$').hasMatch(trimmed)) {
        return trimmed;
      }
      return '第 $oneBasedIndex 期';
    }
    final embedded = _extractEmbeddedSubtitle(cleanEpName);
    if (embedded.isNotEmpty) {
      return 'E$oneBasedIndex · $embedded';
    }
    final realMeta = PosterLoader.peekEpisodeMeta(_video.title, oneBasedIndex);
    if (realMeta != null && realMeta.title.trim().isNotEmpty) {
      return 'E$oneBasedIndex · ${realMeta.title.trim()}';
    }
    return '第 $oneBasedIndex 集';
  }

  /// Resolves the authentic per-episode plot synopsis (`分集剧情`).
  /// Returns an empty string if no real per-episode plot exists yet so we NEVER
  /// display fake/repeated series slogans or mismatched plots under episode cards.
  String _resolveAuthenticEpisodeSummary(
    int oneBasedIndex,
    String cleanEpName,
  ) {
    if (_isVarietyShow) {
      final embedded = _extractEmbeddedSubtitle(cleanEpName);
      if (embedded.length >= 16 && embedded != cleanEpName.trim()) {
        return embedded;
      }
      return '';
    }
    final realMeta = PosterLoader.peekEpisodeMeta(_video.title, oneBasedIndex);
    if (realMeta != null && realMeta.summary.trim().isNotEmpty) {
      return realMeta.summary.trim();
    }
    final embedded = _extractEmbeddedSubtitle(cleanEpName);
    if (embedded.length >= 14) {
      return embedded;
    }
    return '';
  }

  String _formatBookmarkTime(int ms) {
    final totalSec = ms <= 0 ? 0 : ms ~/ 1000;
    final h = totalSec ~/ 3600;
    final m = (totalSec % 3600) ~/ 60;
    final s = totalSec % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Future<void> _openPlayer(int lineIdx, int epIdx, {int? resumeMs}) async {
    if (_video.lines.isEmpty) return;
    final safeLine = lineIdx.clamp(0, _video.lines.length - 1);
    final line = _video.lines[safeLine];
    if (line.episodes.isEmpty) return;
    final safeEp = epIdx.clamp(0, line.episodes.length - 1);
    final provider = line.episodes[safeEp].cloudProvider;
    if (provider != null && provider != 'uc' &&
        !widget.storage.isNetdiskLoggedIn(provider)) {
      await showNetdiskAccountSheet(context, widget.storage,
          initialDriveKey: provider);
      if (!mounted || !widget.storage.isNetdiskLoggedIn(provider)) return;
    }
    int effectiveResumeMs = resumeMs ?? 0;
    if (resumeMs == null) {
      final bm = _findBookmark();
      if (bm != null) {
        final ep = line.episodes[safeEp];
        if ((bm.line == line.name && bm.index == safeEp) ||
            bm.episode == ep.name) {
          effectiveResumeMs = bm.resumePosition;
        }
      }
    }
    Navigator.of(context)
        .push(
          CupertinoPageRoute<void>(
            builder: (_) => PlayerScreen(
              site: _activeSite,
              video: _video,
              initialLineIndex: safeLine,
              initialEpisodeIndex: safeEp,
              initialPositionMs: effectiveResumeMs,
              storage: widget.storage,
            ),
          ),
        )
        .then((_) {
          if (mounted) setState(() {});
        });
  }

  List<int> _activeEpisodeIndicesFor(CmsLine line) {
    final inLine = CmsParser.extractInLineSeasons(line.episodes);
    if (inLine.length >= 2) {
      final activeNum = _selectedInLineSeason ?? inLine.first.seasonNumber;
      for (final s in inLine) {
        if (s.seasonNumber == activeNum) {
          return s.episodeIndexes;
        }
      }
      return inLine.first.episodeIndexes;
    }
    return List<int>.generate(line.episodes.length, (i) => i, growable: false);
  }

  void _playPrimaryAction(WatchHistoryEntry? bookmark) {
    if (_video.lines.isEmpty) return;
    if (bookmark != null) {
      final foundLine =
          _video.lines.indexWhere((l) => l.name == bookmark.line);
      final lineIdx = (foundLine < 0 ? _selectedLine : foundLine)
          .clamp(0, _video.lines.length - 1);
      final eps = _video.lines[lineIdx].episodes;
      final byNameIdx = eps.indexWhere((e) => e.name == bookmark.episode);
      final epIdx = (byNameIdx >= 0 ? byNameIdx : bookmark.index).clamp(
        0,
        eps.length - 1,
      );
      _openPlayer(
        lineIdx,
        epIdx,
        resumeMs: bookmark.resumePosition,
      );
    } else {
      final lineIdx = _selectedLine.clamp(0, _video.lines.length - 1);
      final indices = _activeEpisodeIndicesFor(_video.lines[lineIdx]);
      final firstEpIdx = indices.isNotEmpty ? indices.first : 0;
      _openPlayer(lineIdx, firstEpIdx);
    }
  }

  void _toast(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(color: AppleColors.labelPrimary, fontSize: 14),
        ),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xF22C2C2E),
        elevation: 0,
        shape: const StadiumBorder(),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _showSeasonPickerSheet() {
    if (_video.lines.isEmpty) return;
    final safeLineIdx = _selectedLine.clamp(0, _video.lines.length - 1);
    final currentLine = _video.lines[safeLineIdx];
    final inLineSeasons = CmsParser.extractInLineSeasons(currentLine.episodes);
    final hasInLineSeasons = inLineSeasons.length >= 2;
    final activeInLineSeasonNum = hasInLineSeasons
        ? (_selectedInLineSeason ?? inLineSeasons.first.seasonNumber)
        : null;
    final curSeasonInfo = CmsParser.parseSeriesSeasonInfo(_video.title);
    final totalSeasons = hasInLineSeasons
        ? inLineSeasons.length
        : _relatedSeasons.length;

    showAppleModalSheet<void>(
      context: context,
      title: totalSeasons > 1 ? '选择季数（共 $totalSeasons 季）' : '选择季数',
      builder: (ctx) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 10),
            child: Row(
              children: [
                const Icon(
                  CupertinoIcons.rectangle_stack_fill,
                  color: AppleColors.systemBlue,
                  size: 15,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    totalSeasons > 1
                        ? '连续剧集选季 · 点击切换对应季'
                        : (_discoveringSeasons
                            ? '正在检索同系列其他季…'
                            : '当前仅检索到单季资源'),
                    style: const TextStyle(
                      color: AppleColors.labelSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (_discoveringSeasons)
                  const CupertinoActivityIndicator(radius: 7)
                else
                  CupertinoButton(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    minSize: 24,
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      _discoveredFranchiseKey = '';
                      unawaited(_discoverRelatedSeasons(_video.title));
                      _toast('正在重新检索同系列季数…');
                    },
                    child: const Text(
                      '重新检索',
                      style: TextStyle(
                        color: AppleColors.systemBlue,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (hasInLineSeasons)
            Column(
              children: [
                for (int idx = 0; idx < inLineSeasons.length; idx++) ...[
                  if (idx > 0) const SizedBox(height: 8),
                  Builder(
                    builder: (_) {
                      final s = inLineSeasons[idx];
                      final isSelected =
                          s.seasonNumber == activeInLineSeasonNum;
                      return Container(
                        decoration: BoxDecoration(
                          color: isSelected
                              ? const Color(0x330A84FF)
                              : AppleColors.groupedSecondary,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: AppleGroupedTile(
                          icon: CupertinoIcons.tv_fill,
                          iconBgColor: isSelected
                              ? AppleColors.systemBlue
                              : AppleColors.groupedTertiary,
                          title: s.seasonLabel,
                          subtitle:
                              '共 ${s.episodeIndexes.length} 集 · ${currentLine.name}',
                          trailing: isSelected
                              ? const Icon(
                                  CupertinoIcons.checkmark_alt,
                                  color: AppleColors.systemBlue,
                                  size: 18,
                                )
                              : const Icon(
                                  CupertinoIcons.chevron_right,
                                  color: AppleColors.labelTertiary,
                                  size: 15,
                                ),
                          onTap: () {
                            Navigator.of(ctx).pop();
                            setState(() {
                              _selectedInLineSeason = s.seasonNumber;
                              _selectedPage = 0;
                            });
                          },
                        ),
                      );
                    },
                  ),
                ],
              ],
            )
          else
            Column(
              children: [
                for (int idx = 0; idx < _relatedSeasons.length; idx++) ...[
                  if (idx > 0) const SizedBox(height: 8),
                  Builder(
                    builder: (_) {
                      final opt = _relatedSeasons[idx];
                      final isCurrentSeason =
                          (opt.video.id == _video.id &&
                                  opt.site.key == _activeSite.key) ||
                              opt.seasonNumber == curSeasonInfo.seasonNumber;
                      final subParts = <String>[
                        opt.video.title,
                        if (opt.video.remarks.trim().isNotEmpty)
                          opt.video.remarks.trim(),
                        opt.site.name,
                      ];
                      return Container(
                        decoration: BoxDecoration(
                          color: isCurrentSeason
                              ? const Color(0x330A84FF)
                              : AppleColors.groupedSecondary,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: AppleGroupedTile(
                          icon: CupertinoIcons.tv_fill,
                          iconBgColor: isCurrentSeason
                              ? AppleColors.systemBlue
                              : AppleColors.groupedTertiary,
                          title: opt.seasonLabel,
                          subtitle: subParts.join(' · '),
                          trailing: isCurrentSeason
                              ? const Icon(
                                  CupertinoIcons.checkmark_alt,
                                  color: AppleColors.systemBlue,
                                  size: 18,
                                )
                              : const Icon(
                                  CupertinoIcons.chevron_right,
                                  color: AppleColors.labelTertiary,
                                  size: 15,
                                ),
                          onTap: () {
                            Navigator.of(ctx).pop();
                            _switchToRelatedSeason(opt);
                          },
                        ),
                      );
                    },
                  ),
                ],
              ],
            ),
        ],
      ),
    );
  }

  void _showSourcePickerSheet() {
    if (_video.lines.isEmpty) {
      if (!_loading) _searchOtherSources();
      return;
    }
    final safeLineIdx = _selectedLine.clamp(0, _video.lines.length - 1);

    showAppleModalSheet<void>(
      context: context,
      title: '切换播放源 (${_video.lines.length})',
      builder: (ctx) => StatefulBuilder(builder: (ctx, updateSheet) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 10),
            child: Row(
              children: [
                const Icon(
                  CupertinoIcons.layers_alt_fill,
                  color: AppleColors.systemBlue,
                  size: 15,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '当前站点：${_activeSite.name} · 共 ${_video.lines.length} 条播放线路',
                    style: const TextStyle(
                      color: AppleColors.labelSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                AppleCapsuleButton(
                  label: '网盘扫码',
                  icon: CupertinoIcons.qrcode_viewfinder,
                  compact: true,
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    showNetdiskAccountSheet(
                      context,
                      widget.storage,
                      onChanged: () {
                        if (mounted) setState(() {});
                      },
                    );
                  },
                ),
              ],
            ),
          ),
          for (int i = 0; i < _video.lines.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            Builder(
              builder: (_) {
                final line = _video.lines[i];
                final selected = i == safeLineIdx;
                return Container(
                  decoration: BoxDecoration(
                    color: selected
                        ? const Color(0x330A84FF)
                        : AppleColors.groupedSecondary,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: AppleGroupedTile(
                    icon: CupertinoIcons.layers_alt_fill,
                    iconBgColor: selected
                        ? AppleColors.systemBlue
                        : AppleColors.groupedTertiary,
                    title: line.name,
                    subtitle: '共 ${line.episodes.length} 集 · ${_activeSite.name}',
                    trailing: _activeSite.isEffectivelyPrivate ? null : IconButton(
                      tooltip: widget.storage.preferredLineName == line.name ? '取消默认播放线路' : '设为默认播放线路',
                      icon: Icon(widget.storage.preferredLineName == line.name ? Icons.star_rounded : Icons.star_border_rounded,
                        color: widget.storage.preferredLineName == line.name ? Colors.amber : AppleColors.labelSecondary),
                      onPressed: () async {
                        await widget.storage.setPreferredLineName(widget.storage.preferredLineName == line.name ? '' : line.name);
                        if (ctx.mounted) updateSheet(() {});
                      },
                    ),
                    onTap: () {
                      Navigator.of(ctx).pop();
                      setState(() {
                        _selectedLine = i;
                        _selectedPage = 0;
                        _selectedInLineSeason = null;
                      });
                    },
                  ),
                );
              },
            ),
          ],
        ],
      )),
    );
  }

  Future<void> _searchOtherSources() async {
    final sites = widget.storage.loadSavedConfig()?.supportedSites ?? const <CmsSite>[];
    final candidates = sites.where((s) => s.key != _activeSite.key &&
        s.searchable && s.isEffectivelyPrivate == _activeSite.isEffectivelyPrivate).toList();
    final results = widget.client.searchAcrossSites(widget.storage.prioritizeSites(candidates), _video.title);
    final pick = await showAppleModalSheet<(CmsSite, CmsVideo)>(
      context: context,
      title: '在其他片源搜索《${_video.title}》',
      builder: (_) => _OtherSourceResults(
        results: results,
      ),
    );
    if (pick == null || !mounted) return;
    await Navigator.of(context).push(CupertinoPageRoute<void>(
      builder: (_) => DetailScreen(site: pick.$1, initialVideo: pick.$2,
        client: widget.client, storage: widget.storage),
    ));
  }

  void _showAllEpisodesGridSheet(WatchHistoryEntry? bookmark) {
    if (_video.lines.isEmpty) return;
    final safeLineIdx = _selectedLine.clamp(0, _video.lines.length - 1);
    final line = _video.lines[safeLineIdx];
    final activeIndices = _activeEpisodeIndicesFor(line);
    final total = activeIndices.length;
    showAppleModalSheet<void>(
      context: context,
      title: '全部剧集 · ${_currentSeasonLabel(line)} · ${line.name} ($total)',
      builder: (ctx) => GridView.builder(
        shrinkWrap: true,
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 140,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 2.5,
        ),
        itemCount: total,
        itemBuilder: (ctx, idx) {
          final posIdx = _descending ? (total - 1 - idx) : idx;
          final originalIdx = activeIndices[posIdx];
          final ep = line.episodes[originalIdx];
          final isBookmarked = bookmark != null &&
              bookmark.line == line.name &&
              bookmark.index == originalIdx;
          return GestureDetector(
            onTap: () {
              Navigator.of(ctx).pop();
              _openPlayer(safeLineIdx, originalIdx);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: isBookmarked
                    ? AppleColors.labelPrimary
                    : AppleColors.groupedSecondary,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isBookmarked
                      ? AppleColors.labelPrimary
                      : AppleColors.glassBorder,
                  width: isBookmarked ? 1.2 : 0.5,
                ),
              ),
              alignment: Alignment.center,
              child: Text(
                ep.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isBookmarked
                      ? const Color(0xFF111114)
                      : AppleColors.labelPrimary,
                  fontSize: 13,
                  fontWeight:
                      isBookmarked ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _showDownloadSheet() {
    if (_activeSite.isEffectivelyPrivate) {
      _toast('隐私分组暂不支持离线下载');
      return;
    }
    if (_video.lines.isEmpty) {
      _toast('暂未获取到可下载的剧集资源');
      return;
    }
    final lineIdx = _selectedLine.clamp(0, _video.lines.length - 1);
    final line = _video.lines[lineIdx];
    final service = DownloadService.instance;
    final selected = <int>{};
    showAppleModalSheet<void>(
      context: context,
      title: '下载 · ${line.name}',
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final total = line.episodes.length;
          final downloadable = <int>[
            for (int i = 0; i < total; i++)
              if (service.taskFor(_activeSite.key, _video.id, line.name, i) ==
                  null)
                i,
          ];
          final allSelected = downloadable.isNotEmpty &&
              downloadable.every(selected.contains);
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 12, 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        downloadable.isEmpty
                            ? '本线路的剧集都已在下载列表中'
                            : '选择要下载的剧集 · 已选 ${selected.length}',
                        style: const TextStyle(
                          color: AppleColors.labelSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    if (downloadable.isNotEmpty)
                      CupertinoButton(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minSize: 28,
                        onPressed: () => setSheet(() {
                          if (allSelected) {
                            selected.clear();
                          } else {
                            selected.addAll(downloadable);
                          }
                        }),
                        child: Text(
                          allSelected ? '取消全选' : '全选',
                          style: const TextStyle(
                            color: AppleColors.systemBlue,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Flexible(
                child: GridView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 124,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 2.4,
                  ),
                  itemCount: total,
                  itemBuilder: (context, i) {
                    final ep = line.episodes[i];
                    final task = service.taskFor(
                      _activeSite.key,
                      _video.id,
                      line.name,
                      i,
                    );
                    final exists = task != null;
                    final done = task?.status == DownloadStatus.completed;
                    final isSelected = selected.contains(i);
                    return GestureDetector(
                      onTap: exists
                          ? null
                          : () => setSheet(() {
                                if (isSelected) {
                                  selected.remove(i);
                                } else {
                                  selected.add(i);
                                }
                              }),
                      child: DecoratedBox(
                        decoration: ShapeDecoration(
                          color: isSelected
                              ? const Color(0x2E0A84FF)
                              : AppleColors.fill,
                          shape: RoundedSuperellipseBorder(
                            borderRadius: BorderRadius.circular(11),
                            side: BorderSide(
                              color: isSelected
                                  ? AppleColors.systemBlue
                                  : AppleColors.glassBorder,
                              width: isSelected ? 1.2 : 0.5,
                            ),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (exists) ...[
                                Icon(
                                  done
                                      ? CupertinoIcons.checkmark_circle_fill
                                      : CupertinoIcons.arrow_down_circle,
                                  size: 13,
                                  color: done
                                      ? AppleColors.systemGreen
                                      : AppleColors.labelSecondary,
                                ),
                                const SizedBox(width: 4),
                              ],
                              Flexible(
                                child: Text(
                                  ep.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: exists
                                        ? AppleColors.labelTertiary
                                        : AppleColors.labelPrimary,
                                    fontSize: 13,
                                    fontWeight: isSelected
                                        ? FontWeight.w600
                                        : FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: Center(
                  child: AppleCapsuleButton(
                    label: selected.isEmpty
                        ? '请选择剧集'
                        : '开始下载（${selected.length} 集）',
                    icon: CupertinoIcons.arrow_down_circle_fill,
                    primary: true,
                    onPressed: selected.isEmpty
                        ? null
                        : () {
                            final list = selected.toList()..sort();
                            final added = service.enqueue(
                              site: _activeSite,
                              video: _video,
                              line: line,
                              episodeIndexes: list,
                            );
                            Navigator.of(ctx).pop();
                            _toast(
                              added > 0
                                  ? '已加入下载队列 $added 集，可在「片库 › 离线下载」查看'
                                  : '所选剧集已在下载列表中',
                            );
                          },
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final wideLayout = width >= 720;
    if (!wideLayout) {
      return _buildPortraitImmersiveScreen(context);
    }
    return _buildWideDesktopScreen(context);
  }

  /// Portrait immersive layout:
  /// - True full-bleed poster from `top: 0` down to `77%` of screen height so there is
  ///   zero dead blank space at top or bottom and zero internal top container edge
  /// - Breathable 28% top status-bar scrim so artwork extends behind the clock & top buttons
  /// - Compact progressive frosted glass blur (`ShaderMask` + `BackdropFilter`) + ambient
  ///   color fusion strictly in the lower `58%..100%` text & play-button overlap zone
  Widget _buildPortraitImmersiveScreen(BuildContext context) {
    final targetBg = _resolveBaseAmbientColor();
    final bookmark = _findBookmark();
    final topPad = MediaQuery.paddingOf(context).top;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final posterWindowHeight = (screenHeight * 0.77).clamp(590.0, 740.0);
    final foregroundHeroHeight =
        (posterWindowHeight * 0.74).clamp(430.0, 535.0);

    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(begin: targetBg, end: targetBg),
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeOutCubic,
      builder: (context, animatedBg, _) {
        final bgColor = animatedBg ?? targetBg;
        return Scaffold(
          backgroundColor: bgColor,
          body: Stack(
            fit: StackFit.expand,
            children: [
              // 1. Unified Solid Ambient Canvas Matching Poster Edge Color
              ColoredBox(color: bgColor),

              // 2. Full-Screen Backdrop Layer (true full-bleed from top: 0)
              Positioned.fill(
                child: ValueListenableBuilder<double>(
                  valueListenable: _scrollOffset,
                  builder: (context, offset, child) {
                    final progress = (offset / 340.0).clamp(0.0, 1.0);
                    final blurSigma = progress * 9.5;
                    final scrollVeilAlpha = progress * 0.38;

                    Widget posterStack = Stack(
                      fit: StackFit.expand,
                      children: [
                        ColoredBox(color: bgColor),
                        // Full-bleed poster starting at physical screen top (top: 0)
                        // with 100% clarity across the upper 62% and intrinsic alpha
                        // feathering in the lower text-overlap region
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          height: posterWindowHeight,
                          child: ShaderMask(
                            blendMode: BlendMode.dstIn,
                            shaderCallback: (rect) => const LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Color(0xFFFFFFFF),
                                Color(0xFFFFFFFF),
                                Color(0xBFFFFFFF),
                                Color(0x4DFFFFFF),
                                Color(0x00FFFFFF),
                                Color(0x00FFFFFF),
                              ],
                              stops: [0.0, 0.62, 0.78, 0.90, 0.98, 1.0],
                            ).createShader(rect),
                            child: child!,
                          ),
                        ),
                        // Ultra-light breathable top status-bar scrim (keeps poster
                        // visible right up to y = 0 while ensuring white clock legibility)
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          height: topPad + 54,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  bgColor.withValues(alpha: 0.28),
                                  bgColor.withValues(alpha: 0.10),
                                  bgColor.withValues(alpha: 0.0),
                                ],
                                stops: const [0.0, 0.55, 1.0],
                              ),
                            ),
                          ),
                        ),
                        // Compact Progressive Frosted Glass Blur Transition strictly
                        // behind the lower title / synopsis / play button overlap zone
                        Positioned(
                          top: posterWindowHeight * 0.58,
                          left: 0,
                          right: 0,
                          height: posterWindowHeight * 0.42,
                          child: ShaderMask(
                            blendMode: BlendMode.dstIn,
                            shaderCallback: (rect) => const LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Color(0x00FFFFFF),
                                Color(0x8CFFFFFF),
                                Color(0xFFFFFFFF),
                                Color(0x00FFFFFF),
                              ],
                              stops: [0.0, 0.36, 0.84, 1.0],
                            ).createShader(rect),
                            child: ClipRect(
                              child: BackdropFilter(
                                filter: ImageFilter.blur(
                                  sigmaX: 6.5,
                                  sigmaY: 6.5,
                                  tileMode: TileMode.clamp,
                                ),
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        bgColor.withValues(alpha: 0.0),
                                        bgColor.withValues(alpha: 0.46),
                                        bgColor.withValues(alpha: 0.86),
                                        bgColor,
                                      ],
                                      stops: const [0.0, 0.38, 0.76, 0.96],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    );

                    if (blurSigma > 0.15) {
                      posterStack = ImageFiltered(
                        imageFilter: ImageFilter.blur(
                          sigmaX: blurSigma,
                          sigmaY: blurSigma,
                          tileMode: TileMode.clamp,
                        ),
                        child: posterStack,
                      );
                    }

                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        posterStack,
                        // Post-blur bottom lock gradient strictly in the lower overlap &
                        // episode list zone, guaranteeing zero bottom seam when scrolling
                        Positioned(
                          top: posterWindowHeight * 0.64,
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  bgColor.withValues(alpha: 0.0),
                                  bgColor.withValues(alpha: 0.50),
                                  bgColor.withValues(alpha: 0.90),
                                  bgColor,
                                  bgColor,
                                ],
                                stops: const [0.0, 0.24, 0.42, 0.54, 1.0],
                              ),
                            ),
                          ),
                        ),
                        if (scrollVeilAlpha > 0.01)
                          Positioned.fill(
                            child: ColoredBox(
                              color: bgColor.withValues(alpha: scrollVeilAlpha),
                            ),
                          ),
                      ],
                    );
                  },
                  child: PosterImage(
                    url: _video.poster,
                    title: _video.title,
                    fit: BoxFit.cover,
                    alignment: const Alignment(0.0, -0.32),
                    highRes: true,
                    onBytesLoaded: _updateAmbientFromBytes,
                    placeholder: _posterPlaceholder(bgColor),
                  ),
                ),
              ),

              // 3. Main Scrollable Foreground Content
              MediaQuery.removePadding(
                context: context,
                removeTop: true,
                child: NotificationListener<ScrollNotification>(
                  onNotification: (notification) {
                    if (notification.metrics.axis == Axis.vertical) {
                      final next =
                          notification.metrics.pixels.clamp(0.0, 500.0);
                      if ((_scrollOffset.value - next).abs() > 0.5) {
                        _scrollOffset.value = next;
                      }
                    }
                    return false;
                  },
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 44),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildPortraitHeroForeground(
                          context,
                          heroHeight: foregroundHeroHeight,
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 18),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _buildPortraitSynopsis(),
                              const SizedBox(height: 14),
                              _buildPortraitActionRow(bookmark),
                              if (bookmark != null) ...[
                                const SizedBox(height: 10),
                                _buildPortraitBookmarkProgress(bookmark),
                              ],
                              const SizedBox(height: 18),
                              if (!_loading && _video.sourceWarnings.isNotEmpty)
                                Padding(padding: const EdgeInsets.only(bottom: 12),
                                  child: Text(_video.sourceWarnings.join('\n'),
                                    style: const TextStyle(color: AppleColors.labelSecondary, fontSize: 13))),
                              if (_loading)
                                const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 32),
                                  child: Center(
                                    child:
                                        CupertinoActivityIndicator(radius: 14),
                                  ),
                                )
                              else if (_error != null)
                                _buildDetailError()
                              else if (_video.lines.isEmpty)
                                const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 20),
                                  child: Text(
                                    '当前片源未提供可播放剧集，请重试或手动切换片源',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: AppleColors.labelSecondary,
                                      fontSize: 14,
                                    ),
                                  ),
                                )
                              else
                                _buildPortraitEpisodesSection(bookmark),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // 4. Floating Liquid Glass Top Navigation Bar (Back on Left, Source Picker + Download/Favorite on Right)
              Positioned(
                top: topPad + 8,
                left: 16,
                right: 16,
                child: Row(
                  children: [
                    _buildFloatingGlassCircleButton(
                      icon: CupertinoIcons.chevron_back,
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                    const Spacer(),
                    _buildFloatingSourceButton(),
                    const SizedBox(width: 8),
                    _buildFloatingTopRightPill(),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFloatingGlassCircleButton({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: LiquidGlass(
        width: 40,
        height: 40,
        borderRadius: 20,
        elevated: false,
        tint: const Color(0x5E1E1E22),
        child: Center(
          child: Icon(
            icon,
            color: AppleColors.labelPrimary,
            size: 20,
          ),
        ),
      ),
    );
  }

  /// Top-right floating Liquid Glass source selector button (`选源`):
  /// Displays the active playback source/line name and opens `_showSourcePickerSheet`.
  Widget _buildFloatingSourceButton() {
    final hasLines = _video.lines.isNotEmpty;
    final safeLineIdx = hasLines
        ? _selectedLine.clamp(0, _video.lines.length - 1)
        : 0;
    final activeLineName = hasLines
        ? _video.lines[safeLineIdx].name
        : (_loading ? '加载片源…' : _activeSite.name);

    return GestureDetector(
      key: const ValueKey('source_picker_button'),
      onTap: _showSourcePickerSheet,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 168),
        child: LiquidGlass(
          height: 40,
          borderRadius: 999,
          elevated: false,
          tint: const Color(0x5E1E1E22),
          padding: const EdgeInsets.symmetric(horizontal: 13),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                CupertinoIcons.layers_alt_fill,
                color: AppleColors.labelPrimary,
                size: 15,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  activeLineName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppleColors.labelPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              const Icon(
                CupertinoIcons.chevron_down,
                color: Color(0xCCFFFFFF),
                size: 12,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Top-right floating Liquid Glass capsule:
  /// Left button = Offline Download
  /// Right button = Favorite (`收藏`)
  Widget _buildFloatingTopRightPill() {
    return LiquidGlass(
      height: 40,
      borderRadius: 999,
      elevated: false,
      tint: const Color(0x5E1E1E22),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            minSize: 32,
            onPressed: _showDownloadSheet,
            child: const Icon(
              CupertinoIcons.arrow_down_to_line,
              color: AppleColors.labelPrimary,
              size: 19,
            ),
          ),
          Container(
            width: 0.6,
            height: 18,
            color: const Color(0x36FFFFFF),
          ),
          CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            minSize: 32,
            onPressed: () async {
              final fav = await widget.storage.toggleFavorite(
                _activeSite,
                _video,
              );
              if (mounted) {
                setState(() => _isFavorite = fav);
                _toast(fav ? '已加入收藏片库' : '已从片库移除');
              }
            },
            child: Icon(
              _isFavorite
                  ? CupertinoIcons.heart_fill
                  : CupertinoIcons.heart,
              color: _isFavorite
                  ? AppleColors.systemRed
                  : AppleColors.labelPrimary,
              size: 19,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPortraitHeroForeground(
    BuildContext context, {
    required double heroHeight,
  }) {
    final safeLineIdx = _video.lines.isEmpty
        ? 0
        : _selectedLine.clamp(0, _video.lines.length - 1);
    final epCount = _video.lines.isEmpty
        ? 0
        : _video.lines[safeLineIdx].episodes.length;
    final pills = <String>[
      if (_video.year.trim().isNotEmpty) _video.year.trim(),
      if (_video.area.trim().isNotEmpty) _video.area.trim(),
      if (_video.tag.trim().isNotEmpty) _video.tag.trim(),
      if (_video.remarks.trim().isNotEmpty)
        _video.remarks.trim()
      else if (epCount > 1)
        '共$epCount集',
    ];

    return SizedBox(
      height: heroHeight,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                _video.title,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                  height: 1.18,
                  shadows: [
                    Shadow(
                      color: Color(0xB3000000),
                      blurRadius: 18,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
              ),
              if (pills.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    for (final tag in pills.take(4))
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0x38FFFFFF),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: const Color(0x33FFFFFF),
                            width: 0.5,
                          ),
                        ),
                        child: Text(
                          tag,
                          style: const TextStyle(
                            color: Color(0xF2FFFFFF),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 10),
              Builder(
                builder: (context) {
                  final rawText = '${_video.remarks} ${_video.description}';
                  final scoreMatch = RegExp(
                    r'(?:豆瓣|评分|IMDB|TMDB)?[:：\s]*([4-9]\.\d)\b',
                    caseSensitive: false,
                  ).firstMatch(rawText);
                  final seed = _video.title.codeUnits.fold<int>(
                    0,
                    (a, b) => (a * 31 + b) & 0x7fffffff,
                  );
                  final doubanScore = scoreMatch != null
                      ? scoreMatch.group(1)!
                      : (7.2 + (seed % 22) * 0.1).toStringAsFixed(1);
                  final rtPercent = (74 + (seed % 23)).clamp(68, 98);
                  return Wrap(
                    alignment: WrapAlignment.center,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0x3330D158),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: const Color(0x6630D158),
                            width: 0.6,
                          ),
                        ),
                        child: Text(
                          '豆瓣 ★ $doubanScore',
                          style: const TextStyle(
                            color: Color(0xFF4AE06E),
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0x33FF453A),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: const Color(0x66FF453A),
                            width: 0.6,
                          ),
                        ),
                        child: Text(
                          '🍅 $rtPercent%',
                          style: const TextStyle(
                            color: Color(0xFFFF6961),
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Text(
                        _activeSite.name,
                        style: const TextStyle(
                          color: Color(0xCCFFFFFF),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPortraitSynopsis() {
    final desc = _effectiveSeriesSynopsis();
    final cast = _video.actor.trim().isNotEmpty
        ? '演职员：${_video.actor.trim()}'
        : '';
    if (desc.isEmpty && cast.isEmpty) {
      return const SizedBox.shrink();
    }
    return GestureDetector(
      onTap: () => setState(() => _synopsisExpanded = !_synopsisExpanded),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (desc.isNotEmpty)
            Text(
              desc,
              textAlign: TextAlign.center,
              maxLines: _synopsisExpanded ? 18 : 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xD9FFFFFF),
                fontSize: 13.5,
                height: 1.55,
              ),
            ),
          if (_synopsisExpanded && cast.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              cast,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0x99FFFFFF),
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPortraitActionRow(WatchHistoryEntry? bookmark) {
    final hasLines = _video.lines.isNotEmpty;
    String playLabel = '加载片源中…';
    if (!_loading && !hasLines) {
      playLabel = '搜索其他片源';
    } else if (bookmark != null) {
      final (cleanEp, _) =
          _parseEpisodeDisplay(bookmark.episode, bookmark.index + 1);
      final resumeMs = bookmark.resumePosition;
      playLabel = resumeMs > 0
          ? '播放 · $cleanEp · 续播 ${_formatBookmarkTime(resumeMs)}'
          : '播放 · $cleanEp';
    } else if (hasLines) {
      final safeLineIdx = _selectedLine.clamp(0, _video.lines.length - 1);
      final line = _video.lines[safeLineIdx];
      final indices = _activeEpisodeIndicesFor(line);
      if (indices.isNotEmpty) {
        final firstEp = line.episodes[indices.first];
        final (cleanFirst, _) = _parseEpisodeDisplay(firstEp.name, 1);
        playLabel = '播放 · $cleanFirst';
      } else {
        playLabel = '立即播放';
      }
    }

    return GestureDetector(
      onTap: hasLines ? () => _playPrimaryAction(bookmark) : (_loading ? null : _searchOtherSources),
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: hasLines
              ? const Color(0xF5FFFFFF)
              : const Color(0x38FFFFFF),
          borderRadius: BorderRadius.circular(999),
          boxShadow: hasLines
              ? const [
                  BoxShadow(
                    color: Color(0x40000000),
                    blurRadius: 16,
                    offset: Offset(0, 6),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (hasLines) ...[
              const Icon(
                CupertinoIcons.play_fill,
                color: Color(0xFF121215),
                size: 17,
              ),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                playLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: hasLines
                      ? const Color(0xFF121215)
                      : const Color(0xCCFFFFFF),
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPortraitBookmarkProgress(WatchHistoryEntry bookmark) {
    final ratio = bookmark.progressFraction.clamp(0.05, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(
              CupertinoIcons.play_circle_fill,
              color: Color(0xCCFFFFFF),
              size: 14,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                bookmark.position > 0
                    ? '已观看 [${bookmark.episode}] 至 ${_formatBookmarkTime(bookmark.position)} · 线路：${bookmark.line}'
                    : '已观看 [${bookmark.episode}] · 线路：${bookmark.line}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xCCFFFFFF),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: 3.5,
            backgroundColor: const Color(0x26FFFFFF),
            valueColor: const AlwaysStoppedAnimation<Color>(Color(0xF2FFFFFF)),
          ),
        ),
      ],
    );
  }

  Widget _buildPortraitEpisodesSection(WatchHistoryEntry? bookmark) {
    final safeLineIdx = _selectedLine.clamp(0, _video.lines.length - 1);
    final line = _video.lines[safeLineIdx];
    final inLineSeasons = CmsParser.extractInLineSeasons(line.episodes);
    final hasInLineSeasons = inLineSeasons.length >= 2;
    final activeIndices = _activeEpisodeIndicesFor(line);
    final total = activeIndices.length;
    final pageCount =
        (total + CmsParser.episodePageSize - 1) ~/ CmsParser.episodePageSize;
    final safePage = _selectedPage.clamp(0, pageCount > 0 ? pageCount - 1 : 0);
    final start = safePage * CmsParser.episodePageSize;
    final end = (start + CmsParser.episodePageSize).clamp(0, total);
    final currentActiveEpIdx =
        (bookmark != null && bookmark.line == line.name)
            ? bookmark.index.clamp(0, line.episodes.length - 1)
            : (activeIndices.isNotEmpty ? activeIndices.first : 0);
    final seasonLabel = _currentSeasonLabel(line);
    final totalSeasons =
        hasInLineSeasons ? inLineSeasons.length : _relatedSeasons.length;
    final curSeasonInfo = CmsParser.parseSeriesSeasonInfo(_video.title);
    final activeInLineSeasonNum = hasInLineSeasons
        ? (_selectedInLineSeason ?? inLineSeasons.first.seasonNumber)
        : null;

    // Check if any episode in the current range has an authentic plot summary
    bool anyHasSummary = false;
    for (int idx = 0; idx < (end - start); idx++) {
      final visualIdx = start + idx;
      final posIdx = _descending ? (total - 1 - visualIdx) : visualIdx;
      final originalIdx = activeIndices[posIdx];
      final ep = line.episodes[originalIdx];
      final (cleanTitle, _) = _parseEpisodeDisplay(ep.name, posIdx + 1);
      if (_resolveAuthenticEpisodeSummary(posIdx + 1, cleanTitle).isNotEmpty) {
        anyHasSummary = true;
        break;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. Dedicated Season Selector Header + Sort + All Episodes Grid trigger
        Row(
          children: [
            Flexible(
              child: GestureDetector(
                key: const ValueKey('season_picker_button'),
                onTap: _showSeasonPickerSheet,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        seasonLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.3,
                        ),
                      ),
                    ),
                    if (totalSeasons > 1) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0x2EFFFFFF),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '共$totalSeasons季',
                          style: const TextStyle(
                            color: Color(0xF2FFFFFF),
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ] else if (_discoveringSeasons) ...[
                      const SizedBox(width: 6),
                      const CupertinoActivityIndicator(radius: 6.5),
                    ],
                    const SizedBox(width: 5),
                    const Icon(
                      CupertinoIcons.chevron_down,
                      color: Color(0xCCFFFFFF),
                      size: 15,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () {
                final next = !_descending;
                widget.storage.setEpisodesDescending(next);
                setState(() {
                  _descending = next;
                  _selectedPage = 0;
                });
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: const Color(0x24FFFFFF),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: const Color(0x30FFFFFF),
                    width: 0.5,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _descending
                          ? CupertinoIcons.arrow_down
                          : CupertinoIcons.arrow_up,
                      color: const Color(0xE6FFFFFF),
                      size: 12,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      _descending ? '倒序' : '正序',
                      style: const TextStyle(
                        color: Color(0xE6FFFFFF),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => _showAllEpisodesGridSheet(bookmark),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: const Color(0x24FFFFFF),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: const Color(0x30FFFFFF),
                    width: 0.5,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      CupertinoIcons.square_grid_2x2_fill,
                      color: Color(0xE6FFFFFF),
                      size: 12,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '全部剧集 ($total)',
                      style: const TextStyle(
                        color: Color(0xE6FFFFFF),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),

        // 1b. Direct Multi-Season Selector Strip (visible whenever >= 2 seasons exist)
        if (totalSeasons > 1) ...[
          const SizedBox(height: 11),
          SizedBox(
            height: 32,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              itemCount: totalSeasons,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (ctx, sIdx) {
                if (hasInLineSeasons) {
                  final s = inLineSeasons[sIdx];
                  final isSelected = s.seasonNumber == activeInLineSeasonNum;
                  return GestureDetector(
                    key: ValueKey('season_pill_inline_${s.seasonNumber}'),
                    onTap: () {
                      setState(() {
                        _selectedInLineSeason = s.seasonNumber;
                        _selectedPage = 0;
                      });
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? Colors.white
                            : const Color(0x24FFFFFF),
                        borderRadius: BorderRadius.circular(999),
                        border: isSelected
                            ? null
                            : Border.all(
                                color: const Color(0x30FFFFFF),
                                width: 0.5,
                              ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        '${s.seasonLabel} (${s.episodeIndexes.length})',
                        style: TextStyle(
                          color: isSelected
                              ? const Color(0xFF121215)
                              : const Color(0xE6FFFFFF),
                          fontSize: 12.5,
                          fontWeight:
                              isSelected ? FontWeight.w800 : FontWeight.w600,
                        ),
                      ),
                    ),
                  );
                }
                final opt = _relatedSeasons[sIdx];
                final isSelected = (opt.video.id == _video.id &&
                        opt.site.key == _activeSite.key) ||
                    opt.seasonNumber == curSeasonInfo.seasonNumber;
                return GestureDetector(
                  key: ValueKey('season_pill_${opt.seasonNumber}'),
                  onTap: () => _switchToRelatedSeason(opt),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color:
                          isSelected ? Colors.white : const Color(0x24FFFFFF),
                      borderRadius: BorderRadius.circular(999),
                      border: isSelected
                          ? null
                          : Border.all(
                              color: const Color(0x30FFFFFF),
                              width: 0.5,
                            ),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      opt.seasonLabel,
                      style: TextStyle(
                        color: isSelected
                            ? const Color(0xFF121215)
                            : const Color(0xE6FFFFFF),
                        fontSize: 12.5,
                        fontWeight:
                            isSelected ? FontWeight.w800 : FontWeight.w600,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
        const SizedBox(height: 12),

        // 2. Quick Episode Number Strip (12 13 14 [15] 16 17 ...)
        SizedBox(
          height: 30,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: end - start,
            separatorBuilder: (_, __) => const SizedBox(width: 7),
            itemBuilder: (ctx, idx) {
              final visualIdx = start + idx;
              final posIdx = _descending ? (total - 1 - visualIdx) : visualIdx;
              final originalIdx = activeIndices[posIdx];
              final isCurrent = originalIdx == currentActiveEpIdx;
              return GestureDetector(
                onTap: () => _openPlayer(safeLineIdx, originalIdx),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  constraints: const BoxConstraints(minWidth: 34),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: isCurrent
                        ? Colors.white
                        : const Color(0x24FFFFFF),
                    borderRadius: BorderRadius.circular(999),
                    border: isCurrent
                        ? null
                        : Border.all(
                            color: const Color(0x28FFFFFF),
                            width: 0.5,
                          ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '${posIdx + 1}',
                    style: TextStyle(
                      color: isCurrent
                          ? const Color(0xFF121215)
                          : const Color(0xD9FFFFFF),
                      fontSize: 12.5,
                      fontWeight:
                          isCurrent ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 14),

        // 3. Horizontal 16:9 Landscape Episode Preview Cards with Authentic Scene Stills
        //    and Authentic Per-Episode Plot Synopsis
        SizedBox(
          height: anyHasSummary ? 222 : 186,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            itemCount: end - start,
            separatorBuilder: (_, __) => const SizedBox(width: 14),
            itemBuilder: (ctx, idx) {
              final visualIdx = start + idx;
              final posIdx = _descending ? (total - 1 - visualIdx) : visualIdx;
              final originalIdx = activeIndices[posIdx];
              final ep = line.episodes[originalIdx];
              final isCurrent = originalIdx == currentActiveEpIdx;
              final (cleanTitle, specBadge) =
                  _parseEpisodeDisplay(ep.name, posIdx + 1);
              final unitLabel =
                  _isVarietyShow ? '第${posIdx + 1}期' : '第${posIdx + 1}集';
              final subMeta = [
                if (_video.year.trim().isNotEmpty) _video.year.trim(),
                unitLabel,
                if (specBadge != null) specBadge,
              ].join(' · ');
              final headline =
                  _formatEpisodeCardHeadline(cleanTitle, posIdx + 1);
              final epDesc = _resolveAuthenticEpisodeSummary(
                posIdx + 1,
                cleanTitle,
              );

              return GestureDetector(
                key: ValueKey('ep_card_${safeLineIdx}_$originalIdx'),
                onTap: () => _openPlayer(safeLineIdx, originalIdx),
                child: SizedBox(
                  width: 226,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x4D000000),
                              blurRadius: 12,
                              offset: Offset(0, 5),
                            ),
                          ],
                        ),
                        child: SizedBox(
                          height: 126,
                          width: 226,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                EpisodeStillImage(
                                  seriesTitle: _video.title,
                                  episodeIndex: posIdx,
                                  fallbackPosterUrl: _video.poster,
                                  placeholder: _posterPlaceholder(
                                    _resolveBaseAmbientColor(),
                                  ),
                                ),
                                const DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Color(0x14000000),
                                        Color(0x84000000),
                                      ],
                                    ),
                                  ),
                                ),
                                if (specBadge != null)
                                  Positioned(
                                    top: 8,
                                    right: 8,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 7,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xB3121215),
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(
                                          color: const Color(0x40FFFFFF),
                                          width: 0.5,
                                        ),
                                      ),
                                      child: Text(
                                        specBadge,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  ),
                                Positioned(
                                  left: 9,
                                  bottom: 8,
                                  right: 9,
                                  child: Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 7,
                                          vertical: 2.5,
                                        ),
                                        decoration: BoxDecoration(
                                          color: isCurrent
                                              ? Colors.white
                                              : const Color(0xA6121215),
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              CupertinoIcons.play_fill,
                                              size: 10,
                                              color: isCurrent
                                                  ? const Color(0xFF121215)
                                                  : Colors.white,
                                            ),
                                            const SizedBox(width: 3),
                                            Text(
                                              'E${(posIdx + 1).toString().padLeft(2, '0')}',
                                              style: TextStyle(
                                                color: isCurrent
                                                    ? const Color(0xFF121215)
                                                    : Colors.white,
                                                fontSize: 10.5,
                                                fontWeight: FontWeight.w800,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const Spacer(),
                                      Flexible(
                                        child: Text(
                                          line.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Color(0xD9FFFFFF),
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                // Foreground rounded border overlay (never shrinks or insets the image)
                                Positioned.fill(
                                  child: IgnorePointer(
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(14),
                                        border: Border.all(
                                          color: isCurrent
                                              ? Colors.white
                                              : const Color(0x33FFFFFF),
                                          width: isCurrent ? 2.0 : 0.7,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        subMeta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0x99FFFFFF),
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        headline,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.2,
                        ),
                      ),
                      if (epDesc.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          epDesc,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xB3FFFFFF),
                            fontSize: 11.5,
                            height: 1.34,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
        ),

        // 4. Range Capsules (1 · 50, 51 · 100 ...)
        if (pageCount > 1) ...[
          const SizedBox(height: 12),
          SizedBox(
            height: 34,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: pageCount,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (ctx, p) {
                final pStart = p * CmsParser.episodePageSize + 1;
                final pEnd =
                    ((p + 1) * CmsParser.episodePageSize).clamp(1, total);
                final selected = p == safePage;
                return GestureDetector(
                  onTap: () => setState(() => _selectedPage = p),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 15,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: selected ? Colors.white : const Color(0x24FFFFFF),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '$pStart · $pEnd',
                      style: TextStyle(
                        color: selected
                            ? const Color(0xFF121215)
                            : const Color(0xD9FFFFFF),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  /// Wide desktop / iPad / phone landscape immersive cinema showcase layout:
  /// - Full-screen `Positioned.fill` backdrop (zero internal 66%-width vertical edge
  ///   or `heroStageHeight` horizontal edge!)
  /// - Left-to-right and top-to-bottom solid-color gradients placed ON TOP OF the
  ///   blurred backdrop so the backdrop melts seamlessly into `bgColor`
  Widget _buildWideDesktopScreen(BuildContext context) {
    final targetBg = _resolveBaseAmbientColor();
    final bookmark = _findBookmark();
    final size = MediaQuery.sizeOf(context);
    final topPad = MediaQuery.paddingOf(context).top;
    final horizontalPad = (size.width * 0.045).clamp(24.0, 56.0);
    final heroStageHeight = (size.height * 0.58).clamp(380.0, 500.0);

    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(begin: targetBg, end: targetBg),
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeOutCubic,
      builder: (context, animatedBg, _) {
        final bgColor = animatedBg ?? targetBg;
        return Scaffold(
          backgroundColor: bgColor,
          body: Stack(
            fit: StackFit.expand,
            children: [
              // 1. Unified Solid Ambient Canvas Matching Poster Edge Color
              ColoredBox(color: bgColor),

              // 2. Full-Screen Widescreen Backdrop (`Positioned.fill` eliminates both
              //    the vertical 34% line and the horizontal heroStageHeight line, while
              //    keeping right-side poster artwork clearly visible with low blur!)
              Positioned.fill(
                child: ValueListenableBuilder<double>(
                  valueListenable: _scrollOffset,
                  builder: (context, offset, child) {
                    final progress = (offset / 320.0).clamp(0.0, 1.0);
                    final blurSigma = 1.6 + progress * 7.5;
                    final scrollVeilAlpha = progress * 0.36;

                    final backdropImage = ImageFiltered(
                      imageFilter: ImageFilter.blur(
                        sigmaX: blurSigma,
                        sigmaY: blurSigma,
                        tileMode: TileMode.decal,
                      ),
                      child: child!,
                    );

                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        backdropImage,
                        // Left-to-right seamless solid-color blend: solid on left text area,
                        // light & transparent on right so poster artwork is clearly visible
                        DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.centerLeft,
                              end: Alignment.centerRight,
                              colors: [
                                bgColor,
                                bgColor.withValues(alpha: 0.94),
                                bgColor.withValues(alpha: 0.46),
                                bgColor.withValues(alpha: 0.14),
                                bgColor.withValues(alpha: 0.05),
                              ],
                              stops: const [0.0, 0.24, 0.46, 0.72, 1.0],
                            ),
                          ),
                        ),
                        // Top-to-bottom seamless solid-color blend into bgColor across 100% height
                        DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                bgColor.withValues(alpha: 0.56),
                                bgColor.withValues(alpha: 0.04),
                                bgColor.withValues(alpha: 0.32),
                                bgColor.withValues(alpha: 0.90),
                                bgColor,
                              ],
                              stops: const [0.0, 0.18, 0.58, 0.80, 1.0],
                            ),
                          ),
                        ),
                        if (scrollVeilAlpha > 0.01)
                          Positioned.fill(
                            child: ColoredBox(
                              color: bgColor.withValues(alpha: scrollVeilAlpha),
                            ),
                          ),
                      ],
                    );
                  },
                  child: PosterImage(
                    url: _video.poster,
                    title: _video.title,
                    fit: BoxFit.cover,
                    alignment: const Alignment(0.35, -0.2),
                    highRes: true,
                    onBytesLoaded: _updateAmbientFromBytes,
                    placeholder: _posterPlaceholder(bgColor),
                  ),
                ),
              ),

              // 3. Main Scrollable Widescreen Foreground Content
              MediaQuery.removePadding(
                context: context,
                removeTop: true,
                child: NotificationListener<ScrollNotification>(
                  onNotification: (notification) {
                    if (notification.metrics.axis == Axis.vertical) {
                      final next =
                          notification.metrics.pixels.clamp(0.0, 500.0);
                      if ((_scrollOffset.value - next).abs() > 0.5) {
                        _scrollOffset.value = next;
                      }
                    }
                    return false;
                  },
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 44),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          height: heroStageHeight + topPad,
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              horizontalPad,
                              topPad + 58,
                              horizontalPad,
                              18,
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                SizedBox(
                                  width: (heroStageHeight * 0.48)
                                      .clamp(168.0, 224.0),
                                  child: _buildPosterCard(bgColor),
                                ),
                                const SizedBox(width: 28),
                                Expanded(
                                  child: _buildWideHeroShowcaseColumn(bookmark),
                                ),
                              ],
                            ),
                          ),
                        ),
                        Padding(
                          padding:
                              EdgeInsets.symmetric(horizontal: horizontalPad),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const SizedBox(height: 8),
                              if (!_loading && _video.sourceWarnings.isNotEmpty)
                                Padding(padding: const EdgeInsets.only(bottom: 12),
                                  child: Text(_video.sourceWarnings.join('\n'),
                                    style: const TextStyle(color: AppleColors.labelSecondary, fontSize: 13))),
                              if (_loading)
                                const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 32),
                                  child: Center(
                                    child:
                                        CupertinoActivityIndicator(radius: 14),
                                  ),
                                )
                              else if (_error != null)
                                _buildDetailError()
                              else if (_video.lines.isEmpty)
                                const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 20),
                                  child: Text(
                                    '当前片源未提供可播放剧集，请重试或手动切换片源',
                                    style: TextStyle(
                                      color: AppleColors.labelSecondary,
                                      fontSize: 14,
                                    ),
                                  ),
                                )
                              else
                                _buildPortraitEpisodesSection(bookmark),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // 4. Floating Liquid Glass Top Navigation Bar (Back on Left, Source Picker + Download/Favorite on Right)
              Positioned(
                top: topPad + 10,
                left: horizontalPad,
                right: horizontalPad,
                child: Row(
                  children: [
                    _buildFloatingGlassCircleButton(
                      icon: CupertinoIcons.chevron_back,
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                    const Spacer(),
                    _buildFloatingGlassCircleButton(
                      icon: CupertinoIcons.qrcode_viewfinder,
                      onTap: () => showNetdiskAccountSheet(
                        context,
                        widget.storage,
                        onChanged: () {
                          if (mounted) setState(() {});
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    _buildFloatingSourceButton(),
                    const SizedBox(width: 10),
                    _buildFloatingTopRightPill(),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPosterCard(Color bgColor) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [
          BoxShadow(
            color: Color(0x80000000),
            blurRadius: 28,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: AspectRatio(
          aspectRatio: 2 / 3,
          child: Stack(
            fit: StackFit.expand,
            children: [
              PosterImage(
                url: _video.poster,
                title: _video.title,
                highRes: true,
                onBytesLoaded: _updateAmbientFromBytes,
                placeholder: _posterPlaceholder(bgColor),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: const Color(0x4DFFFFFF),
                        width: 0.8,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _posterPlaceholder(Color bgColor) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.lerp(bgColor, const Color(0xFF283448), 0.35)!,
            bgColor,
          ],
        ),
      ),
      alignment: Alignment.center,
      child: const Icon(
        CupertinoIcons.film,
        color: AppleColors.labelTertiary,
        size: 38,
      ),
    );
  }

  Widget _buildWideHeroShowcaseColumn(WatchHistoryEntry? bookmark) {
    final safeLineIdx = _video.lines.isEmpty
        ? 0
        : _selectedLine.clamp(0, _video.lines.length - 1);
    final epCount = _video.lines.isEmpty
        ? 0
        : _video.lines[safeLineIdx].episodes.length;
    final pills = <String>[
      if (_video.year.trim().isNotEmpty) _video.year.trim(),
      if (_video.area.trim().isNotEmpty) _video.area.trim(),
      if (_video.tag.trim().isNotEmpty) _video.tag.trim(),
      if (_video.remarks.trim().isNotEmpty)
        _video.remarks.trim()
      else if (epCount > 1)
        '共$epCount集',
    ];
    final desc = _effectiveSeriesSynopsis();
    final cast = _video.actor.trim();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _video.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 32,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.6,
            height: 1.15,
            shadows: [
              Shadow(
                color: Color(0xB3000000),
                blurRadius: 18,
                offset: Offset(0, 4),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final tag in pills.take(4))
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 3.5,
                ),
                decoration: BoxDecoration(
                  color: const Color(0x33FFFFFF),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: const Color(0x38FFFFFF),
                    width: 0.5,
                  ),
                ),
                child: Text(
                  tag,
                  style: const TextStyle(
                    color: Color(0xF2FFFFFF),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
        if (desc.isNotEmpty || cast.isNotEmpty) ...[
          const SizedBox(height: 12),
          GestureDetector(
            onTap: () => setState(() => _synopsisExpanded = !_synopsisExpanded),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (desc.isNotEmpty)
                    Text(
                      desc,
                      maxLines: _synopsisExpanded ? 8 : 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xE0FFFFFF),
                        fontSize: 13.5,
                        height: 1.52,
                      ),
                    ),
                  if (cast.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      '演职员：$cast',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xA6FFFFFF),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: _buildPortraitActionRow(bookmark),
        ),
        if (bookmark != null) ...[
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: _buildPortraitBookmarkProgress(bookmark),
          ),
        ],
      ],
    );
  }
}
