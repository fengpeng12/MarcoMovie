import 'package:package_info_plus/package_info_plus.dart';
import 'source_choice_sliver.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/cms_client.dart';
import '../core/catpaw_host.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/emby_library.dart';
import '../core/cms_parser.dart';
import '../core/app_update.dart';
import '../core/csp_bridge.dart';
import '../core/download_service.dart';
import '../core/models.dart';
import '../core/netdisk_service.dart';
import '../core/storage_service.dart';
import '../core/search_source_notice.dart';
import 'apple_theme.dart';
import 'detail_screen.dart';
import 'netdisk_sheet.dart';
import 'player_screen.dart';
import 'poster_image.dart';
import 'source_verification_dialog.dart';
/// Apple HIG adaptive shell:
/// - macOS / iPadOS / Desktop (`width >= 700`): Translucent sidebar with traffic-light inset & source card
/// - iOS (`width < 700`): Frosted-glass top navigation bar and translucent Cupertino bottom tab bar
class AdaptiveShell extends StatefulWidget {
  final StorageService storage;
  final CmsClient client;
  const AdaptiveShell({
    super.key,
    required this.storage,
    required this.client,
  });
  @override
  State<AdaptiveShell> createState() => _AdaptiveShellState();
}
class _AdaptiveShellState extends State<AdaptiveShell> {
  int _tabIndex = 0;
  CmsConfig? _config;
  CmsSite? _activeSite;
  List<CmsCategory> _categories = const [];
  String _selectedCategoryId = '';
  String _primaryTab = 'recommend';
  bool _filterExpanded = false;
  String _filterSubCategoryId = '';
  String _filterGenreLabel = '';
  String _filterArea = '';
  String _filterYear = '';
  List<CmsVideo> _rawCategoryVideos = const [];
  List<CmsVideo> _homeVideos = const [];
  int _currentPage = 1;
  int _pageCount = 1;
  bool _homeLoading = false;
  bool _loadingMore = false;
  String? _homeError;
  Object? _homeErrorCause;
  Future<void> Function()? _retryHomeError;
  int _homeEpoch = 0;
  int _categoryEpoch = 0;
  Completer<void>? _homeAbort;
  Completer<void>? _categoryAbort;
  Completer<void>? _liveAbort;

  void _cancelCatalogue() {
    for (final pending in [_homeAbort, _categoryAbort]) {
      if (pending != null && !pending.isCompleted) pending.complete();
    }
  }
  // 5-tap logo privacy state
  int _logoTapCount = 0;
  DateTime? _lastLogoTapAt;
  bool _privateSessionUnlocked = false;
  String _selectedPrivateSiteKey = '';
  bool _privacyPortalAnimating = false;
  int _privacyPortalRunId = 0;
  // Search state
  final TextEditingController _searchController = TextEditingController();
  final List<(CmsSite, CmsVideo)> _searchResults = [];
  final Map<String, String> _searchNotices = {};
  final Map<String, CmsSite> _searchVerificationSites = {};
  String _searchKeyword = '';
  String _searchSiteFilterKey = '';
  bool _searchPerformed = false;
  bool _searching = false;
  int _searchEpoch = 0;
  StreamSubscription<(CmsSite, List<CmsVideo>)>? _searchSubscription;
  VoidCallback? _searchSheetListener;
  // Live state
  int _selectedLiveSource = 0;
  int _selectedLiveGroup = 0;
  final TextEditingController _liveSearchController = TextEditingController();
  String _liveSearchQuery = '';
  List<LiveGroup> _liveGroups = const [];
  bool _liveLoading = false;
  String? _liveError;
  int _liveEpoch = 0;
  // Favorites / History segmented index
  int _librarySegment = 0;
  // Expandable drawer keys in Settings tab
  final Set<String> _expandedSettings = <String>{};
  bool get _isMacOS => !kIsWeb && Platform.isMacOS;
  CmsFilter get _currentFilter => CmsFilter(
        primaryTab: _primaryTab,
        categoryId: _filterSubCategoryId,
        genreLabel: _filterGenreLabel,
        area: _filterArea,
        year: _filterYear,
      );
  List<CmsSite> get _visibleSupportedSites {
    final cfg = _config;
    if (cfg == null) return const [];
    return _privateSessionUnlocked
        ? cfg.privateSupportedSites
        : cfg.publicSupportedSites;
  }
  List<LiveSource> get _visibleLives {
    final cfg = _config;
    if (cfg == null) return const [];
    return _privateSessionUnlocked ? cfg.privateLives : cfg.publicLives;
  }
  @override
  void initState() {
    super.initState();
    unawaited(_loadInstalledVersion());
    GlassworkBackdrop.reduceTransparency.value =
        widget.storage.glassBlurLevel == 'solid' ||
            widget.storage.glassBlurStrength <= 0.02;
    GlassworkBackdrop.intensity.value = widget.storage.glassBlurStrength;
    _reloadSavedConfig();
  }
  @override
  void dispose() {
    _cancelCatalogue();
    if (_liveAbort != null && !_liveAbort!.isCompleted) _liveAbort!.complete();
    _searchSubscription?.cancel();
    unawaited(CmsClient.closeScriptSessions());
    _searchController.dispose();
    _liveSearchController.dispose();
    super.dispose();
  }
  void _reloadSavedConfig() {
    // A deleted source may still have catalogue/live/search requests in flight.
    // Invalidate them before exposing the new registry, including an empty one.
    _cancelCatalogue();
    if (_liveAbort != null && !_liveAbort!.isCompleted) _liveAbort!.complete();
    ++_homeEpoch;
    ++_categoryEpoch;
    ++_liveEpoch;
    ++_searchEpoch;
    _searchSubscription?.cancel();
    _searchSubscription = null;
    _searchResults.clear();
    _searchNotices.clear();
    _searchVerificationSites.clear();
    _searchPerformed = false;
    _searching = false;
    final saved = widget.storage.loadSavedConfig();
    _config = saved;
    unawaited(CmsClient.retainScriptSessions(
      (saved?.scriptOwners ?? const <CmsSite>[]).where((site) =>
        _privateSessionUnlocked || !site.isEffectivelyPrivate),
    ));
    final availableSites = saved == null
        ? const <CmsSite>[]
        : (_privateSessionUnlocked
            ? saved.privateSupportedSites
            : (saved.publicSupportedSites.isNotEmpty
                ? saved.publicSupportedSites
                : saved.supportedSites
                    .where((s) => !s.isEffectivelyPrivate)
                    .toList()));
    if (availableSites.isNotEmpty) {
      final preferredKey = _privateSessionUnlocked
          ? _selectedPrivateSiteKey
          : (widget.storage.preferredSiteKey.isNotEmpty
              ? widget.storage.preferredSiteKey : widget.storage.selectedSiteKey);
      _activeSite = availableSites.firstWhere(
        (s) => s.key == preferredKey,
        orElse: () => availableSites.firstWhere(
          (s) => !CspBridge.isBannerNoticeSite(s),
          orElse: () => availableSites.first,
        ),
      );
      if (_privateSessionUnlocked) {
        _selectedPrivateSiteKey = _activeSite!.key;
      }
      _loadSiteHome();
    } else {
      _activeSite = null;
      _categories = const [];
      _rawCategoryVideos = const [];
      _homeVideos = const [];
      _homeError = null;
      _homeLoading = false;
      _loadingMore = false;
    }
    final lives = _visibleLives;
    if (lives.isNotEmpty) {
      _loadLivePlaylist(0);
    } else {
      _liveGroups = const [];
      _liveLoading = false;
      _liveError = null;
    }
    if (mounted) setState(() {});
  }
  Future<void> _loadSiteHome() async {
    final site = _activeSite;
    if (site == null) return;
    _cancelCatalogue();
    final abort = _homeAbort = Completer<void>();
    final epoch = ++_homeEpoch;
    ++_categoryEpoch;
    setState(() {
      _homeLoading = true;
      _loadingMore = false;
      _homeError = null;
      _primaryTab = 'recommend';
      _selectedCategoryId = '';
      _filterSubCategoryId = '';
      _filterGenreLabel = '';
      _filterArea = '';
      _filterYear = '';
      _currentPage = 1;
    });
    try {
      final (cats, listing) = await widget.client.runSourceOperation(
        () => widget.client.fetchHome(site), cancellation: abort,
      );
      if (!mounted || epoch != _homeEpoch || _activeSite?.key != site.key) {
        return;
      }
      setState(() {
        _categories = cats;
        _rawCategoryVideos = listing.videos;
        _homeVideos = listing.sourceFiltered
            ? listing.videos
            : CmsParser.filterVideos(listing.videos, _currentFilter);
        _currentPage = listing.page;
        _pageCount = listing.pageCount;
        _homeLoading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted || epoch != _homeEpoch || _activeSite?.key != site.key) {
        return;
      }
      setState(() {
        _homeLoading = false;
        _loadingMore = false;
        _homeError = '读取片源「${site.name}」失败：$e';
        _homeErrorCause = e;
        _retryHomeError = _loadSiteHome;
      });
    }
  }
  Future<void> _refreshCurrentHomeView() async {
    if (_primaryTab == 'recommend' &&
        _selectedCategoryId.isEmpty &&
        _filterSubCategoryId.isEmpty &&
        _filterGenreLabel.isEmpty &&
        _filterArea.isEmpty &&
        _filterYear.isEmpty) {
      await _loadSiteHome();
      return;
    }
    await _reloadFilteredListing(page: 1);
  }
  Future<void> _selectPrimaryTab(String tabKey) async {
    if (tabKey == 'recommend') {
      setState(() {
        _primaryTab = 'recommend';
        _filterSubCategoryId = '';
        _filterGenreLabel = '';
      });
      await _reloadFilteredListing(page: 1);
      return;
    }
    final resolved = CmsParser.resolvePrimaryTabCategory(_categories, tabKey);
    setState(() {
      _primaryTab = tabKey;
      _filterSubCategoryId = '';
      _filterGenreLabel = '';
      _selectedCategoryId = resolved.categoryId;
    });
    await _reloadFilteredListing(page: 1);
  }
  Future<void> _reloadFilteredListing({int page = 1}) async {
    final site = _activeSite;
    if (site == null) return;
    if (page > 1 && _loadingMore) return;
    _cancelCatalogue();
    ++_homeEpoch;
    final abort = _categoryAbort = Completer<void>();
    Future<T> read<T>(Future<T> Function() request) => widget.client.runSourceOperation(
      request, cancellation: abort,
    );
    final epoch = ++_categoryEpoch;
    final filter = _currentFilter;
    String targetCategoryId = '';
    List<String> targetChildIds = const [];
    if (_filterSubCategoryId.isNotEmpty) {
      targetCategoryId = _filterSubCategoryId;
      targetChildIds =
          CmsParser.childCategoryIds(_categories, _filterSubCategoryId);
    } else if (_primaryTab != 'recommend') {
      final resolved =
          CmsParser.resolvePrimaryTabCategory(_categories, _primaryTab);
      targetCategoryId = resolved.categoryId;
      targetChildIds = resolved.childIds;
    }
    setState(() {
      if (page == 1) {
        _homeLoading = true;
        _loadingMore = false;
      } else {
        _loadingMore = true;
      }
      _homeError = null;
      _selectedCategoryId = targetCategoryId;
    });
    try {
      CmsListing listing;
      if (targetCategoryId.isEmpty && _primaryTab == 'recommend' && page == 1) {
        final (cats, homeListing) = await read(() => widget.client.fetchHome(site));
        if (!mounted || epoch != _categoryEpoch || _activeSite?.key != site.key) return;
        if (_categories.isEmpty && cats.isNotEmpty) {
          _categories = cats;
        }
        listing = homeListing;
      } else if (targetCategoryId.isEmpty) {
        // Recommend tab pagination (page > 1) or unfiltered query:
        // First request default feed page (`categoryId: ''`).
        listing = await read(() => widget.client.fetchCategory(
          site,
          '',
          page,
          filter: filter,
        ));
        final existingKeys = _rawCategoryVideos
            .map((v) => v.id.isNotEmpty ? v.id : v.title)
            .toSet();
        final hasNewItems = listing.videos.any(
          (v) => !existingKeys.contains(v.id.isNotEmpty ? v.id : v.title),
        );
        // If the site's root feed does not paginate directly, fallback to the first category with its childIds.
        if (!hasNewItems && _categories.isNotEmpty) {
          final firstCat = _categories.first;
          final firstChildren =
              CmsParser.childCategoryIds(_categories, firstCat.id);
          final fallbackListing = await read(() => widget.client.fetchCategory(
            site,
            firstCat.id,
            page,
            childIds: firstChildren,
            filter: filter,
          ));
          if (fallbackListing.videos.isNotEmpty) {
            listing = fallbackListing;
          }
        }
      } else {
        listing = await read(() => widget.client.fetchCategory(
          site,
          targetCategoryId,
          page,
          childIds: targetChildIds,
          filter: filter,
        ));
      }
      if (!mounted || epoch != _categoryEpoch || _activeSite?.key != site.key) {
        return;
      }
      List<CmsVideo> combinedRaw;
      int addedCount = 0;
      if (page == 1) {
        combinedRaw = listing.videos;
        addedCount = listing.videos.length;
      } else {
        final seen = <String>{
          for (final v in _rawCategoryVideos)
            v.id.isNotEmpty ? v.id : v.title,
        };
        combinedRaw = [..._rawCategoryVideos];
        for (final v in listing.videos) {
          final key = v.id.isNotEmpty ? v.id : v.title;
          if (seen.add(key)) {
            combinedRaw.add(v);
            addedCount++;
          }
        }
      }
      // Remote rules may filter by opaque values absent from their result cards.
      // Keep the source's result instead of filtering those cards a second time.
      var filteredVideos = listing.sourceFiltered
          ? combinedRaw
          : CmsParser.filterVideos(combinedRaw, filter);
      // If client-side filter on page 1 matched nothing and more pages exist, probe page 2 automatically
      if (filteredVideos.isEmpty &&
          !listing.sourceFiltered &&
          filter.hasSubFilter &&
          page == 1 &&
          listing.pageCount > 1 &&
          targetCategoryId.isNotEmpty) {
        try {
          final page2 = await read(() => widget.client.fetchCategory(
            site,
            targetCategoryId,
            2,
            childIds: targetChildIds,
            filter: filter,
          ));
          final merged2 = [...combinedRaw, ...page2.videos];
          final filtered2 = page2.sourceFiltered
              ? merged2
              : CmsParser.filterVideos(merged2, filter);
          if (filtered2.isNotEmpty) {
            filteredVideos = filtered2;
          }
        } catch (_) {}
      }
      // The optional second-page probe may outlive a changed filter or route.
      if (!mounted || epoch != _categoryEpoch || _activeSite?.key != site.key) return;
      setState(() {
        _rawCategoryVideos = combinedRaw;
        _homeVideos = filteredVideos;
        _currentPage = page;
        if (page == 1) {
          _pageCount = listing.pageCount;
        } else if (addedCount == 0 && listing.videos.isEmpty) {
          // Reached the end of available pages
          _pageCount = page;
        } else {
          _pageCount = math.max(_pageCount, listing.pageCount);
        }
        _homeLoading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted || epoch != _categoryEpoch || _activeSite?.key != site.key) {
        return;
      }
      setState(() {
        _homeLoading = false;
        _loadingMore = false;
        if (page == 1 || CmsClient.needsSourceVerification(site, e)) {
          _homeError = '加载分类失败：$e';
          _homeErrorCause = e;
          _retryHomeError = () => _reloadFilteredListing(page: page);
        }
      });
    }
  }
  Future<void> _loadCategory(String categoryId, {int page = 1}) async {
    _filterSubCategoryId = categoryId;
    await _reloadFilteredListing(page: page);
  }
  Future<void> _runGlobalSearch(String keyword) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty || _config == null) return;
    final epoch = ++_searchEpoch;
    await _searchSubscription?.cancel();
    _searchSubscription = null;
    await widget.storage.addSearchKeyword(
      trimmed,
      forPrivate: _privateSessionUnlocked,
    );
    if (!mounted || epoch != _searchEpoch) return;
    final allSites = _visibleSupportedSites;
    final hasSelectedSite = _searchSiteFilterKey.isNotEmpty &&
        allSites.any((s) => '${s.subscriptionId}:${s.key}' == _searchSiteFilterKey);
    final orderedSites = hasSelectedSite
        ? <CmsSite>[
            ...allSites.where((s) => '${s.subscriptionId}:${s.key}' == _searchSiteFilterKey),
            ...allSites.where((s) => '${s.subscriptionId}:${s.key}' != _searchSiteFilterKey),
          ]
        : allSites;
    setState(() {
      _searching = true;
      _searchResults.clear();
      _searchNotices.clear();
      _searchVerificationSites.clear();
      if (!hasSelectedSite) _searchSiteFilterKey = '';
      _searchKeyword = trimmed;
      _searchPerformed = true;
    });
    _searchSheetListener?.call();
    _searchSubscription = widget.client
        .searchAcrossSites(
          orderedSites,
          trimmed,
          onSourceError: (site, error) {
            if (!mounted || epoch != _searchEpoch) return;
            setState(() {
              _searchNotices['${site.subscriptionId}:${site.key}'] =
                  '${site.name}：${searchSourceNotice(error)}';
              if (CmsClient.needsSourceVerification(site, error)) {
                _searchVerificationSites['${site.subscriptionId}:${site.key}'] = site;
              }
            });
            _searchSheetListener?.call();
          },
        )
        .listen(
          (batch) {
            if (!mounted || epoch != _searchEpoch) return;
            final (site, videos) = batch;
            setState(() {
              for (final v in videos) {
                _searchResults.add((site, v));
              }
            });
            _searchSheetListener?.call();
          },
          onError: (_) {
            if (mounted && epoch == _searchEpoch) {
              setState(() => _searching = false);
              _searchSheetListener?.call();
            }
          },
          onDone: () {
            if (mounted && epoch == _searchEpoch) {
              _searchSubscription = null;
              setState(() => _searching = false);
              _searchSheetListener?.call();
            }
          },
        );
  }
  Future<void> _retryVerifiedSearch(CmsSite site) async {
    final epoch = _searchEpoch;
    final key = '${site.subscriptionId}:${site.key}';
    try {
      final listing = await widget.client.fetchSearch(site, _searchKeyword);
      if (!mounted || epoch != _searchEpoch) return;
      setState(() {
        _searchResults.removeWhere((v) => v.$1.key == site.key && v.$1.subscriptionId == site.subscriptionId);
        _searchResults.addAll(listing.videos.map((v) => (site, v)));
        _searchNotices.remove(key);
        _searchVerificationSites.remove(key);
      });
    } catch (error) {
      if (!mounted || epoch != _searchEpoch) return;
      setState(() {
        _searchNotices[key] = '${site.name}：${searchSourceNotice(error)}';
        if (!CmsClient.needsSourceVerification(site, error)) _searchVerificationSites.remove(key);
      });
    }
    _searchSheetListener?.call();
  }

  Future<void> _loadLivePlaylist(int sourceIndex) async {
    final lives = _visibleLives;
    if (sourceIndex < 0 || sourceIndex >= lives.length) return;
    if (_liveAbort != null && !_liveAbort!.isCompleted) _liveAbort!.complete();
    final abort = _liveAbort = Completer<void>();
    final epoch = ++_liveEpoch;
    setState(() {
      _selectedLiveSource = sourceIndex;
      _selectedLiveGroup = 0;
      _liveLoading = true;
      _liveError = null;
    });
    try {
      final groups = await widget.client.runSourceOperation(
        () => widget.client.fetchLiveGroups(lives[sourceIndex]), cancellation: abort,
      );
      if (!mounted ||
          epoch != _liveEpoch ||
          _selectedLiveSource != sourceIndex) {
        return;
      }
      setState(() {
        _liveGroups = groups;
        _liveLoading = false;
      });
    } catch (e) {
      if (!mounted ||
          epoch != _liveEpoch ||
          _selectedLiveSource != sourceIndex) {
        return;
      }
      setState(() {
        _liveLoading = false;
        _liveError = '读取直播列表失败：$e';
      });
    }
  }
  void _openVideoDetail(CmsSite site, CmsVideo video) {
    if (video.id.startsWith('netdisk_qr:')) {
      final driveKey = video.id.substring('netdisk_qr:'.length).trim();
      showNetdiskAccountSheet(
        context,
        widget.storage,
        initialDriveKey: driveKey.isEmpty ? null : driveKey,
        onChanged: () {
          if (mounted) setState(() {});
        },
      );
      return;
    }
    Navigator.of(context)
        .push(
          CupertinoPageRoute<void>(
            builder: (_) => DetailScreen(
              site: site,
              initialVideo: video,
              client: widget.client,
              storage: widget.storage,
            ),
          ),
        )
        .then((_) {
          if (mounted) setState(() {});
        });
  }
  void _showAppleNotice(String title, String message) {
    if (!mounted) return;
    showCupertinoDialog<void>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text(title),
        content: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(message),
        ),
        actions: [
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('好'),
          ),
        ],
      ),
    );
  }
  Future<void> _quickImportFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = (data?.text ?? '').trim();
    if (text.isEmpty) {
      _showImportConfigDialog();
      return;
    }
    try {
      if (CmsParser.isBackupPayload(text)) {
        await widget.storage.importBackupJson(text);
        _reloadSavedConfig();
        _showAppleNotice('已从剪贴板恢复备份', '备份中的配置、收藏与观看历史已同步生效。');
        return;
      }
      final entries = await widget.client.resolveBatchSubscriptions(
        rawTextInput: text,
      );
      final merged = await widget.storage.upsertSubscriptions(entries);
      _reloadSavedConfig();
      final siteCount = merged?.publicSupportedSites.length ?? 0;
      final liveCount = merged?.publicLives.length ?? 0;
      _showAppleNotice(
        '订阅导入成功',
        '本次成功导入 ${entries.length} 个订阅源，当前共 $siteCount 个可用片源'
        '${liveCount > 0 ? "、$liveCount 个直播源" : ""}。',
      );
    } catch (e) {
      _showImportConfigDialog(initialInput: text, initialError: '剪贴板内容未能直接导入：$e');
    }
  }
  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final isLandscape = size.width > size.height;
    const dockItems = <(IconData, IconData, String)>[
      (CupertinoIcons.play_rectangle, CupertinoIcons.play_rectangle_fill, '主页'),
      (
        CupertinoIcons.dot_radiowaves_left_right,
        CupertinoIcons.dot_radiowaves_left_right,
        '直播',
      ),
      (
        CupertinoIcons.square_favorites_alt,
        CupertinoIcons.square_favorites_alt_fill,
        '片库',
      ),
      (CupertinoIcons.gear_alt, CupertinoIcons.gear_alt_fill, '设置'),
    ];
    final pages = [
      _buildHomeTab(context, useSidebar: isLandscape),
      _buildLiveTab(context, useSidebar: isLandscape),
      _buildFavoritesHistoryTab(context, useSidebar: isLandscape),
      _buildSettingsTab(context, useSidebar: isLandscape),
    ];
    final safeTabIndex = _tabIndex.clamp(0, pages.length - 1);
    final ambientPoster = safeTabIndex == 0 && _homeVideos.isNotEmpty
        ? _homeVideos.first.poster
        : '';
    final ambientTitle = safeTabIndex == 0 && _homeVideos.isNotEmpty
        ? _homeVideos.first.title
        : '';
    final customWallUrl = widget.storage.customWallpaperUrl;
    final blurSigma = switch (widget.storage.glassBlurLevel) {
      'light' => 36.0,
      'deep' => 84.0,
      _ => 60.0,
    };
    Widget? customWallWidget;
    if (customWallUrl.isNotEmpty) {
      if (customWallUrl.startsWith('http://') ||
          customWallUrl.startsWith('https://')) {
        customWallWidget = PosterImage(
          url: customWallUrl,
          highRes: true,
          placeholder: const SizedBox.shrink(),
        );
      } else if (!kIsWeb) {
        final file = File(customWallUrl);
        if (file.existsSync()) {
          customWallWidget = Image.file(
            file,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.high,
          );
        }
      }
    }
    return Scaffold(
      backgroundColor: AppleColors.background,
      extendBody: true,
      bottomNavigationBar: isLandscape ? null : IgnorePointer(
        ignoring: _privacyPortalAnimating,
        child: Opacity(opacity: _privacyPortalAnimating ? 0 : 1, child: Center(
        heightFactor: 1,
        child: AppleLiquidGlassDock(selectedIndex: safeTabIndex,
          onSelect: (i) => setState(() => _tabIndex = i),
          isLandscape: false, items: dockItems),
      ))),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Minimal Apple background: true black, faint top lift, and a softly
          // blurred ambient artwork of the featured title on the home tab.
          RepaintBoundary(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 600),
              child: AppleAmbientBackground(
                key: ValueKey<String>(
                  '$ambientPoster|${widget.storage.wallpaperPreset}|$customWallUrl|${widget.storage.ambientGlowEnabled}|$blurSigma',
                ),
                preset: widget.storage.wallpaperPreset,
                customWallpaper: customWallWidget,
                showAmbientArtwork: widget.storage.ambientGlowEnabled,
                blurSigma: blurSigma,
                artwork: ambientPoster.isEmpty && ambientTitle.isEmpty
                    ? null
                    : Opacity(
                        opacity: 0.55,
                        child: PosterImage(
                          url: ambientPoster,
                          title: ambientTitle,
                          highRes: true,
                          placeholder: const SizedBox.shrink(),
                        ),
                      ),
              ),
            ),
          ),
          // Active page content (with right clearance in landscape for the right-side Dock)
          Padding(
            padding: EdgeInsets.only(
              bottom: !isLandscape && safeTabIndex == pages.length - 1
                  ? AppleLiquidGlassDock.portraitFootprint(context) : 0,
              right: isLandscape
                  ? AppleLiquidGlassDock.landscapeFootprint(context)
                  : 0,
            ),
            child: RepaintBoundary(child: pages[safeTabIndex]),
          ),
          // iPhone / iPad style Dock:
          // - Portrait: bottom floating rounded-rectangle dock
          // - Landscape: right-side vertical dock
          if (isLandscape)
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              child: Center(
                child: AppleLiquidGlassDock(
                  selectedIndex: safeTabIndex,
                  onSelect: (i) => setState(() => _tabIndex = i),
                  isLandscape: true,
                  items: dockItems,
                ),
              ),
            ),
          if (_privacyPortalAnimating)
            Positioned.fill(
              child: _PrivacyModePortalAnimation(
                key: ValueKey('privacy_portal_$_privacyPortalRunId'),
                onFinished: () {
                  if (mounted) {
                    setState(() => _privacyPortalAnimating = false);
                  }
                },
              ),
            ),
        ],
      ),
    );
  }
  Widget _buildHomeTab(BuildContext context, {required bool useSidebar}) {
    if (_config == null && !_privateSessionUnlocked) {
      return _buildWelcomeOnboarding(context);
    }
    final depots =
        _privateSessionUnlocked ? const <CmsDepot>[] : (_config?.depots ?? const []);
    final history = _privateSessionUnlocked
        ? const <WatchHistoryEntry>[]
        : widget.storage.getWatchHistory();
    final horizontalPad = useSidebar ? 24.0 : 16.0;
    final topSafePad = MediaQuery.paddingOf(context).top;
    final activeFilterCount = _currentFilter.activeDimensionCount;
    return SafeArea(
      top: false,
      bottom: false,
      right: !useSidebar,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compactHeader = constraints.maxWidth < 600;
          final sourceControls = Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (depots.isNotEmpty) ...[
                Flexible(child: _buildHeaderCapsule(
                compact: compactHeader,
                  icon: CupertinoIcons.archivebox_fill,
                  label: compactHeader ? '' : (widget.storage.activeDepotName.isEmpty
                      ? '切换仓库' : widget.storage.activeDepotName),
                  onTap: _showDepotPickerDialog,
                )),
                const SizedBox(width: 6),
              ],
              Flexible(child: _buildHeaderCapsule(
                compact: compactHeader,
                icon: _privateSessionUnlocked
                    ? CupertinoIcons.lock_shield_fill : CupertinoIcons.layers_alt_fill,
                label: _activeSite?.name ??
                    (_privateSessionUnlocked ? '选择隐私源' : '选择片源'),
                onTap: _showSitePickerDialog,
              )),
            ],
          );
          final maxH =
              constraints.maxHeight > 0 ? constraints.maxHeight : 800.0;
          final s1 = ((topSafePad * 0.35) / maxH).clamp(0.008, 0.045);
          final s2 = ((topSafePad * 0.78) / maxH).clamp(0.020, 0.085);
          final s3 = ((topSafePad + 16.0) / maxH).clamp(0.038, 0.13);
          return ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (rect) => LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: const [
                Color(0x00FFFFFF),
                Color(0x1EFFFFFF),
                Color(0x88FFFFFF),
                Color(0xFFFFFFFF),
                Color(0xFFFFFFFF),
                Color(0x00FFFFFF),
              ],
              stops: [0.0, s1, s2, s3, 0.968, 1.0],
            ).createShader(rect),
            child: CustomScrollView(
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.only(top: topSafePad),
                  sliver: CupertinoSliverRefreshControl(
                    onRefresh: _refreshCurrentHomeView,
                  ),
                ),
                // Horizontal padding is applied per block so the horizontal shelves
                // (继续观看 / 分类) can run edge-to-edge with a soft fade instead of
                // being hard-clipped by the page margin.
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    0,
                    useSidebar && _isMacOS ? 24 : 12,
                    0,
                    12,
                  ),
                  sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Top Header Bar (5x tap on brand logo opens number-pad unlock for Privacy Mode;
                  // top-right button is Global Search)
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: horizontalPad),
                    child: Row(
                      children: [
                        Flexible(
                          flex: 0,
                          child: GestureDetector(
                            key: const ValueKey('home-brand-logo'),
                            behavior: HitTestBehavior.opaque,
                            onTap: _handleHomeLogoTap,
                            child: MarcoBrandLogo(
                              iconSize: compactHeader ? 24 : 28,
                              fontSize: compactHeader ? 14 : 16.5,
                              showWordmark: !_privateSessionUnlocked || !compactHeader,
                            ),
                          ),
                        ),
                        if (_privateSessionUnlocked) ...[
                          const SizedBox(width: 8),
                          GestureDetector(
                            key: const ValueKey('home-exit-privacy-pill'),
                            onTap: _exitPrivacySpace,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 9,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [
                                    Color(0xFF7C3AED),
                                    Color(0xFF4F46E5),
                                  ],
                                ),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: const Color(0x88C4B5FD),
                                  width: 0.6,
                                ),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    CupertinoIcons.eye_slash_fill,
                                    color: Colors.white,
                                    size: 11.5,
                                  ),
                                  SizedBox(width: 4),
                                  Text(
                                    '隐私 · 退出',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(width: 8),
                        Expanded(child: sourceControls),
                        const SizedBox(width: 6),
                        Builder(
                          builder: (context) {
                            final loggedCount = NetdiskService.drives
                                .where((d) =>
                                    widget.storage.isNetdiskLoggedIn(d.key))
                                .length;
                            return ApplePressableScale(
                              key: const ValueKey('home-netdisk-button'),
                              pressedScale: 0.93,
                              pressedOpacity: 0.86,
                              onTap: () => showNetdiskAccountSheet(
                                context,
                                widget.storage,
                                onChanged: () {
                                  if (mounted) setState(() {});
                                },
                              ),
                              child: LiquidGlass(
                                borderRadius: 999,
                                elevated: false,
                                rimStrength: 0.9,
                                tint: loggedCount > 0
                                    ? const Color(0x33165B33)
                                    : const Color(0x281E1E24),
                                padding: EdgeInsets.symmetric(
                                  horizontal: compactHeader ? 8.5 : 11,
                                  vertical: 8.5,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      loggedCount > 0
                                          ? CupertinoIcons.cloud_fill
                                          : CupertinoIcons.qrcode_viewfinder,
                                      color: loggedCount > 0
                                          ? AppleColors.systemGreen
                                          : const Color(0xFF5AC8FA),
                                      size: 13.5,
                                    ),
                                    if (!compactHeader) ...[
                                      const SizedBox(width: 4),
                                      Text(
                                        loggedCount > 0
                                            ? '网盘 · $loggedCount'
                                            : '网盘',
                                        style: const TextStyle(
                                          color: AppleColors.labelPrimary,
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                        const SizedBox(width: 6),
                        CupertinoButton(
                          key: const ValueKey('home-search-button'),
                          padding: EdgeInsets.zero,
                          minSize: 33,
                          onPressed: _showGlobalSearchSheet,
                          child: const LiquidGlass(
                            width: 33,
                            height: 33,
                            borderRadius: 999,
                            elevated: false,
                            tint: Color(0x521E1E22),
                            child: Center(
                              child: Icon(
                                CupertinoIcons.search,
                                color: AppleColors.labelPrimary,
                                size: 16,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // If config has only Android JAR (`csp_*`) sites and no direct HTTP sites
                  if (_activeSite == null) ...[
                    const SizedBox(height: 24),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: horizontalPad),
                      child: _privateSessionUnlocked
                          ? _buildEmptyPrivacySpaceNotice(context)
                          : _buildPluginOnlyConfigNotice(context),
                    ),
                  ] else ...[
                    // History shelf — newest first; hidden in Privacy Mode.
                    if (!_privateSessionUnlocked &&
                        widget.storage.showContinueWatching &&
                        history.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: horizontalPad),
                        child: Row(
                          children: [
                            const Text(
                              '历史记录',
                              style: TextStyle(
                                color: AppleColors.labelPrimary,
                                fontSize: 19,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.4,
                              ),
                            ),
                            const Spacer(),
                            CupertinoButton(
                              padding: EdgeInsets.zero,
                              minSize: 24,
                              onPressed: _showWatchHistorySheet,
                              child: const Text(
                                '查看全部',
                                style: TextStyle(
                                  color: AppleColors.systemBlue,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      AppleEdgeFade(
                        fadeStart: false,
                        fadeEnd: true,
                        fadeWidth: 18,
                        child: SizedBox(
                          height: 96,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            clipBehavior: Clip.none,
                            physics: const BouncingScrollPhysics(),
                            padding: EdgeInsets.symmetric(
                              horizontal: horizontalPad,
                              vertical: 3,
                            ),
                            itemCount: history.length.clamp(0, 8),
                            separatorBuilder: (_, __) =>
                                const SizedBox(width: 12),
                            itemBuilder: (ctx, i) =>
                                _buildContinueWatchingCard(history[i]),
                          ),
                        ),
                      ),
                    ],
                    // Featured Hero Showcase Card on first page when videos exist
                    if (widget.storage.showHeroBanner &&
                        !CspBridge.isMyDriveSite(_activeSite!) &&
                        _homeVideos.isNotEmpty &&
                        _primaryTab == 'recommend' &&
                        !_currentFilter.hasSubFilter &&
                        _currentPage == 1) ...[
                      const SizedBox(height: 18),
                      Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: horizontalPad),
                        child: _buildHeroShowcaseCard(
                          _activeSite!,
                          _homeVideos.first,
                          wide: useSidebar,
                        ),
                      ),
                    ],
                    if (CspBridge.isMyDriveSite(_activeSite!)) ...[
                      const SizedBox(height: 16),
                      Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: horizontalPad),
                        child: _buildMyDriveNetdiskBanner(_activeSite!),
                      ),
                    ],
                    // Fixed 5 Primary Category Tabs (推荐、电影、剧集、动漫、综艺) + Filter Button
                    const SizedBox(height: 18),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: horizontalPad),
                      child: Row(
                        children: [
                          Expanded(
                            child: SizedBox(
                              height: 36,
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                physics: const BouncingScrollPhysics(),
                                itemCount: CmsParser.primaryHomeTabs.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(width: 8),
                                itemBuilder: (ctx, idx) {
                                  final (tabKey, tabLabel) =
                                      CmsParser.primaryHomeTabs[idx];
                                  return _buildCategoryPill(
                                    label: tabLabel,
                                    selected: _primaryTab == tabKey,
                                    onTap: () => _selectPrimaryTab(tabKey),
                                  );
                                },
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          GestureDetector(
                            key: const ValueKey('home-filter-button'),
                            onTap: () => setState(
                              () => _filterExpanded = !_filterExpanded,
                            ),
                            child: LiquidGlass(
                              height: 36,
                              borderRadius: 999,
                              elevated: false,
                              rimStrength:
                                  (_filterExpanded || activeFilterCount > 0)
                                      ? 1.05
                                      : 0.88,
                              tint: (_filterExpanded || activeFilterCount > 0)
                                  ? const Color(0xCC0A84FF)
                                  : const Color(0x241E1E24),
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 13),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    CupertinoIcons.slider_horizontal_3,
                                    size: 14,
                                    color: (_filterExpanded ||
                                            activeFilterCount > 0)
                                        ? Colors.white
                                        : AppleColors.labelPrimary,
                                  ),
                                  const SizedBox(width: 5),
                                  Text(
                                    activeFilterCount > 0
                                        ? '筛选 · $activeFilterCount'
                                        : '筛选',
                                    style: TextStyle(
                                      color: (_filterExpanded ||
                                              activeFilterCount > 0)
                                          ? Colors.white
                                          : AppleColors.labelPrimary,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Collapsible Multi-Dimension Filter Drawer (类别 / 国家地区 / 年份)
                    AnimatedSize(
                      duration: const Duration(milliseconds: 260),
                      curve: Curves.easeOutCubic,
                      child: _filterExpanded
                          ? Padding(
                              padding: EdgeInsets.fromLTRB(
                                horizontalPad,
                                12,
                                horizontalPad,
                                2,
                              ),
                              child: _buildHomeFilterDrawer(),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (_activeSite != null) ...[
            if (_homeError != null)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          CupertinoIcons.exclamationmark_triangle_fill,
                          color: AppleColors.systemOrange,
                          size: 38,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _homeError!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: AppleColors.labelSecondary,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 10,
                          children: [
                            AppleCapsuleButton(
                              label: '重试',
                              icon: CupertinoIcons.refresh,
                              primary: true,
                              compact: true,
                              onPressed: _retryHomeError ?? _loadSiteHome,
                            ),
                            if (CmsClient.needsSourceVerification(_activeSite!, _homeErrorCause))
                              SourceVerificationButton(client: widget.client, site: _activeSite!,
                                onVerified: _retryHomeError ?? _loadSiteHome),
                            AppleCapsuleButton(
                              label: '切换其他片源',
                              icon: CupertinoIcons.layers_alt,
                              compact: true,
                              onPressed: _showSitePickerDialog,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: EdgeInsets.symmetric(
                  horizontal: horizontalPad,
                  vertical: 8,
                ),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: switch (widget.storage.gridDensity) {
                      'comfortable' => useSidebar ? 210 : 162,
                      'compact' => useSidebar ? 148 : 108,
                      _ => useSidebar ? 176 : 132,
                    },
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.56,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final video = _homeVideos[index];
                      return _buildVideoCard(_activeSite!, video);
                    },
                    childCount: _homeVideos.length,
                  ),
                ),
              ),
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(
                  top: 18,
                  bottom: useSidebar ? 32 : 128,
                ),
                child: Center(
                  child: (_homeLoading || _loadingMore)
                      ? const CupertinoActivityIndicator(radius: 13)
                      : (_homeVideos.isEmpty && _homeError == null)
                          ? const Padding(
                              padding: EdgeInsets.symmetric(vertical: 40),
                              child: Text(
                                '当前筛选条件下暂无影片，试试调整筛选或切换分类',
                                style: TextStyle(
                                  color: AppleColors.labelSecondary,
                                  fontSize: 14,
                                ),
                              ),
                            )
                      : (_homeError == null && _currentPage < _pageCount
                          ? AppleCapsuleButton(
                              key: const ValueKey('home-load-more-button'),
                              label: '加载更多影片',
                              icon: CupertinoIcons.arrow_down_circle,
                              onPressed: () => _reloadFilteredListing(
                                page: _currentPage + 1,
                              ),
                            )
                          : const SizedBox.shrink()),
                ),
              ),
            ),
          ],
        ],
      ),
          );
        },
      ),
    );
  }
  Widget _buildWelcomeOnboarding(BuildContext context) {
    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: AppleGlassSurface(
              padding: const EdgeInsets.all(28),
              borderRadius: BorderRadius.circular(26),
              color: const Color(0xCC16171D),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const MarcoBrandLogo(
                    iconSize: 78,
                    fontSize: 24,
                    stacked: true,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '把今晚，留给好故事。',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppleColors.labelPrimary,
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    '适用于手机、平板与桌面的播放器。导入自己的订阅或本地配置后开始使用。',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppleColors.labelSecondary,
                      fontSize: 14,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: AppleCapsuleButton(
                      label: '导入配置地址或 JSON',
                      icon: CupertinoIcons.add_circled_solid,
                      primary: true,
                      onPressed: () => _showImportConfigDialog(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: AppleCapsuleButton(
                      label: '一键粘贴剪贴板并导入',
                      icon: CupertinoIcons.doc_on_clipboard_fill,
                      onPressed: _quickImportFromClipboard,
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: AppleCapsuleButton(
                      label: '从跨平台备份恢复',
                      icon: CupertinoIcons.arrow_2_circlepath,
                      onPressed: _showBackupRestoreDialog,
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    '本产品仅为播放工具，不内置、不提供、不托管任何影视资源或配置地址。',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppleColors.labelTertiary,
                      fontSize: 11,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
  Widget _buildEmptyPrivacySpaceNotice(BuildContext context) {
    return AppleGlassSurface(
      padding: const EdgeInsets.all(24),
      borderRadius: BorderRadius.circular(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                CupertinoIcons.eye_slash_fill,
                color: Color(0xFFA78BFA),
                size: 22,
              ),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  '隐私分组模式 · 独立无痕空间',
                  style: TextStyle(
                    color: AppleColors.labelPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            '当前尚未添加任何隐私分组订阅。隐私空间与正常模式完全隔离：不保留观看历史记录，搜索、收藏与片源数据互不共通。',
            style: TextStyle(
              color: AppleColors.labelSecondary,
              fontSize: 13,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              AppleCapsuleButton(
                label: '导入隐私订阅 (VOD/M3U/JSON)',
                icon: CupertinoIcons.lock_fill,
                primary: true,
                compact: true,
                onPressed: () => _showImportConfigDialog(
                  initialIsPrivate: true,
                  initialGroup: '隐私分组',
                ),
              ),
              AppleCapsuleButton(
                label: '管理隐私订阅与密码',
                icon: CupertinoIcons.slider_horizontal_3,
                compact: true,
                onPressed: _showPrivateResourcesSheet,
              ),
              AppleCapsuleButton(
                label: '退出隐私模式',
                icon: CupertinoIcons.lock_open_fill,
                compact: true,
                onPressed: _exitPrivacySpace,
              ),
            ],
          ),
        ],
      ),
    );
  }
  Widget _buildPluginOnlyConfigNotice(BuildContext context) {
    final pluginCount = _config?.pluginOnlySites.length ?? 0;
    final depotCount = _config?.depots.length ?? 0;
    final liveCount = _config?.lives.length ?? 0;
    final String titleText;
    final String bodyText;
    if (pluginCount > 0) {
      titleText = '已成功加载配置（共 $pluginCount 个安卓专用插件站点）';
      bodyText =
          '当前仓库中的片源全部为安卓 JAR 爬虫插件（csp_*）。由于苹果 iOS / macOS 系统安全机制限制，无法直接运行安卓 DEX 字节码插件；Apple 端支持所有标准 HTTP/HTTPS CMS 站点（type 0 / 1 / 4）、已移植 Guard/DRPY/JS/Py 规则源与 M3U/TXT 电视直播源。';
    } else if (liveCount > 0) {
      titleText = '已成功加载直播配置（共 $liveCount 个直播源）';
      bodyText = '当前订阅仅包含电视直播频道，可直接前往直播页观看，或导入点播订阅源。';
    } else {
      titleText = '当前订阅暂未加载到可用片源';
      bodyText = '请尝试在设置中刷新订阅源、切换其他子仓库，或导入新的影视/直播配置地址。';
    }
    return AppleGlassSurface(
      padding: const EdgeInsets.all(22),
      borderRadius: BorderRadius.circular(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                CupertinoIcons.info_circle_fill,
                color: AppleColors.systemBlue,
                size: 22,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  titleText,
                  style: const TextStyle(
                    color: AppleColors.labelPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            bodyText,
            style: const TextStyle(
              color: AppleColors.labelSecondary,
              fontSize: 13,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              if (depotCount > 1)
                AppleCapsuleButton(
                  label: '切换其他子仓库 ($depotCount)',
                  icon: CupertinoIcons.archivebox_fill,
                  primary: true,
                  compact: true,
                  onPressed: _showDepotPickerDialog,
                ),
              if (liveCount > 0)
                AppleCapsuleButton(
                  label: '观看电视直播 ($liveCount)',
                  icon: CupertinoIcons.dot_radiowaves_left_right,
                  primary: depotCount <= 1,
                  compact: true,
                  onPressed: () => setState(() => _tabIndex = 1),
                ),
              AppleCapsuleButton(
                label: '查看全部站点列表',
                icon: CupertinoIcons.list_bullet,
                compact: true,
                onPressed: _showSitePickerDialog,
              ),
              AppleCapsuleButton(
                label: '导入其他配置',
                icon: CupertinoIcons.add,
                compact: true,
                onPressed: _showImportConfigDialog,
              ),
            ],
          ),
        ],
      ),
    );
  }
  Widget _buildHeaderCapsule({
    required IconData icon,
    bool compact = false,
    required String label,
    required VoidCallback onTap,
  }) {
    return ApplePressableScale(
      pressedScale: 0.93,
      pressedOpacity: 0.86,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 176),
        child: LiquidGlass(
          borderRadius: 999,
          elevated: false,
          rimStrength: 0.9,
          tint: const Color(0x281E1E24),
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 8 : 12,
            vertical: 8.5,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!compact || label.isEmpty)
                Icon(icon, color: AppleColors.labelSecondary, size: 13.5),
              if (!compact) const SizedBox(width: 5),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppleColors.labelPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (!compact) const SizedBox(width: 4),
              if (!compact)
                const Icon(
                  CupertinoIcons.chevron_down,
                  color: AppleColors.labelSecondary,
                  size: 11.5,
                ),
            ],
          ),
        ),
      ),
    );
  }
  Widget _buildHeroShowcaseCard(
    CmsSite site,
    CmsVideo featured, {
    required bool wide,
  }) {
    final tagChips = <String>[
      if (featured.year.trim().isNotEmpty) featured.year.trim(),
      if (featured.area.trim().isNotEmpty) featured.area.trim(),
      if (featured.remarks.trim().isNotEmpty) featured.remarks.trim(),
    ];
    final infoLine = featured.description.trim().isNotEmpty
        ? featured.description.trim()
        : (featured.actor.trim().isNotEmpty ? '主演：${featured.actor.trim()}' : '');
    return ApplePressableScale(
      pressedScale: 0.965,
      pressedOpacity: 0.92,
      onTap: () => _openVideoDetail(site, featured),
      child: SizedBox(
        height: wide ? 256 : 212,
        child: AppleSmoothClipCard(
          borderRadius: 30,
          backgroundColor: const Color(0xFF111114),
          rimStrength: 1.05,
          boxShadow: const [
            BoxShadow(
              color: Color(0x59000000),
              blurRadius: 26,
              offset: Offset(0, 12),
            ),
          ],
          child: Stack(
            fit: StackFit.expand,
            children: [
              ImageFiltered(
                imageFilter: ImageFilter.blur(
                  sigmaX: 36,
                  sigmaY: 36,
                  tileMode: TileMode.mirror,
                ),
                child: PosterImage(
                  url: featured.poster,
                  title: featured.title,
                  highRes: true,
                  placeholder: const SizedBox.shrink(),
                ),
              ),
              Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0x55000000),
                      Color(0xAD07080C),
                      Color(0xEB050508),
                    ],
                    stops: [0.0, 0.55, 1.0],
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.all(wide ? 22 : 16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AspectRatio(
                      aspectRatio: 2 / 3,
                      child: AppleSmoothClipCard(
                        borderRadius: 18,
                        backgroundColor: const Color(0xFF1A1A20),
                        rimStrength: 0.88,
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x48000000),
                            blurRadius: 14,
                            offset: Offset(0, 6),
                          ),
                        ],
                        child: PosterImage(
                          url: featured.poster,
                          title: featured.title,
                          highRes: true,
                          placeholder: _buildPosterPlaceholder(),
                        ),
                      ),
                    ),
                    SizedBox(width: wide ? 20 : 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Top badge
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8.5,
                              vertical: 3.5,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0x38FFFFFF),
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
                                  CupertinoIcons.sparkles,
                                  color: Color(0xFF5AC8FA),
                                  size: 11,
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    '今日首推 · ${site.name}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: AppleColors.labelPrimary,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 0.1,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          // Title
                          Text(
                            featured.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppleColors.labelPrimary,
                              fontSize: wide ? 23 : 18.5,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.4,
                              height: 1.2,
                            ),
                          ),
                          if (tagChips.isNotEmpty) ...[
                            const SizedBox(height: 7),
                            Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              children: [
                                for (final chip in tagChips)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 7,
                                      vertical: 2.5,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0x29FFFFFF),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      chip,
                                      style: const TextStyle(
                                        color: AppleColors.labelSecondary,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                          if (infoLine.isNotEmpty) ...[
                            const SizedBox(height: 7),
                            Text(
                              infoLine,
                              maxLines: wide ? 2 : 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppleColors.labelSecondary,
                                fontSize: 12,
                                height: 1.35,
                              ),
                            ),
                          ],
                          const Spacer(),
                          // Bottom row: Watch Now button anchored at bottom-right corner
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              AppleCapsuleButton(
                                key: const ValueKey('hero-watch-now-button'),
                                label: '立即观看',
                                icon: CupertinoIcons.play_fill,
                                primary: true,
                                compact: true,
                                onPressed: () => _openVideoDetail(site, featured),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
  Widget _buildHomeFilterDrawer() {
    final subCats = CmsParser.subCategoriesForPrimaryTab(
      _categories,
      _primaryTab,
    );
    final existingNames = subCats.map((c) => c.name.trim()).toSet();
    final extraGenres = [
      for (final g in CmsParser.fallbackGenreTags)
        if (!existingNames.any((n) => n.contains(g))) g,
    ];
    final hasAnyFilter = _currentFilter.hasSubFilter;

    return LiquidGlass(
      key: const ValueKey('home-filter-drawer'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      borderRadius: 22,
      elevated: false,
      rimStrength: 0.95,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                CupertinoIcons.slider_horizontal_3,
                color: AppleColors.systemBlue,
                size: 14,
              ),
              const SizedBox(width: 6),
              const Text(
                '多维片库筛选',
                style: TextStyle(
                  color: AppleColors.labelPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (hasAnyFilter)
                GestureDetector(
                  onTap: () {
                    setState(() {
                      _filterSubCategoryId = '';
                      _filterGenreLabel = '';
                      _filterArea = '';
                      _filterYear = '';
                    });
                    _reloadFilteredListing(page: 1);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0x280A84FF),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: const Color(0x555AC8FA),
                        width: 0.6,
                      ),
                    ),
                    child: const Text(
                      '重置筛选',
                      style: TextStyle(
                        color: AppleColors.systemBlue,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          // 1. 类别 (Sub-categories from site + Genre tags)
          _buildFilterDimensionRow(
            title: '类别',
            children: [
              _buildMiniFilterChip(
                label: '全部',
                selected:
                    _filterSubCategoryId.isEmpty && _filterGenreLabel.isEmpty,
                onTap: () {
                  setState(() {
                    _filterSubCategoryId = '';
                    _filterGenreLabel = '';
                  });
                  _reloadFilteredListing(page: 1);
                },
              ),
              for (final cat in subCats)
                _buildMiniFilterChip(
                  label: cat.name,
                  selected: _filterSubCategoryId == cat.id,
                  onTap: () {
                    setState(() {
                      _filterSubCategoryId = cat.id;
                      _filterGenreLabel = '';
                    });
                    _reloadFilteredListing(page: 1);
                  },
                ),
              for (final genre in extraGenres)
                _buildMiniFilterChip(
                  label: genre,
                  selected: _filterGenreLabel == genre &&
                      _filterSubCategoryId.isEmpty,
                  onTap: () {
                    setState(() {
                      _filterGenreLabel = genre;
                    });
                    _reloadFilteredListing(page: 1);
                  },
                ),
            ],
          ),
          const SizedBox(height: 10),
          // 2. 地区 (Area / Country)
          _buildFilterDimensionRow(
            title: '地区',
            children: [
              for (final area in CmsParser.filterAreas)
                _buildMiniFilterChip(
                  label: area,
                  selected: (_filterArea.isEmpty && area == '全部') ||
                      _filterArea == area,
                  onTap: () {
                    setState(() {
                      _filterArea = area == '全部' ? '' : area;
                    });
                    _reloadFilteredListing(page: 1);
                  },
                ),
            ],
          ),
          const SizedBox(height: 10),
          // 3. 年份 (Year)
          _buildFilterDimensionRow(
            title: '年份',
            children: [
              for (final yr in CmsParser.filterYears)
                _buildMiniFilterChip(
                  label: yr,
                  selected: (_filterYear.isEmpty && yr == '全部') ||
                      _filterYear == yr,
                  onTap: () {
                    setState(() {
                      _filterYear = yr == '全部' ? '' : yr;
                    });
                    _reloadFilteredListing(page: 1);
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
  Widget _buildFilterDimensionRow({
    required String title,
    required List<Widget> children,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 36,
          child: Text(
            title,
            style: const TextStyle(
              color: AppleColors.labelSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            child: Row(
              children: [
                for (int i = 0; i < children.length; i++) ...[
                  if (i > 0) const SizedBox(width: 7),
                  children[i],
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
  Widget _buildMiniFilterChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return ApplePressableScale(
      pressedScale: 0.92,
      pressedOpacity: 0.86,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 12.5, vertical: 6.5),
        decoration: BoxDecoration(
          gradient: selected
              ? const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFF2894FF), Color(0xFF0A84FF)],
                )
              : const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0x26FFFFFF), Color(0x14FFFFFF)],
                ),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? const Color(0xAA80D4FF)
                : const Color(0x2EFFFFFF),
            width: 0.7,
          ),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          strutStyle: const StrutStyle(
            forceStrutHeight: true,
            height: 1.1,
            fontSize: 12,
          ),
          style: TextStyle(
            color: selected ? Colors.white : AppleColors.labelPrimary,
            fontSize: 12,
            height: 1.1,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
  String _resolveHistoryPoster(WatchHistoryEntry entry) {
    final direct = entry.poster.trim();
    if (direct.isNotEmpty) return direct;
    for (final v in _homeVideos) {
      if ((v.id == entry.id || v.title == entry.title) &&
          v.poster.trim().isNotEmpty) {
        return v.poster.trim();
      }
    }
    for (final f in widget.storage.getFavorites()) {
      if ((f.id == entry.id || f.title == entry.title) &&
          f.poster.trim().isNotEmpty) {
        return f.poster.trim();
      }
    }
    return '';
  }

  Widget _buildContinueWatchingCard(WatchHistoryEntry entry) {
    final resolvedPoster = _resolveHistoryPoster(entry);
    final pct = (entry.progressFraction * 100).round();
    return ApplePressableScale(
      key: ValueKey('cw_${entry.site}_${entry.id}'),
      pressedScale: 0.955,
      pressedOpacity: 0.90,
      onTap: () {
        if (_config == null) return;
        final site = _config!.supportedSites.firstWhere(
          (s) => s.key == entry.site,
          orElse: () => _activeSite!,
        );
        _openVideoDetail(
          site,
          CmsVideo(
            id: entry.id,
            title: entry.title,
            poster: resolvedPoster,
          ),
        );
      },
      child: AppleGlassSurface(
        borderRadius: BorderRadius.circular(22),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        blurSigma: 32,
        child: SizedBox(
          width: 228,
          child: Row(
            children: [
              SizedBox(
                width: 52,
                height: 72,
                child: AppleSmoothClipCard(
                  borderRadius: 12,
                  backgroundColor: const Color(0xFF1A1A20),
                  rimStrength: 0.85,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      PosterImage(
                        url: resolvedPoster,
                        title: entry.title,
                        placeholder: _buildPosterPlaceholder(),
                      ),
                      Positioned(
                        right: 4,
                        bottom: 4,
                        child: Container(
                          width: 18,
                          height: 18,
                          decoration: BoxDecoration(
                            color: const Color(0xB8000000),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: const Color(0x66FFFFFF),
                              width: 0.6,
                            ),
                          ),
                          alignment: Alignment.center,
                          child: const Icon(
                            CupertinoIcons.play_fill,
                            color: Colors.white,
                            size: 9.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppleColors.labelPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      entry.episode.isEmpty
                          ? (pct > 0 ? '已看 $pct%' : '继续观看')
                          : entry.episode,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppleColors.labelSecondary,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: entry.progressFraction > 0
                            ? entry.progressFraction
                            : 0.15,
                        minHeight: 3.5,
                        backgroundColor: AppleColors.groupedTertiary,
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          AppleColors.systemBlue,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
  Widget _buildCategoryPill({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return ApplePressableScale(
      pressedScale: 0.92,
      pressedOpacity: 0.86,
      onTap: onTap,
      child: selected
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 7),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0xFFFFFFFF),
                    Color(0xFFE7E9EE),
                  ],
                ),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: const Color(0xB3FFFFFF),
                  width: 0.75,
                ),
              ),
              alignment: Alignment.center,
              child: Text(
                label,
                style: const TextStyle(
                  color: Color(0xFF0A0A0E),
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            )
          : LiquidGlass(
              borderRadius: 999,
              elevated: false,
              rimStrength: 0.88,
              tint: const Color(0x241E1E24),
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 7),
              child: Center(
                child: Text(
                  label,
                  style: const TextStyle(
                    color: AppleColors.labelPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
    );
  }
  Widget _buildMyDriveNetdiskBanner(CmsSite site) {
    return Container(
      key: const ValueKey('mydrive-netdisk-banner'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF12233B), Color(0xFF14161E)],
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: AppleColors.systemBlue.withValues(alpha: 0.45),
          width: 0.8,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                CupertinoIcons.qrcode_viewfinder,
                color: Color(0xFF5AC8FA),
                size: 22,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${site.name} · 电视端网盘扫码与账号管理',
                  style: const TextStyle(
                    color: AppleColors.labelPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              AppleCapsuleButton(
                label: '打开网盘中心',
                icon: CupertinoIcons.qrcode,
                primary: true,
                compact: true,
                onPressed: () => showNetdiskAccountSheet(
                  context,
                  widget.storage,
                  onChanged: () {
                    if (mounted) setState(() {});
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '点击下方网盘即可弹出官方扫码窗口，支持夸克（我的夸父）、UC（我的优汐）、百度（我的嘟嘟）、阿里云盘（我的阿狸）4K 原画线路：',
            style: TextStyle(
              color: AppleColors.labelSecondary,
              fontSize: 12.5,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final drive in NetdiskService.drives)
                AppleCapsuleButton(
                  label:
                      '${drive.tvAlias} · ${widget.storage.isNetdiskLoggedIn(drive.key) ? "已启用" : "扫码登录"}',
                  icon: widget.storage.isNetdiskLoggedIn(drive.key)
                      ? CupertinoIcons.checkmark_seal_fill
                      : CupertinoIcons.qrcode_viewfinder,
                  primary: widget.storage.isNetdiskLoggedIn(drive.key),
                  compact: true,
                  onPressed: () => showNetdiskAccountSheet(
                    context,
                    widget.storage,
                    initialDriveKey: drive.key,
                    onChanged: () {
                      if (mounted) setState(() {});
                    },
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
  Widget _buildPosterPlaceholder() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF242428), Color(0xFF161618)],
        ),
      ),
      alignment: Alignment.center,
      child: const Icon(
        CupertinoIcons.film,
        color: AppleColors.labelTertiary,
        size: 26,
      ),
    );
  }
  Widget _buildNetdiskCardPoster(String driveKey, String title) {
    final loggedIn = widget.storage.isNetdiskLoggedIn(driveKey);
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: loggedIn
              ? const [Color(0xFF143527), Color(0xFF0E1D17)]
              : const [Color(0xFF152946), Color(0xFF101724)],
        ),
      ),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(10),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            loggedIn ? CupertinoIcons.cloud_fill : CupertinoIcons.qrcode_viewfinder,
            color: loggedIn ? const Color(0xFF30D158) : const Color(0xFF5AC8FA),
            size: 38,
          ),
          const SizedBox(height: 8),
          Text(
            title.split('·').first.trim(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              loggedIn ? '已登录+启用中' : '点击扫码登录',
              style: TextStyle(
                color: loggedIn ? const Color(0xFF30D158) : const Color(0xFF5AC8FA),
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
  Widget _buildVideoCard(
    CmsSite site,
    CmsVideo video, {
    String? badge,
    VoidCallback? onTap,
  }) {
    final cardKey =
        'vcard_${site.key}_${video.id.isNotEmpty ? video.id : video.title}_${badge ?? ""}';
    return ApplePressableScale(
      key: ValueKey(cardKey),
      pressedScale: 0.945,
      pressedOpacity: 0.90,
      onTap: onTap ?? () => _openVideoDetail(site, video),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: AppleSmoothClipCard(
              borderRadius: 20,
              backgroundColor: const Color(0xFF1C1C20),
              rimStrength: 0.86,
              boxShadow: const [
                BoxShadow(
                  color: Color(0x36000000),
                  blurRadius: 12,
                  offset: Offset(0, 5),
                ),
              ],
              child: Stack(
                fit: StackFit.expand,
                children: [
                  video.id.startsWith('netdisk_qr:')
                      ? _buildNetdiskCardPoster(
                          video.id.substring('netdisk_qr:'.length).trim(),
                          video.title,
                        )
                      : PosterImage(
                          url: video.poster,
                          title: video.title,
                          placeholder: _buildPosterPlaceholder(),
                        ),
                  if (badge != null && badge.isNotEmpty)
                    Positioned(
                      top: 7,
                      left: 7,
                      right: 7,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: GlassworkBackdrop(
                            radius: 8,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7.5,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0x701E1E22),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: const Color(0x3DFFFFFF),
                                  width: 0.5,
                                ),
                              ),
                              child: Text(
                                badge,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: AppleColors.labelPrimary,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (video.remarks.isNotEmpty)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(8, 16, 8, 6),
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Color(0x00000000), Color(0xBD000000)],
                          ),
                        ),
                        child: Text(
                          video.remarks,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            color: AppleColors.labelPrimary,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 7),
          Text(
            video.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppleColors.labelPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
            ),
          ),
          if (widget.storage.cardSubtitleMode != 'none') ...[
            const SizedBox(height: 2),
            Text(
              switch (widget.storage.cardSubtitleMode) {
                'site' => site.name,
                'year_area' => [
                    video.year.trim(),
                    video.area.trim(),
                    video.tag.trim(),
                  ].where((s) => s.isNotEmpty).join(' · ').isNotEmpty
                      ? [
                          video.year.trim(),
                          video.area.trim(),
                          video.tag.trim(),
                        ].where((s) => s.isNotEmpty).join(' · ')
                      : (video.remarks.isNotEmpty ? video.remarks : site.name),
                _ => video.remarks.isNotEmpty ? video.remarks : site.name,
              },
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppleColors.labelSecondary,
                fontSize: 11,
              ),
            ),
          ],
        ],
      ),
    );
  }
  void _showGlobalSearchSheet() {
    final isPriv = _privateSessionUnlocked;
    showAppleModalSheet<void>(
      context: context,
      title: isPriv ? '隐私空间搜索' : '全站搜索',
      maxWidth: 680,
      ignoreKeyboardInsets: true,
      trailingAction: CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minSize: 28,
        onPressed: () {
          if (widget.storage.getSearchHistory(forPrivate: isPriv).isNotEmpty) {
            widget.storage.clearSearchHistory(forPrivate: isPriv).then((_) {
              if (mounted) setState(() {});
              _searchSheetListener?.call();
            });
          }
        },
        child: const Text(
          '清空历史',
          style: TextStyle(color: AppleColors.labelSecondary, fontSize: 13),
        ),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            _searchSheetListener = () {
              if (ctx.mounted) setSheetState(() {});
            };
            final history = widget.storage.getSearchHistory(forPrivate: isPriv);
            final size = MediaQuery.sizeOf(ctx);
            final wide = size.width > 640;
            final siteCounts = <String, int>{};
            final siteByKey = <String, CmsSite>{};
            for (final s in _visibleSupportedSites) {
              siteByKey['${s.subscriptionId}:${s.key}'] = s;
            }
            for (final (site, _) in _searchResults) {
              final k = '${site.subscriptionId}:${site.key}';
              siteByKey[k] = site;
              siteCounts[k] = (siteCounts[k] ?? 0) + 1;
            }
            if (_searchSiteFilterKey.isNotEmpty &&
                !siteByKey.containsKey(_searchSiteFilterKey)) {
              _searchSiteFilterKey = '';
            }
            final filterSiteEntries = siteByKey.entries.toList()
              ..sort((a, b) {
                final ca = siteCounts[a.key] ?? 0;
                final cb = siteCounts[b.key] ?? 0;
                if (ca != cb) return cb.compareTo(ca);
                return 0;
              });
            final filteredSearchResults = _searchSiteFilterKey.isEmpty
                ? _searchResults
                : _searchResults
                    .where(
                      (r) =>
                          '${r.$1.subscriptionId}:${r.$1.key}' ==
                          _searchSiteFilterKey,
                    )
                    .toList(growable: false);
            return SizedBox(
              height: (size.height * 0.75).clamp(400.0, 640.0),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: AppleSearchField(
                            controller: _searchController,
                            autofocus: true,
                            placeholder: '搜索片名、演员或导演…',
                            onSubmitted: (kw) {
                              _runGlobalSearch(kw);
                              setSheetState(() {});
                            },
                          ),
                        ),
                        const SizedBox(width: 10),
                        AppleCapsuleButton(
                          label: '搜索',
                          primary: true,
                          compact: true,
                          onPressed: () {
                            _runGlobalSearch(_searchController.text);
                            setSheetState(() {});
                          },
                        ),
                      ],
                    ),
                    if (history.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 30,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          physics: const BouncingScrollPhysics(),
                          itemCount: history.length,
                          separatorBuilder: (_, __) => const SizedBox(width: 8),
                          itemBuilder: (ctx, i) {
                            final kw = history[i];
                            return ApplePressableScale(
                              pressedScale: 0.92,
                              onTap: () {
                                _searchController.text = kw;
                                _runGlobalSearch(kw);
                                setSheetState(() {});
                              },
                              child: Container(
                                alignment: Alignment.center,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 5,
                                ),
                                decoration: BoxDecoration(
                                  color: AppleColors.groupedSecondary,
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(
                                    color: AppleColors.glassBorder,
                                    width: 0.5,
                                  ),
                                ),
                                child: Text(
                                  kw,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: AppleColors.labelSecondary,
                                    fontSize: 12,
                                    height: 1.1,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (filterSiteEntries.isNotEmpty) ...[
                            Container(
                              key: const ValueKey('search-site-filter-bar'),
                              width: wide ? 138 : 106,
                              decoration: BoxDecoration(
                                color: const Color(0x4018181E),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: AppleColors.glassBorder,
                                  width: 0.6,
                                ),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(16),
                                child: ListView.separated(
                                  scrollDirection: Axis.vertical,
                                  physics: const BouncingScrollPhysics(),
                                  padding: const EdgeInsets.all(6),
                                  itemCount: filterSiteEntries.length + 1,
                                  separatorBuilder: (_, __) =>
                                      const SizedBox(height: 6),
                                  itemBuilder: (ctx, idx) {
                                    final isAll = idx == 0;
                                    final key = isAll
                                        ? ''
                                        : filterSiteEntries[idx - 1].key;
                                    final site = isAll
                                        ? null
                                        : filterSiteEntries[idx - 1].value;
                                    final count = isAll
                                        ? _searchResults.length
                                        : (siteCounts[key] ?? 0);
                                    final selected =
                                        _searchSiteFilterKey == key;
                                    final titleText =
                                        isAll ? '全部线路' : site!.name;
                                    return ApplePressableScale(
                                      pressedScale: 0.94,
                                      pressedOpacity: 0.88,
                                      onTap: () {
                                        setSheetState(() {
                                          _searchSiteFilterKey =
                                              selected && !isAll ? '' : key;
                                        });
                                      },
                                      child: AnimatedContainer(
                                        duration:
                                            const Duration(milliseconds: 180),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 9,
                                          vertical: 9,
                                        ),
                                        decoration: BoxDecoration(
                                          gradient: selected
                                              ? const LinearGradient(
                                                  begin: Alignment.topLeft,
                                                  end: Alignment.bottomRight,
                                                  colors: [
                                                    Color(0xFF2E96FF),
                                                    Color(0xFF0A84FF),
                                                  ],
                                                )
                                              : null,
                                          color: selected
                                              ? null
                                              : (count > 0
                                                  ? const Color(0x283E9BFF)
                                                  : const Color(0x3826262E)),
                                          borderRadius:
                                              BorderRadius.circular(11),
                                          border: Border.all(
                                            color: selected
                                                ? const Color(0x99FFFFFF)
                                                : (count > 0
                                                    ? const Color(0x553E9BFF)
                                                    : const Color(0x1FFFFFFF)),
                                            width: 0.65,
                                          ),
                                        ),
                                        child: Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                titleText,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: selected
                                                      ? Colors.white
                                                      : (count > 0
                                                          ? AppleColors
                                                              .labelPrimary
                                                          : AppleColors
                                                              .labelSecondary),
                                                  fontSize: 12,
                                                  fontWeight:
                                                      selected || count > 0
                                                          ? FontWeight.w600
                                                          : FontWeight.w500,
                                                  height: 1.2,
                                                ),
                                              ),
                                            ),
                                            if (count > 0) ...[
                                              const SizedBox(width: 4),
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 5.5,
                                                  vertical: 2,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: selected
                                                      ? const Color(0x38FFFFFF)
                                                      : const Color(0x380A84FF),
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                          999),
                                                ),
                                                child: Text(
                                                  '$count',
                                                  style: TextStyle(
                                                    color: selected
                                                        ? Colors.white
                                                        : const Color(
                                                            0xFF70B8FF),
                                                    fontSize: 10.5,
                                                    fontWeight: FontWeight.w700,
                                                  ),
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
                            ),
                            const SizedBox(width: 11),
                          ],
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (_searching)
                                  const Padding(
                                    padding: EdgeInsets.only(bottom: 10),
                                    child: Row(
                                      children: [
                                        CupertinoActivityIndicator(radius: 9),
                                        SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            '正在并发检索所有可用片源…',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: AppleColors.labelSecondary,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                if (_searchNotices.isNotEmpty)
                                  ConstrainedBox(
                                    constraints: BoxConstraints(
                                      maxHeight: (size.height * 0.18)
                                          .clamp(68.0, 144.0),
                                    ),
                                    child: SingleChildScrollView(
                                      padding:
                                          const EdgeInsets.only(bottom: 10),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            _searchNotices.values.join('\n'),
                                            key: const ValueKey(
                                                'search-source-notices'),
                                            style: const TextStyle(
                                              color: AppleColors.labelSecondary,
                                              fontSize: 12,
                                            ),
                                          ),
                                          for (final site
                                              in _searchVerificationSites
                                                  .values)
                                            Padding(
                                              padding:
                                                  const EdgeInsets.only(top: 8),
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    site.name,
                                                    style: const TextStyle(
                                                      color: AppleColors
                                                          .labelSecondary,
                                                      fontSize: 12,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 4),
                                                  SourceVerificationButton(
                                                    key: ValueKey(
                                                        '$_searchEpoch:${site.subscriptionId}:${site.key}'),
                                                    client: widget.client,
                                                    site: site,
                                                    onVerified: () =>
                                                        _retryVerifiedSearch(
                                                            site),
                                                  ),
                                                ],
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                Expanded(
                                  child: filteredSearchResults.isEmpty &&
                                          !_searching
                                      ? Center(
                                          child: SingleChildScrollView(
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                const Icon(
                                                  CupertinoIcons.search,
                                                  color:
                                                      AppleColors.labelTertiary,
                                                  size: 42,
                                                ),
                                                const SizedBox(height: 10),
                                                Text(
                                                  !_searchPerformed
                                                      ? '输入关键词，并发检索全部已启用片源'
                                                      : (_searchSiteFilterKey
                                                                  .isNotEmpty &&
                                                              _searchResults
                                                                  .isNotEmpty)
                                                          ? '当前所选线路暂无匹配影片'
                                                          : _searchNotices
                                                                  .isEmpty
                                                              ? '没有找到匹配影片'
                                                              : '本次搜索未返回影片，请查看上方片源提示',
                                                  textAlign: TextAlign.center,
                                                  style: const TextStyle(
                                                    color: AppleColors
                                                        .labelSecondary,
                                                    fontSize: 14,
                                                  ),
                                                ),
                                                if (_searchSiteFilterKey
                                                        .isNotEmpty &&
                                                    _searchResults
                                                        .isNotEmpty) ...[
                                                  const SizedBox(height: 12),
                                                  AppleCapsuleButton(
                                                    label:
                                                        '查看全部线路 (${_searchResults.length})',
                                                    compact: true,
                                                    onPressed: () {
                                                      setSheetState(() {
                                                        _searchSiteFilterKey =
                                                            '';
                                                      });
                                                    },
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ),
                                        )
                                      : GridView.builder(
                                          keyboardDismissBehavior:
                                              ScrollViewKeyboardDismissBehavior
                                                  .onDrag,
                                          padding:
                                              const EdgeInsets.only(bottom: 16),
                                          gridDelegate:
                                              SliverGridDelegateWithMaxCrossAxisExtent(
                                            maxCrossAxisExtent:
                                                wide ? 156 : 120,
                                            mainAxisSpacing: 14,
                                            crossAxisSpacing: 10,
                                            childAspectRatio: 0.56,
                                          ),
                                          itemCount:
                                              filteredSearchResults.length,
                                          itemBuilder: (ctx, i) {
                                            final (site, video) =
                                                filteredSearchResults[i];
                                            return _buildVideoCard(
                                              site,
                                              video,
                                              badge: site.name,
                                              onTap: () {
                                                // Keep the search modal sheet resident underneath DetailScreen
                                                // so returning from DetailScreen lands directly back on search results.
                                                FocusScope.of(ctx).unfocus();
                                                _openVideoDetail(site, video);
                                              },
                                            );
                                          },
                                        ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ).whenComplete(() {
      _searchSheetListener = null;
    });
  }

  void _handleHomeLogoTap() {
    final now = DateTime.now();
    if (_lastLogoTapAt == null ||
        now.difference(_lastLogoTapAt!) > const Duration(milliseconds: 2500)) {
      _logoTapCount = 1;
    } else {
      _logoTapCount++;
    }
    _lastLogoTapAt = now;
    if (_logoTapCount >= 5) {
      _logoTapCount = 0;
      _lastLogoTapAt = null;
      _openPrivateSpaceWithAuth();
    }
  }

  void _enterPrivacySpaceDirectly() {
    HapticFeedback.heavyImpact();
    _searchSubscription?.cancel();
    _searchResults.clear();
    _searchController.clear();
    setState(() {
      _privateSessionUnlocked = true;
      _privacyPortalAnimating = true;
      _privacyPortalRunId++;
      _tabIndex = 0;
    });
    _reloadSavedConfig();
  }

  void _exitPrivacySpace() {
    HapticFeedback.lightImpact();
    _searchSubscription?.cancel();
    _searchResults.clear();
    _searchController.clear();
    setState(() {
      _privateSessionUnlocked = false;
    });
    _reloadSavedConfig();
  }

  void _openPrivateSpaceWithAuth() {
    if (_privateSessionUnlocked) {
      _exitPrivacySpace();
      return;
    }
    if (!widget.storage.hasPrivacyPassword) {
      _showSetPrivacyPasswordDialog(
        title: '设置隐私数字密码',
        subtitle: '请使用下方号码盘设置 4 位数字密码（后续连点 Logo 5 次输入密码即可直接进入隐私分组模式）',
        onSuccess: _enterPrivacySpaceDirectly,
      );
      return;
    }
    _showVerifyPrivacyPasswordDialog(
      onSuccess: _enterPrivacySpaceDirectly,
    );
  }

  void _showSetPrivacyPasswordDialog({
    String title = '设置隐私数字密码',
    String subtitle = '请输入 4 位数字作为隐私分组访问密码',
    VoidCallback? onSuccess,
  }) {
    String firstPin = '';
    String currentPin = '';
    bool confirming = false;
    String? err;
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'SetPrivacyPin',
      barrierColor: const Color(0xB3000000),
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (ctx, anim1, anim2) {
        return Center(
          child: StatefulBuilder(
            builder: (ctx, setPadState) {
              void handleDigit(String digit) async {
                if (currentPin.length >= 4) return;
                HapticFeedback.selectionClick();
                setPadState(() {
                  err = null;
                  currentPin += digit;
                });
                if (currentPin.length == 4) {
                  await Future<void>.delayed(const Duration(milliseconds: 120));
                  if (!ctx.mounted) return;
                  if (!confirming) {
                    setPadState(() {
                      firstPin = currentPin;
                      currentPin = '';
                      confirming = true;
                    });
                  } else {
                    if (currentPin == firstPin) {
                      await widget.storage.setPrivacyPassword(currentPin);
                      if (!ctx.mounted || !mounted ||
                          ModalRoute.of(ctx)?.isCurrent != true) {
                        return;
                      }
                      Navigator.of(ctx).pop();
                      onSuccess?.call();
                    } else {
                      HapticFeedback.heavyImpact();
                      setPadState(() {
                        err = '两次输入的密码不一致，请重新设置';
                        firstPin = '';
                        currentPin = '';
                        confirming = false;
                      });
                    }
                  }
                }
              }

              void handleBackspace() {
                if (currentPin.isEmpty) return;
                HapticFeedback.selectionClick();
                setPadState(() {
                  err = null;
                  currentPin = currentPin.substring(0, currentPin.length - 1);
                });
              }

              return _buildGlassPinPadCard(
                context: ctx,
                title: confirming ? '再次输入确认密码' : title,
                subtitle: confirming ? '请再次输入刚才设置的 4 位数字密码' : subtitle,
                pinLength: 4,
                enteredCount: currentPin.length,
                errorText: err,
                onDigit: handleDigit,
                onBackspace: handleBackspace,
                onCancel: () => Navigator.of(ctx).pop(),
              );
            },
          ),
        );
      },
      transitionBuilder: (ctx, anim, _, child) {
        final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutBack);
        return FadeTransition(
          opacity: anim,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.90, end: 1.0).animate(curved),
            child: child,
          ),
        );
      },
    );
  }

  void _showVerifyPrivacyPasswordDialog({required VoidCallback onSuccess}) {
    final savedPwd = widget.storage.privacyPassword.trim();
    final targetLen = savedPwd.length.clamp(4, 8);
    String currentPin = '';
    String? err;
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'VerifyPrivacyPin',
      barrierColor: const Color(0xB8000000),
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (ctx, anim1, anim2) {
        return Center(
          child: StatefulBuilder(
            builder: (ctx, setPadState) {
              void handleDigit(String digit) async {
                if (currentPin.length >= targetLen) return;
                HapticFeedback.selectionClick();
                setPadState(() {
                  err = null;
                  currentPin += digit;
                });
                if (widget.storage.verifyPrivacyPassword(currentPin)) {
                  await Future<void>.delayed(const Duration(milliseconds: 90));
                  if (!ctx.mounted || !mounted ||
                      ModalRoute.of(ctx)?.isCurrent != true) {
                    return;
                  }
                  Navigator.of(ctx).pop();
                  onSuccess();
                  return;
                }
                if (currentPin.length >= targetLen) {
                  HapticFeedback.heavyImpact();
                  setPadState(() {
                    err = '密码错误，请重新输入';
                  });
                  await Future<void>.delayed(const Duration(milliseconds: 340));
                  if (ctx.mounted) {
                    setPadState(() {
                      currentPin = '';
                    });
                  }
                }
              }

              void handleBackspace() {
                if (currentPin.isEmpty) return;
                HapticFeedback.selectionClick();
                setPadState(() {
                  err = null;
                  currentPin = currentPin.substring(0, currentPin.length - 1);
                });
              }

              return _buildGlassPinPadCard(
                context: ctx,
                title: '解锁隐私空间',
                subtitle: '输入设置的密码即可直接进入隐私分组模式',
                pinLength: targetLen,
                enteredCount: currentPin.length,
                errorText: err,
                onDigit: handleDigit,
                onBackspace: handleBackspace,
                onCancel: () => Navigator.of(ctx).pop(),
              );
            },
          ),
        );
      },
      transitionBuilder: (ctx, anim, _, child) {
        final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutBack);
        return FadeTransition(
          opacity: anim,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.90, end: 1.0).animate(curved),
            child: child,
          ),
        );
      },
    );
  }

  Widget _buildGlassPinPadCard({
    required BuildContext context,
    required String title,
    required String subtitle,
    required int pinLength,
    required int enteredCount,
    required String? errorText,
    required ValueChanged<String> onDigit,
    required VoidCallback onBackspace,
    required VoidCallback onCancel,
  }) {
    final hasError = errorText != null && errorText.isNotEmpty;
    const rows = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
    ];
    final card = Material(
      color: Colors.transparent,
      child: AppleGlassSurface(
        key: const ValueKey('privacy-pin-glass'),
        width: 326,
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
        borderRadius: BorderRadius.circular(32),
        elevated: true,
        child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF8B5CF6), Color(0xFF4F46E5)],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF8B5CF6).withValues(alpha: 0.45),
                        blurRadius: 16,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  alignment: Alignment.center,
                  child: const Icon(
                    CupertinoIcons.lock_shield_fill,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  hasError ? errorText : subtitle,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: hasError
                        ? AppleColors.systemRed
                        : AppleColors.labelSecondary,
                    fontSize: 12.5,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 18),
                // PIN indicator dots
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (int i = 0; i < pinLength; i++) ...[
                      if (i > 0) const SizedBox(width: 14),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i < enteredCount
                              ? (hasError
                                  ? AppleColors.systemRed
                                  : const Color(0xFFC4B5FD))
                              : const Color(0x1FFFFFFF),
                          border: Border.all(
                            color: i < enteredCount
                                ? (hasError
                                    ? AppleColors.systemRed
                                    : const Color(0xFFA78BFA))
                                : const Color(0x4DFFFFFF),
                            width: 1.2,
                          ),
                          boxShadow: i < enteredCount
                              ? [
                                  BoxShadow(
                                    color: (hasError
                                            ? AppleColors.systemRed
                                            : const Color(0xFF8B5CF6))
                                        .withValues(alpha: 0.65),
                                    blurRadius: 10,
                                  ),
                                ]
                              : null,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 22),
                // 3x4 Tactile Liquid Glass Number Pad
                for (final row in rows) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      for (final digit in row)
                        _buildPinPadDigitButton(
                          label: digit,
                          onTap: () => onDigit(digit),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildPinPadActionButton(
                      label: '取消',
                      onTap: onCancel,
                    ),
                    _buildPinPadDigitButton(
                      label: '0',
                      onTap: () => onDigit('0'),
                    ),
                    _buildPinPadActionButton(
                      icon: CupertinoIcons.delete_left_fill,
                      onTap: onBackspace,
                    ),
                  ],
                ),
              ],
        ),
      ),
    );
    return SafeArea(
      minimum: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        key: const ValueKey('privacy-pin-scroll'),
        child: card,
      ),
    );
  }

  Widget _buildPinPadDigitButton({
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 68,
        height: 68,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0x38FFFFFF),
              Color(0x1AFFFFFF),
            ],
          ),
          border: Border.all(
            color: const Color(0x36FFFFFF),
            width: 0.7,
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 26,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildPinPadActionButton({
    String? label,
    IconData? icon,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 68,
        height: 68,
        child: Center(
          child: icon != null
              ? Icon(icon, color: AppleColors.labelSecondary, size: 22)
              : Text(
                  label ?? '',
                  style: const TextStyle(
                    color: AppleColors.labelSecondary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
        ),
      ),
    );
  }

  void _showPrivateResourcesSheet() {
    showAppleModalSheet<void>(
      context: context,
      title: '隐私资源 · 隐藏列表',
      trailingAction: CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minSize: 28,
        onPressed: () {
          Navigator.of(context).pop();
          setState(() {
            _privateSessionUnlocked = false;
          });
          _reloadSavedConfig();
        },
        child: const Text(
          '锁定退出',
          style: TextStyle(color: AppleColors.systemOrange, fontSize: 13),
        ),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final allSubs = widget.storage.getSubscriptions();
          final privateSubs =
              allSubs.where((s) => s.isEffectivelyPrivate).toList();
          final privateSites = _config?.privateSupportedSites ?? const [];
          final privateLives = _config?.privateLives ?? const [];
          return ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(16),
            children: [
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  AppleCapsuleButton(
                    label: '导入隐私订阅 (VOD/M3U/JSON)',
                    icon: CupertinoIcons.lock_fill,
                    primary: true,
                    compact: true,
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      _showImportConfigDialog(
                        initialIsPrivate: true,
                        initialGroup: '隐私专区',
                      );
                    },
                  ),
                  AppleCapsuleButton(
                    label: '修改隐私密码',
                    icon: CupertinoIcons.lock_shield_fill,
                    compact: true,
                    onPressed: () {
                      _showSetPrivacyPasswordDialog(
                        title: '修改隐私访问密码',
                        subtitle: '请输入新的隐私空间密码：',
                      );
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (privateSites.isEmpty &&
                  privateSubs.isEmpty &&
                  privateLives.isEmpty)
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: AppleColors.groupedSecondary,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Column(
                    children: [
                      Icon(
                        CupertinoIcons.eye_slash_fill,
                        color: AppleColors.labelTertiary,
                        size: 38,
                      ),
                      SizedBox(height: 10),
                      Text(
                        '隐藏列表暂无隐私资源',
                        style: TextStyle(
                          color: AppleColors.labelPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SizedBox(height: 6),
                      Text(
                        '点击上方「导入隐私订阅」，或将下方现有订阅设为「隐私」，即可在此安全访问；日常浏览时完全隐藏。',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppleColors.labelSecondary,
                          fontSize: 12.5,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              if (privateSites.isNotEmpty) ...[
                AppleGroupedSection(
                  header: '隐藏影视片源 (${privateSites.length})',
                  footer: '点击任意隐私片源即可在主页立即加载浏览；点击右上角「锁定退出」后自动恢复隐藏。',
                  children: privateSites.map((s) {
                    final selected = s.key == _activeSite?.key;
                    return AppleGroupedTile(
                      icon: CupertinoIcons.lock_shield_fill,
                      iconBgColor: selected
                          ? AppleColors.systemBlue
                          : AppleColors.systemPurple,
                      title: s.name,
                      subtitle: '${s.group} · ${s.api}',
                      trailing: selected
                          ? const Icon(
                              CupertinoIcons.checkmark_alt,
                              color: AppleColors.systemBlue,
                              size: 18,
                            )
                          : const Text(
                              '立即访问',
                              style: TextStyle(
                                color: AppleColors.systemBlue,
                                fontSize: 12,
                              ),
                            ),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        if (s.isCatPaw && Uri.parse(s.api).path == '/api/baseset') {
                          _showCatPawSettings(s);
                          return;
                        }
                        setState(() {
                          _privateSessionUnlocked = true;
                          _activeSite = s;
                        });
                        _loadSiteHome();
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
              ],
              if (privateLives.isNotEmpty) ...[
                AppleGroupedSection(
                  header: '隐藏直播源 (${privateLives.length})',
                  children: [
                    for (int i = 0; i < privateLives.length; i++)
                      AppleGroupedTile(
                        icon: CupertinoIcons.dot_radiowaves_left_right,
                        iconBgColor: AppleColors.systemIndigo,
                        title: privateLives[i].name,
                        subtitle: '${privateLives[i].group} · M3U/TXT 直播',
                        trailingText: '去观看',
                        onTap: () {
                          Navigator.of(ctx).pop();
                          setState(() {
                            _privateSessionUnlocked = true;
                            _tabIndex = 1;
                          });
                          final idx = _visibleLives.indexWhere(
                            (l) => l.url == privateLives[i].url,
                          );
                          if (idx >= 0) _loadLivePlaylist(idx);
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
              if (allSubs.isNotEmpty)
                AppleGroupedSection(
                  header: '管理订阅隐私开关 (${allSubs.length})',
                  footer: '开启开关可将对应订阅移入隐私隐藏列表。',
                  children: allSubs.map((sub) {
                    final priv = sub.isEffectivelyPrivate;
                    return AppleGroupedTile(
                      icon: priv
                          ? CupertinoIcons.eye_slash_fill
                          : CupertinoIcons.globe,
                      iconBgColor: priv
                          ? AppleColors.systemPurple
                          : AppleColors.systemBlue,
                      title: '${sub.name} [${sub.format}]',
                      subtitle:
                          '分组：${sub.group} · ${sub.siteCount} 片源 / ${sub.liveCount} 直播',
                      trailing: CupertinoSwitch(
                        value: priv,
                        activeTrackColor: AppleColors.systemPurple,
                        onChanged: (val) async {
                          await widget.storage.toggleSubscriptionPrivacy(
                            sub.id,
                            val,
                          );
                          if (!val &&
                              (sub.group.contains('隐私') ||
                                  sub.group.contains('私密'))) {
                            await widget.storage.updateSubscriptionGroup(
                              sub.id,
                              '默认分组',
                            );
                          }
                          _reloadSavedConfig();
                          setSheetState(() {});
                        },
                      ),
                    );
                  }).toList(),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildLiveTab(BuildContext context, {required bool useSidebar}) {
    final lives = _visibleLives;
    final pad = useSidebar ? 28.0 : 16.0;
    if (lives.isEmpty) {
      return SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  CupertinoIcons.dot_radiowaves_left_right,
                  color: AppleColors.labelTertiary,
                  size: 48,
                ),
                const SizedBox(height: 12),
                const Text(
                  '当前配置未包含 M3U / TXT 直播源',
                  style: TextStyle(
                    color: AppleColors.labelPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  '可直接导入 M3U / TXT 直播订阅地址或包含 lives 节点的 JSON 配置。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppleColors.labelSecondary,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 18),
                AppleCapsuleButton(
                  label: '导入 M3U / 直播订阅',
                  icon: CupertinoIcons.add,
                  primary: true,
                  compact: true,
                  onPressed: () =>
                      _showImportConfigDialog(initialGroup: '电视直播'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final totalChannelCount = _liveGroups.fold<int>(
      0,
      (sum, g) => sum + g.channels.length,
    );
    final safeGroupIdx = _liveGroups.isEmpty
        ? -1
        : (_selectedLiveGroup >= _liveGroups.length ? 0 : _selectedLiveGroup);
    final queryLower = _liveSearchQuery.trim().toLowerCase();

    final visibleChannels = <LiveChannel>[];
    if (queryLower.isNotEmpty) {
      for (final g in _liveGroups) {
        for (final ch in g.channels) {
          if (ch.name.toLowerCase().contains(queryLower) ||
              ch.group.toLowerCase().contains(queryLower)) {
            visibleChannels.add(ch);
          }
        }
      }
    } else if (safeGroupIdx == -1) {
      for (final g in _liveGroups) {
        visibleChannels.addAll(g.channels);
      }
    } else if (safeGroupIdx >= 0 && safeGroupIdx < _liveGroups.length) {
      visibleChannels.addAll(_liveGroups[safeGroupIdx].channels);
    }

    return SafeArea(
      bottom: useSidebar,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          pad,
          useSidebar && _isMacOS ? 28 : 12,
          pad,
          0,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header Row: Title + Channel Count + Quick Channel Filter Search Box
            Row(
              children: [
                const Text(
                  '电视直播',
                  style: TextStyle(
                    color: AppleColors.labelPrimary,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.6,
                  ),
                ),
                if (totalChannelCount > 0) ...[
                  const SizedBox(width: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0x1FFFFFFF),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: const Color(0x28FFFFFF),
                        width: 0.5,
                      ),
                    ),
                    child: Text(
                      '$totalChannelCount 频道',
                      style: const TextStyle(
                        color: AppleColors.labelSecondary,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: useSidebar ? 260 : 185,
                  ),
                  child: SizedBox(
                    height: 36,
                    child: AppleSearchField(
                      controller: _liveSearchController,
                      placeholder: '搜索频道…',
                      onChanged: (v) => setState(() => _liveSearchQuery = v),
                      onSuffixTap: () {
                        _liveSearchController.clear();
                        setState(() => _liveSearchQuery = '');
                      },
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Row 1: Live Subscription Source Pills
            SizedBox(
              height: 34,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: lives.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (ctx, i) => _buildCategoryPill(
                  label: lives[i].name,
                  selected: i == _selectedLiveSource,
                  onTap: () => _loadLivePlaylist(i),
                ),
              ),
            ),

            // Row 2: Channel Group Pills (`全部` + each group)
            if (!_liveLoading && _liveError == null && _liveGroups.isNotEmpty) ...[
              const SizedBox(height: 9),
              SizedBox(
                height: 32,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _liveGroups.length + 1,
                  separatorBuilder: (_, __) => const SizedBox(width: 7),
                  itemBuilder: (ctx, idx) {
                    if (idx == 0) {
                      final isAllSelected =
                          queryLower.isEmpty && safeGroupIdx == -1;
                      return _buildCategoryPill(
                        label: '全部 ($totalChannelCount)',
                        selected: isAllSelected,
                        onTap: () => setState(() {
                          _selectedLiveGroup = -1;
                          if (_liveSearchQuery.isNotEmpty) {
                            _liveSearchController.clear();
                            _liveSearchQuery = '';
                          }
                        }),
                      );
                    }
                    final gIdx = idx - 1;
                    final g = _liveGroups[gIdx];
                    final isSelected =
                        queryLower.isEmpty && safeGroupIdx == gIdx;
                    return _buildCategoryPill(
                      label: '${g.name} (${g.channels.length})',
                      selected: isSelected,
                      onTap: () => setState(() {
                        _selectedLiveGroup = gIdx;
                        if (_liveSearchQuery.isNotEmpty) {
                          _liveSearchController.clear();
                          _liveSearchQuery = '';
                        }
                      }),
                    );
                  },
                ),
              ),
            ],
            const SizedBox(height: 12),

            // Main Multi-Column Channel Card Grid
            if (_liveLoading)
              const Expanded(
                child: Center(child: CupertinoActivityIndicator(radius: 14)),
              )
            else if (_liveError != null)
              Expanded(
                child: Center(
                  child: Text(
                    _liveError!,
                    style: const TextStyle(color: AppleColors.systemRed),
                  ),
                ),
              )
            else if (visibleChannels.isEmpty)
              const Expanded(
                child: Center(
                  child: Text(
                    '未找到匹配的直播频道',
                    style: TextStyle(
                      color: AppleColors.labelSecondary,
                      fontSize: 14,
                    ),
                  ),
                ),
              )
            else
              Expanded(
                child: LayoutBuilder(
                  builder: (ctx, constraints) {
                    final availW = constraints.maxWidth;
                    final int cols = availW >= 1240
                        ? 5
                        : availW >= 920
                            ? 4
                            : availW >= 580
                                ? 3
                                : 2;
                    final double aspect = cols == 2 ? 2.42 : 2.52;
                    return ShaderMask(
                      blendMode: BlendMode.dstIn,
                      shaderCallback: (rect) => const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color(0x00FFFFFF),
                          Color(0xD9FFFFFF),
                          Color(0xFFFFFFFF),
                        ],
                        stops: [0.0, 0.025, 0.055],
                      ).createShader(rect),
                      child: GridView.builder(
                        physics: const BouncingScrollPhysics(),
                        padding: EdgeInsets.only(
                          top: 4,
                          bottom: useSidebar ? 28 : 124,
                        ),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: cols,
                          mainAxisSpacing: 10,
                          crossAxisSpacing: 10,
                          childAspectRatio: aspect,
                        ),
                        itemCount: visibleChannels.length,
                        itemBuilder: (ctx, cIdx) {
                          final ch = visibleChannels[cIdx];
                          return _buildLiveChannelCard(
                            context,
                            channel: ch,
                            lives: lives,
                          );
                        },
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _openLiveChannelStream(
    List<LiveSource> lives,
    LiveChannel ch,
    int lineIdx,
  ) {
    if (lives.isEmpty || ch.urls.isEmpty) return;
    final safeIdx = _selectedLiveSource.clamp(0, lives.length - 1);
    final liveSite = lives[safeIdx].playbackSite;
    final liveVideo = CmsVideo(
      id: ch.name,
      title: ch.name,
      lines: [
        CmsLine(
          name: ch.group,
          episodes: ch.episodes,
        ),
      ],
    );
    Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => PlayerScreen(
          site: liveSite,
          video: liveVideo,
          initialLineIndex: 0,
          initialEpisodeIndex: lineIdx.clamp(0, ch.urls.length - 1),
          storage: widget.storage,
          isLive: true,
        ),
      ),
    );
  }

  void _showLiveChannelLinesSheet(
    List<LiveSource> lives,
    LiveChannel ch,
  ) {
    showAppleModalSheet<void>(
      context: context,
      title: '${ch.name} · 选择直播线路',
      maxWidth: 460,
      builder: (ctx) => ListView.separated(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 22),
        itemCount: ch.urls.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (ctx, idx) {
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              Navigator.of(ctx).pop();
              _openLiveChannelStream(lives, ch, idx);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: ShapeDecoration(
                color: const Color(0x22FFFFFF),
                shape: RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.circular(13),
                  side: const BorderSide(
                    color: Color(0x2EFFFFFF),
                    width: 0.6,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: AppleColors.systemGreen,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '线路 ${idx + 1}',
                      style: const TextStyle(
                        color: AppleColors.labelPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const Icon(
                    CupertinoIcons.play_fill,
                    color: AppleColors.labelSecondary,
                    size: 14,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildLiveChannelCard(
    BuildContext context, {
    required LiveChannel channel,
    required List<LiveSource> lives,
  }) {
    final upper = channel.name.toUpperCase();
    final String? qualityTag = upper.contains('8K')
        ? '8K'
        : upper.contains('4K') || upper.contains('UHD')
            ? '4K'
            : upper.contains('50FPS') || upper.contains('60FPS')
                ? '高帧'
                : upper.contains('FHD') || upper.contains('高清')
                    ? 'HD'
                    : null;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openLiveChannelStream(lives, channel, 0),
      onLongPress: channel.urls.length > 1
          ? () => _showLiveChannelLinesSheet(lives, channel)
          : null,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xEB222430),
              Color(0xEB171821),
            ],
          ),
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(
              color: Color(0x2BFFFFFF),
              width: 0.65,
            ),
          ),
          shadows: const [
            BoxShadow(
              color: Color(0x36000000),
              blurRadius: 10,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
          child: Row(
            children: [
              _buildLiveChannelBadge(channel),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            channel.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.2,
                            ),
                          ),
                        ),
                        if (qualityTag != null) ...[
                          const SizedBox(width: 5),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1.5,
                            ),
                            decoration: BoxDecoration(
                              color: qualityTag == '4K' || qualityTag == '8K'
                                  ? const Color(0x38F59E0B)
                                  : const Color(0x28FFFFFF),
                              borderRadius: BorderRadius.circular(5),
                              border: Border.all(
                                color: qualityTag == '4K' || qualityTag == '8K'
                                    ? const Color(0x80F59E0B)
                                    : const Color(0x36FFFFFF),
                                width: 0.5,
                              ),
                            ),
                            child: Text(
                              qualityTag,
                              style: TextStyle(
                                color: qualityTag == '4K' || qualityTag == '8K'
                                    ? const Color(0xFFFBBF24)
                                    : const Color(0xD9FFFFFF),
                                fontSize: 9.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: const BoxDecoration(
                            color: Color(0xFF34D399),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            channel.group,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppleColors.labelSecondary,
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        if (channel.urls.length > 1)
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () =>
                                _showLiveChannelLinesSheet(lives, channel),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0x26FFFFFF),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                '${channel.urls.length}源 ▾',
                                style: const TextStyle(
                                  color: Color(0xE6FFFFFF),
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          )
                        else
                          const Text(
                            '直连',
                            style: TextStyle(
                              color: AppleColors.labelTertiary,
                              fontSize: 10.5,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLiveChannelBadge(LiveChannel channel) {
    final name = channel.name.trim();
    final upper = name.toUpperCase();
    List<Color> gradientColors;
    String topLine = '';
    String mainText = '';

    final cctvMatch =
        RegExp(r'CCTV[-\s]*(\d+\+?|[A-Z0-9]+)', caseSensitive: false)
            .firstMatch(upper);
    if (cctvMatch != null) {
      gradientColors = const [Color(0xFFE11D48), Color(0xFF9F1239)];
      topLine = 'CCTV';
      mainText = cctvMatch.group(1)!;
    } else if (name.contains('卫视')) {
      gradientColors = const [Color(0xFFF59E0B), Color(0xFFB45309)];
      final prefix = name.replaceAll(RegExp(r'卫视.*$'), '').trim();
      mainText = prefix.length >= 2
          ? prefix.substring(0, 2)
          : (prefix.isNotEmpty ? prefix : '卫视');
      topLine = '卫视';
    } else if (RegExp(r'翡翠|明珠|凤凰|TVB|无线|莲花|澳视|香港|台湾|纬来|东森')
        .hasMatch(name)) {
      gradientColors = const [Color(0xFF10B981), Color(0xFF047857)];
      if (upper.contains('TVB') || name.contains('翡翠') || name.contains('明珠')) {
        topLine = 'TVB';
        mainText = name.contains('明珠') ? '明珠' : '翡翠';
      } else if (name.contains('凤凰')) {
        topLine = 'PHOENIX';
        mainText = '凤凰';
      } else {
        mainText = name.length >= 2 ? name.substring(0, 2) : name;
      }
    } else if (upper.contains('4K') || upper.contains('8K')) {
      gradientColors = const [Color(0xFF8B5CF6), Color(0xFF5B21B6)];
      topLine = 'UHD';
      mainText = upper.contains('8K') ? '8K' : '4K';
    } else if (RegExp(r'体育|足球|篮球|赛事|咪咕|CCTV5').hasMatch(name)) {
      gradientColors = const [Color(0xFF06B6D4), Color(0xFF0E7490)];
      topLine = 'SPORT';
      mainText = name.length >= 2 ? name.substring(0, 2) : '体育';
    } else {
      gradientColors = const [Color(0xFF3B82F6), Color(0xFF1D4ED8)];
      final cleaned = name.replaceAll(RegExp(r'[\[\(（【].*?[\]\)）】]'), '').trim();
      mainText = cleaned.length >= 2
          ? cleaned.substring(0, 2)
          : (cleaned.isNotEmpty ? cleaned : 'TV');
    }

    final fallbackBadge = Container(
      width: 42,
      height: 42,
      decoration: ShapeDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: gradientColors,
        ),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(11),
          side: const BorderSide(
            color: Color(0x36FFFFFF),
            width: 0.5,
          ),
        ),
      ),
      alignment: Alignment.center,
      child: topLine.isNotEmpty
          ? Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  topLine,
                  maxLines: 1,
                  style: const TextStyle(
                    color: Color(0xCCFFFFFF),
                    fontSize: 8.0,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.3,
                    height: 1.05,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  mainText,
                  maxLines: 1,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: mainText.length >= 3 ? 11.0 : 12.5,
                    fontWeight: FontWeight.w900,
                    height: 1.1,
                  ),
                ),
              ],
            )
          : Text(
              mainText,
              maxLines: 1,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w900,
              ),
            ),
    );

    if (channel.logo.isNotEmpty) {
      return SizedBox(
        width: 42,
        height: 42,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(11),
          child: DecoratedBox(
            decoration: const BoxDecoration(color: Color(0xFF1E202B)),
            child: PosterImage(
              url: channel.logo,
              fit: BoxFit.contain,
              fadeIn: false,
              placeholder: fallbackBadge,
            ),
          ),
        ),
      );
    }
    return fallbackBadge;
  }
  void _showWatchHistorySheet() {
    if (_privateSessionUnlocked) return;
    showAppleModalSheet<void>(
      context: context,
      title: '观看历史记录',
      maxWidth: 620,
      trailingAction: CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minSize: 28,
        onPressed: () async {
          await widget.storage.clearWatchHistory();
          if (mounted) setState(() {});
          if (context.mounted) Navigator.of(context).pop();
        },
        child: const Text(
          '清空全部',
          style: TextStyle(color: AppleColors.systemRed, fontSize: 13),
        ),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final history = widget.storage.getWatchHistory();
          if (history.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(40),
              child: Center(
                child: Text(
                  '暂无观看历史记录',
                  style: TextStyle(
                    color: AppleColors.labelSecondary,
                    fontSize: 14,
                  ),
                ),
              ),
            );
          }
          return ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: (MediaQuery.sizeOf(ctx).height * 0.72).clamp(320.0, 580.0),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(18, 10, 18, 4),
                  child: Text(
                    '提示：向左滑动单条记录可显示「删除」按钮',
                    style: TextStyle(
                      color: AppleColors.labelTertiary,
                      fontSize: 12,
                    ),
                  ),
                ),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                    itemCount: history.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (ctx, idx) {
                      final h = history[idx];
                      final resolvedPoster = _resolveHistoryPoster(h);
                      return _SwipeToDeleteHistoryTile(
                        key: ValueKey('sheet_hist_${h.site}_${h.id}'),
                        entry: h,
                        posterUrl: resolvedPoster,
                        onTap: () {
                          Navigator.of(ctx).pop();
                          if (_config == null) return;
                          final site = _config!.publicSupportedSites.firstWhere(
                            (s) => s.key == h.site,
                            orElse: () =>
                                _activeSite ??
                                CmsSite(
                                  key: h.site,
                                  name: h.site,
                                  type: 1,
                                  api: '',
                                ),
                          );
                          _openVideoDetail(
                            site,
                            CmsVideo(
                              id: h.id,
                              title: h.title,
                              poster: resolvedPoster,
                            ),
                          );
                        },
                        onDelete: () async {
                          await widget.storage.removeWatchHistoryItem(
                            h.site,
                            h.id,
                          );
                          setSheetState(() {});
                          if (mounted) setState(() {});
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildFavoritesHistoryTab(
    BuildContext context, {
    required bool useSidebar,
  }) {
    final favorites =
        widget.storage.getFavorites(forPrivate: _privateSessionUnlocked);
    final history = _privateSessionUnlocked
        ? const <WatchHistoryEntry>[]
        : widget.storage.getWatchHistory();
    final pad = useSidebar ? 28.0 : 16.0;
    return SafeArea(
      bottom: useSidebar,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          pad,
          useSidebar && _isMacOS ? 28 : 14,
          pad,
          0,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  _privateSessionUnlocked ? '隐私片库' : '我的片库',
                  style: const TextStyle(
                    color: AppleColors.labelPrimary,
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.6,
                  ),
                ),
                const Spacer(),
                if (_librarySegment == 2 &&
                    DownloadService.instance.canOpenFolder &&
                    DownloadService.instance.rootPath.isNotEmpty)
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    minSize: 28,
                    onPressed: DownloadService.instance.openFolder,
                    child: const Text(
                      '打开文件夹',
                      style: TextStyle(
                        color: AppleColors.systemBlue,
                        fontSize: 13,
                      ),
                    ),
                  ),
                if (_librarySegment == 1 &&
                    !_privateSessionUnlocked &&
                    history.isNotEmpty)
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    minSize: 28,
                    onPressed: () async {
                      await widget.storage.clearWatchHistory();
                      setState(() {});
                    },
                    child: const Text(
                      '清空记录',
                      style: TextStyle(
                        color: AppleColors.systemRed,
                        fontSize: 13,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: CupertinoSlidingSegmentedControl<int>(
                backgroundColor: AppleColors.fill,
                thumbColor: const Color(0xFF636366),
                groupValue: _librarySegment,
                children: const {
                  0: Padding(
                    padding: EdgeInsets.symmetric(vertical: 7),
                    child: Text(
                      '收藏片单',
                      style: TextStyle(
                        color: AppleColors.labelPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  1: Padding(
                    padding: EdgeInsets.symmetric(vertical: 7),
                    child: Text(
                      '观看历史',
                      style: TextStyle(
                        color: AppleColors.labelPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  2: Padding(
                    padding: EdgeInsets.symmetric(vertical: 7),
                    child: Text(
                      '离线下载',
                      style: TextStyle(
                        color: AppleColors.labelPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                },
                onValueChanged: (v) {
                  if (v != null) setState(() => _librarySegment = v);
                },
              ),
            ),
            const SizedBox(height: 16),
            if (_librarySegment == 2)
              Expanded(child: _buildDownloadsList(useSidebar: useSidebar))
            else
            Expanded(
              child: _librarySegment == 0
                  ? (favorites.isEmpty
                      ? Center(
                          child: Text(
                            _privateSessionUnlocked
                                ? '隐私片库还没有收藏任何影片'
                                : '还没有收藏任何影片',
                            style: const TextStyle(
                              color: AppleColors.labelSecondary,
                              fontSize: 14,
                            ),
                          ),
                        )
                      : GridView.builder(
                          padding: EdgeInsets.only(
                            bottom: useSidebar ? 24 : 124,
                          ),
                          gridDelegate:
                              SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: useSidebar ? 176 : 132,
                            mainAxisSpacing: 16,
                            crossAxisSpacing: 12,
                            childAspectRatio: 0.56,
                          ),
                          itemCount: favorites.length,
                          itemBuilder: (ctx, i) {
                            final fav = favorites[i];
                            final sitePool = _visibleSupportedSites;
                            final site = sitePool.firstWhere(
                              (s) => s.key == fav.site,
                              orElse: () =>
                                  _activeSite ??
                                  CmsSite(
                                    key: fav.site,
                                    name: fav.site,
                                    type: 1,
                                    api: '',
                                    isPrivate: _privateSessionUnlocked,
                                  ),
                            );
                            return _buildVideoCard(
                              site,
                              CmsVideo(
                                id: fav.id,
                                title: fav.title,
                                poster: fav.poster,
                                remarks: fav.remarks,
                              ),
                            );
                          },
                        ))
                  : (_privateSessionUnlocked
                      ? const Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                CupertinoIcons.eye_slash_fill,
                                color: Color(0xFFA78BFA),
                                size: 42,
                              ),
                              SizedBox(height: 12),
                              Text(
                                '隐私模式不保留任何观看历史记录',
                                style: TextStyle(
                                  color: AppleColors.labelPrimary,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              SizedBox(height: 6),
                              Text(
                                '隐私分组中的播放进度、搜索与收藏均与正常模式完全隔离',
                                style: TextStyle(
                                  color: AppleColors.labelSecondary,
                                  fontSize: 12.5,
                                ),
                              ),
                            ],
                          ),
                        )
                      : (history.isEmpty
                          ? const Center(
                              child: Text(
                                '暂无观看历史',
                                style: TextStyle(
                                  color: AppleColors.labelSecondary,
                                  fontSize: 14,
                                ),
                              ),
                            )
                          : ListView.separated(
                              padding: EdgeInsets.only(
                                bottom: useSidebar ? 24 : 124,
                              ),
                              itemCount: history.length + 1,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (ctx, idx) {
                                if (idx == 0) {
                                  return const Padding(
                                    padding: EdgeInsets.only(
                                      left: 4,
                                      bottom: 2,
                                    ),
                                    child: Text(
                                      '提示：向左滑动单条记录可显示「删除」按钮',
                                      style: TextStyle(
                                        color: AppleColors.labelTertiary,
                                        fontSize: 12,
                                      ),
                                    ),
                                  );
                                }
                                final h = history[idx - 1];
                                final resolvedPoster = _resolveHistoryPoster(h);
                                return _SwipeToDeleteHistoryTile(
                                  key: ValueKey('lib_hist_${h.site}_${h.id}'),
                                  entry: h,
                                  posterUrl: resolvedPoster,
                                  onTap: () {
                                    if (_config == null) return;
                                    final site =
                                        _config!.publicSupportedSites.firstWhere(
                                      (s) => s.key == h.site,
                                      orElse: () => _activeSite!,
                                    );
                                    _openVideoDetail(
                                      site,
                                      CmsVideo(
                                        id: h.id,
                                        title: h.title,
                                        poster: resolvedPoster,
                                      ),
                                    );
                                  },
                                  onDelete: () async {
                                    await widget.storage.removeWatchHistoryItem(
                                      h.site,
                                      h.id,
                                    );
                                    if (mounted) setState(() {});
                                  },
                                );
                              },
                            ))),
            ),
          ],
        ),
      ),
    );
  }
  Widget _buildDownloadsList({required bool useSidebar}) {
    final service = DownloadService.instance;
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) {
        if (!service.isReady) {
          return const Center(
            child: Text(
              '当前设备暂不支持离线下载',
              style: TextStyle(color: AppleColors.labelSecondary, fontSize: 14),
            ),
          );
        }
        final tasks = service.tasks;
        if (tasks.isEmpty) {
          return const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  CupertinoIcons.arrow_down_circle,
                  color: AppleColors.labelTertiary,
                  size: 46,
                ),
                SizedBox(height: 12),
                Text(
                  '还没有下载任何影片',
                  style: TextStyle(
                    color: AppleColors.labelPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  '在影片详情页点击「下载」，即可在没有网络时观看',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppleColors.labelSecondary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          );
        }
        final active = service.activeCount;
        final hasPaused = tasks.any((t) => t.status == DownloadStatus.paused);
        return ListView(
          padding: EdgeInsets.only(bottom: useSidebar ? 24 : 124),
          children: [
            if (active > 0 || hasPaused)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
                child: Row(
                  children: [
                    Text(
                      active > 0 ? '$active 个任务进行中' : '下载已暂停',
                      style: const TextStyle(
                        color: AppleColors.labelSecondary,
                        fontSize: 13,
                      ),
                    ),
                    const Spacer(),
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      minSize: 26,
                      onPressed:
                          active > 0 ? service.pauseAll : service.resumeAll,
                      child: Text(
                        active > 0 ? '全部暂停' : '全部继续',
                        style: const TextStyle(
                          color: AppleColors.systemBlue,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            AppleGroupedSection(
              children: [for (final t in tasks) _buildDownloadRow(t)],
            ),
            if (service.rootPath.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Text(
                  '保存位置：${service.rootPath}',
                  style: const TextStyle(
                    color: AppleColors.labelTertiary,
                    fontSize: 11,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
  Widget _buildDownloadRow(DownloadTask t) {
    final service = DownloadService.instance;
    final done = t.status == DownloadStatus.completed;
    final failed = t.status == DownloadStatus.failed;
    final statusColor = failed
        ? AppleColors.systemRed
        : (done ? AppleColors.systemGreen : AppleColors.labelSecondary);
    IconData actionIcon;
    VoidCallback action;
    if (done) {
      actionIcon = CupertinoIcons.play_circle_fill;
      action = () => _playDownloaded(t);
    } else if (t.status == DownloadStatus.paused || failed) {
      actionIcon = CupertinoIcons.arrow_clockwise_circle;
      action = () => service.resume(t.id);
    } else {
      actionIcon = CupertinoIcons.pause_circle;
      action = () => service.pause(t.id);
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: done ? () => _playDownloaded(t) : null,
        highlightColor: Colors.white10,
        splashColor: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(7),
                child: SizedBox(
                  width: 40,
                  height: 56,
                  child: PosterImage(
                    url: t.poster,
                    title: t.title,
                    placeholder: _buildPosterPlaceholder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppleColors.labelPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${t.episodeName} · ${t.lineName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppleColors.labelSecondary,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 6),
                    if (!done) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: t.status == DownloadStatus.queued &&
                                  t.progress <= 0
                              ? null
                              : t.progress.clamp(0.0, 1.0),
                          minHeight: 3,
                          backgroundColor: AppleColors.fill,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            failed
                                ? AppleColors.systemRed
                                : AppleColors.systemBlue,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                    ],
                    Text(
                      DownloadService.statusLabel(t),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: statusColor, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              CupertinoButton(
                padding: const EdgeInsets.all(4),
                minSize: 34,
                onPressed: action,
                child: Icon(
                  actionIcon,
                  size: 27,
                  color: done
                      ? AppleColors.labelPrimary
                      : AppleColors.systemBlue,
                ),
              ),
              CupertinoButton(
                padding: const EdgeInsets.all(4),
                minSize: 34,
                onPressed: () => _confirmDeleteDownload(t),
                child: const Icon(
                  CupertinoIcons.trash,
                  size: 19,
                  color: AppleColors.labelTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
  void _confirmDeleteDownload(DownloadTask t) {
    showCupertinoDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('删除下载？'),
        content: Text('「${t.title} · ${t.episodeName}」及已下载的文件将被删除。'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () {
              Navigator.of(ctx).pop();
              DownloadService.instance.remove(t.id);
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }
  void _playDownloaded(DownloadTask t) {
    final completed = DownloadService.instance
        .completedFor(t.siteKey, t.videoId)
        .where((x) => x.lineName == t.lineName && x.filePath.isNotEmpty)
        .toList();
    if (completed.isEmpty) return;
    final start = completed.indexWhere((x) => x.id == t.id);
    final site = CmsSite(
      key: t.siteKey,
      name: t.siteName,
      type: t.siteType,
      api: t.siteApi,
    );
    final video = CmsVideo(
      id: t.videoId,
      title: t.title,
      poster: t.poster,
      lines: [
        CmsLine(
          name: t.lineName,
          episodes: [
            for (final x in completed)
              CmsEpisode(name: x.episodeName, url: x.filePath),
          ],
        ),
      ],
    );
    Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => PlayerScreen(
          site: site,
          video: video,
          initialLineIndex: 0,
          initialEpisodeIndex: start < 0 ? 0 : start,
          storage: widget.storage,
        ),
      ),
    );
  }
  String get _wallpaperPresetLabel => switch (widget.storage.wallpaperPreset) {
        'midnight' => '午夜深蓝',
        'aurora' => '极光紫韵',
        'amber' => '流金琥珀',
        'emerald' => '翡翠幽林',
        'custom' => '自定义壁纸',
        _ => '曜石纯黑',
      };

  String get _glassBlurLabel => switch (widget.storage.glassBlurLevel) {
        'light' => '轻盈通透',
        'deep' => '深邃毛玻璃',
        'solid' => '减少透明度',
        _ => '标准液态',
      };

  String get _gridDensityLabel => switch (widget.storage.gridDensity) {
        'comfortable' => '舒展大卡',
        'compact' => '紧凑多列',
        _ => '标准均衡',
      };

  String get _cardSubtitleModeLabel => switch (widget.storage.cardSubtitleMode) {
        'year_area' => '年份与地区',
        'site' => '所属片源名称',
        'none' => '极简隐藏',
        _ => '更新集数与备注',
      };

  String get _preferredQualityLabel => switch (widget.storage.preferredQuality) {
        '4k_netdisk' => '4K 超清原画优先',
        '1080p_direct' => '1080P 高清直连优先',
        'fast_hls' => '极速 M3U8 流媒体优先',
        _ => '站点默认顺序',
      };

  String get _defaultAspectLabel => switch (widget.storage.defaultAspectMode) {
        'cover' => '铺满裁剪',
        'fill' => '拉伸全屏',
        _ => '适应屏幕',
      };

  String get _skipIntroOutroSummary {
    final skipIntro = widget.storage.skipIntroSec;
    final skipOutro = widget.storage.skipOutroSec;
    return (skipIntro == 0 && skipOutro == 0)
        ? '未开启'
        : '片头 ${skipIntro}s · 片尾 ${skipOutro}s';
  }

  Widget _buildSettingsQuickActionRow({
    required IconData icon,
    required Color iconBgColor,
    required String title,
    String? subtitle,
    String? trailingText,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    final rowContent = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 58),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: [
            DecoratedBox(
              decoration: ShapeDecoration(
                color: iconBgColor,
                shape: ContinuousRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                shadows: [
                  BoxShadow(
                    color: iconBgColor.withValues(alpha: 0.28),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: SizedBox(
                width: 30,
                height: 30,
                child: Icon(icon, size: 17, color: Colors.white),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppleColors.labelPrimary,
                      fontSize: 15.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.1,
                      height: 1.28,
                    ),
                  ),
                  if (subtitle != null && subtitle.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppleColors.labelSecondary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w400,
                        letterSpacing: 0.1,
                        height: 1.35,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            if (trailing != null)
              trailing
            else ...[
              if (trailingText != null && trailingText.isNotEmpty)
                Flexible(
                  flex: 0,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 168),
                    child: Text(
                      trailingText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        color: AppleColors.labelSecondary,
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                        letterSpacing: 0.1,
                      ),
                    ),
                  ),
                ),
              if (onTap != null) ...[
                const SizedBox(width: 6),
                Icon(
                  CupertinoIcons.chevron_forward,
                  size: 15,
                  color: Colors.white.withValues(alpha: 0.30),
                ),
              ],
            ],
          ],
        ),
      ),
    );
    if (onTap == null) return rowContent;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        highlightColor: Colors.white.withValues(alpha: 0.08),
        splashColor: Colors.white.withValues(alpha: 0.04),
        child: rowContent,
      ),
    );
  }

  /// Main Settings Tab (Level 1): Authentic iOS System Settings inset-grouped layout
  /// with vivid squircle badges, inline linear Liquid Glass refraction slider, and
  /// clean category navigation rows.
  Widget _buildSettingsTab(BuildContext context, {required bool useSidebar}) {
    final pad = useSidebar ? 28.0 : 16.0;
    final publicSites = _config?.publicSupportedSites ?? const [];
    return SafeArea(
      bottom: useSidebar,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              pad,
              useSidebar && _isMacOS ? 28 : 16,
              pad,
              useSidebar ? 36 : 28,
            ),
            children: [
              const Padding(
                padding: EdgeInsets.only(left: 4, bottom: 16),
                child: Text(
                  '设置',
                  style: TextStyle(
                    color: AppleColors.labelPrimary,
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
              AppleGroupedSection(
                header: '核心偏好设置',
                children: [
                  AppleGroupedTile(
                    minHeight: 88,
                    icon: CupertinoIcons.paintbrush_fill,
                    iconBgColor: AppleColors.systemPurple,
                    title: '外观与视觉风格',
                    subtitle: '自定义影院主题配色、高清壁纸与毛玻璃档位',
                    trailingText: _wallpaperPresetLabel,
                    onTap: () => _openSettingsSubPage(
                      title: '外观与视觉风格',
                      subtitle: '自定义影院主题配色、动态流光背景与毛玻璃通透效果',
                      sectionBuilder: _buildAppearanceSettingsSection,
                    ),
                  ),
                  AppleGroupedTile(
                    minHeight: 88,
                    icon: CupertinoIcons.square_grid_2x2_fill,
                    iconBgColor: AppleColors.systemBlue,
                    title: '首页与排版布局',
                    subtitle: '设置海报列数密度、卡片副标题与首页推荐模块',
                    trailingText: _gridDensityLabel,
                    onTap: () => _openSettingsSubPage(
                      title: '首页与排版布局',
                      subtitle: '调整首页展示模块开关、海报列数密度与卡片副标题样式',
                      sectionBuilder: _buildLayoutSettingsSection,
                    ),
                  ),
                  AppleGroupedTile(
                    minHeight: 88,
                    icon: CupertinoIcons.play_rectangle_fill,
                    iconBgColor: AppleColors.systemOrange,
                    title: '播放与画质偏好',
                    subtitle: '设置默认优选画质、起播倍速与片头片尾自动跳过',
                    trailingText: _preferredQualityLabel,
                    onTap: () => _openSettingsSubPage(
                      title: '播放与画质偏好',
                      subtitle: '进入影视详情页与播放器时自动按首选画质、倍速与片头片尾规则起播',
                      sectionBuilder: _buildPlaybackSettingsSection,
                    ),
                  ),
                  AppleGroupedTile(
                    minHeight: 88,
                    icon: CupertinoIcons.folder_fill,
                    iconBgColor: AppleColors.systemGreen,
                    title: '订阅与数据维护',
                    subtitle: '网盘扫码登录、点播直播订阅源管理与缓存清理',
                    trailingText: '${publicSites.length} 可用',
                    onTap: () => _openSettingsSubPage(
                      title: '订阅与数据维护',
                      subtitle: '集中管理云盘扫码授权、点播与直播订阅源、多仓切换及跨端数据备份',
                      sectionBuilder: _buildCloudAndDataSettingsSection,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              AppleGroupedSection(
                header: '云盘与快捷工具',
                footer: '拖动滑块可实时调节全局界面毛玻璃通透度。',
                children: [
                  Builder(
                    builder: (context) {
                      final loggedCount = NetdiskService.drives
                          .where((d) => widget.storage.isNetdiskLoggedIn(d.key))
                          .length;
                      return _buildSettingsQuickActionRow(
                        icon: CupertinoIcons.qrcode_viewfinder,
                        iconBgColor: const Color(0xFF0A84FF),
                        title: '我的云盘 · 网盘扫码与账号中心',
                        subtitle: '夸克（我的夸父）/ UC（我的优汐）/ 百度（我的嘟嘟）/ 阿里（我的阿狸）',
                        trailingText:
                            loggedCount > 0 ? '已登录 $loggedCount 个' : '去扫码',
                        onTap: () => showNetdiskAccountSheet(
                          context,
                          widget.storage,
                          onChanged: () {
                            if (mounted) setState(() {});
                          },
                        ),
                      );
                    },
                  ),
                  _buildSettingsQuickActionRow(
                    icon: CupertinoIcons.sparkles,
                    iconBgColor: AppleColors.systemIndigo,
                    title: '动态流光背景',
                    subtitle: '开启柔和极光背景与海报环境光晕',
                    trailing: CupertinoSwitch(
                      value: widget.storage.ambientGlowEnabled,
                      activeTrackColor: AppleColors.systemGreen,
                      onChanged: (v) async {
                        await widget.storage.setAmbientGlowEnabled(v);
                        if (mounted) setState(() {});
                      },
                    ),
                  ),
                  _buildLiquidGlassSliderRow(() {
                    if (mounted) setState(() {});
                  }),
                  _buildSettingsQuickActionRow(
                    icon: CupertinoIcons.cloud_upload_fill,
                    iconBgColor: AppleColors.systemTeal,
                    title: '跨平台备份与恢复',
                    subtitle: '导出或恢复全平台通用 JSON 备份配置',
                    trailingText: 'JSON 互通',
                    onTap: _showBackupRestoreDialog,
                  ),
                  _buildSettingsQuickActionRow(
                    icon: CupertinoIcons.arrow_down_circle_fill,
                    iconBgColor: AppleColors.systemBlue,
                    title: '软件更新与版本',
                    subtitle: '检查最新版本更新与发行说明',
                    trailingText: 'v$_currentAppVersion',
                    onTap: _showUpdateCheckSheet,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLiquidGlassSliderRow(VoidCallback refreshBoth) {
    return RepaintBoundary(
      child: ValueListenableBuilder<double>(
        valueListenable: GlassworkBackdrop.intensity,
        builder: (context, rawStrength, _) {
          final strength = rawStrength.clamp(0.0, 1.0);
          final pct = (strength * 100).round();
          final levelLabel = strength < 0.05
              ? '关闭'
              : strength < 0.48
                  ? '轻柔'
                  : strength < 0.80
                      ? '标准'
                      : '深邃';
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 11, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    DecoratedBox(
                      decoration: ShapeDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color.alphaBlend(
                              const Color(0x28FFFFFF),
                              AppleColors.systemTeal,
                            ),
                            AppleColors.systemTeal,
                          ],
                        ),
                        shape: RoundedSuperellipseBorder(
                          borderRadius: BorderRadius.circular(7.5),
                          side: const BorderSide(
                            color: Color(0x33FFFFFF),
                            width: 0.5,
                          ),
                        ),
                      ),
                      child: const SizedBox(
                        width: 30,
                        height: 30,
                        child: Icon(
                          CupertinoIcons.drop_fill,
                          color: Colors.white,
                          size: 17,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        '毛玻璃通透度',
                        style: TextStyle(
                          color: AppleColors.labelPrimary,
                          fontSize: 15.5,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.1,
                        ),
                      ),
                    ),
                    Text(
                      '$pct% · $levelLabel',
                      style: const TextStyle(
                        color: AppleColors.labelSecondary,
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                        letterSpacing: 0.1,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    const Icon(
                      CupertinoIcons.drop,
                      size: 15,
                      color: AppleColors.labelSecondary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: CupertinoSlider(
                        key: const ValueKey('settings-liquid-glass-slider'),
                        value: strength,
                        min: 0.0,
                        max: 1.0,
                        activeColor: AppleColors.systemBlue,
                        onChanged: (v) {
                          GlassworkBackdrop.intensity.value = v;
                          GlassworkBackdrop.reduceTransparency.value =
                              v <= 0.02;
                        },
                        onChangeEnd: (v) async {
                          await widget.storage.setGlassBlurStrength(v);
                          refreshBoth();
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Icon(
                      CupertinoIcons.drop_fill,
                      size: 18,
                      color: AppleColors.systemBlue,
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildBreathingSettingCard({
    required Widget child,
    double bottomSpacing = 0,
  }) {
    return Padding(
      padding: EdgeInsets.only(bottom: bottomSpacing),
      child: AppleSettingsGlassCard(
        borderRadius: BorderRadius.circular(16),
        child: child,
      ),
    );
  }

  void _openSettingsSubPage({
    required String title,
    required String subtitle,
    required Widget Function(BuildContext context, VoidCallback refreshSubPage)
        sectionBuilder,
  }) {
    Navigator.of(context)
        .push(
          CupertinoPageRoute<void>(
            builder: (routeCtx) => StatefulBuilder(
              builder: (subCtx, setSubState) {
                void refreshBoth() {
                  if (subCtx.mounted) setSubState(() {});
                }

                final topPad = MediaQuery.paddingOf(subCtx).top;
                final width = MediaQuery.sizeOf(subCtx).width;
                final hPad = width >= 720 ? 32.0 : 16.0;
                return Scaffold(
                  backgroundColor: AppleColors.background,
                  body: Stack(
                    fit: StackFit.expand,
                    children: [
                      AppleAmbientBackground(
                        preset: widget.storage.wallpaperPreset,
                        showAmbientArtwork: widget.storage.ambientGlowEnabled,
                        blurSigma: 60,
                        animate: false,
                      ),
                      SafeArea(
                        child: RepaintBoundary(
                          child: Align(
                            alignment: Alignment.topCenter,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 860),
                              child: ListView(
                                physics: const BouncingScrollPhysics(),
                                padding: EdgeInsets.fromLTRB(hPad, 58, hPad, 48),
                                children: [
                                  Text(
                                    title,
                                    style: const TextStyle(
                                      color: AppleColors.labelPrimary,
                                      fontSize: 25,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.2,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    subtitle,
                                    style: const TextStyle(
                                      color: AppleColors.labelSecondary,
                                      fontSize: 13,
                                      height: 1.45,
                                      letterSpacing: 0.1,
                                    ),
                                  ),
                                  const SizedBox(height: 20),
                                  sectionBuilder(subCtx, refreshBoth),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        top: topPad + 8,
                        left: hPad,
                        child: GestureDetector(
                          onTap: () => Navigator.of(subCtx).maybePop(),
                          child: AppleSettingsGlassCard(
                            borderRadius: BorderRadius.circular(999),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 13,
                              vertical: 8,
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  CupertinoIcons.chevron_back,
                                  color: AppleColors.systemBlue,
                                  size: 17,
                                ),
                                SizedBox(width: 3),
                                Text(
                                  '设置',
                                  style: TextStyle(
                                    color: AppleColors.systemBlue,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        )
        .then((_) {
          if (mounted) setState(() {});
        });
  }

  Widget _buildAppearanceSettingsSection(
    BuildContext context,
    VoidCallback refreshBoth,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppleGroupedSection(
          header: '壁纸与动态流光氛围',
          footer: '开启呼吸式动态流光后，背景极光色块将以约 8 秒周期柔和呼吸律动，并透过液态玻璃产生实时折射。',
          children: [
            _buildSettingDrawerContainer(
              settingKey: 'wallpaper_preset',
              icon: CupertinoIcons.photo_fill_on_rectangle_fill,
              iconBgColor: AppleColors.systemPurple,
              title: '背景壁纸与主题风格',
              subtitle: widget.storage.customWallpaperUrl.isNotEmpty
                  ? '已启用自定义高清壁纸'
                  : '选择暗黑影院主题底色或自定义壁纸',
              trailingText: _wallpaperPresetLabel,
              onStateChanged: refreshBoth,
              drawerChild: _buildWallpaperDrawerBody(onStateChanged: refreshBoth),
            ),
            AppleGroupedTile(
              icon: CupertinoIcons.sparkles,
              iconBgColor: AppleColors.systemIndigo,
              title: '呼吸式流光氛围背景',
              subtitle: '渲染动态呼吸流光与海报主色调光晕',
              trailing: CupertinoSwitch(
                value: widget.storage.ambientGlowEnabled,
                activeTrackColor: AppleColors.systemGreen,
                onChanged: (v) async {
                  await widget.storage.setAmbientGlowEnabled(v);
                  refreshBoth();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),
        AppleGroupedSection(
          header: '毛玻璃与通透度',
          footer: '支持 0%–100% 连续调节，也可点击下方预设档位快速切换。',
          children: [
            _buildLiquidGlassSliderRow(refreshBoth),
            _buildExpandableChoiceDrawerTile<String>(
              settingKey: 'glass_blur',
              icon: CupertinoIcons.drop_fill,
              iconBgColor: AppleColors.systemBlue,
              title: '毛玻璃效果档位',
              subtitle: '快速切换四档磨砂与通透配置',
              trailingText: _glassBlurLabel,
              currentValue: widget.storage.glassBlurLevel,
              onStateChanged: refreshBoth,
              options: const [
                ('light', '轻盈通透 (35%)', '轻量高斯模糊，保留更多背景色彩细节'),
                ('standard', '标准液态 (68%)', '细腻边缘高光与背景折射'),
                ('deep', '深邃毛玻璃 (100%)', '高浓度深邃磨砂，强化前景文字对比'),
                ('solid', '减少透明度 (0%)', '使用实色面板，提升阅读清晰度'),
              ],
              onSelected: (val) async {
                await widget.storage.setGlassBlurLevel(val);
                GlassworkBackdrop.reduceTransparency.value = val == 'solid';
                GlassworkBackdrop.intensity.value =
                    widget.storage.glassBlurStrength;
                refreshBoth();
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildLayoutSettingsSection(
    BuildContext context,
    VoidCallback refreshBoth,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppleGroupedSection(
          header: '海报网格与卡片信息',
          children: [
            _buildExpandableChoiceDrawerTile<String>(
              settingKey: 'grid_density',
              icon: CupertinoIcons.square_grid_3x2_fill,
              iconBgColor: AppleColors.systemBlue,
              title: '海报网格排版密度',
              subtitle: '选择舒展大卡、标准均衡或紧凑多列',
              trailingText: _gridDensityLabel,
              currentValue: widget.storage.gridDensity,
              onStateChanged: refreshBoth,
              options: const [
                ('comfortable', '舒展大卡', '减少单行卡片列数，放大海报尺寸与视觉呼吸感'),
                ('standard', '标准均衡', '默认黄金比例网格密度，兼顾浏览视野与效率'),
                ('compact', '紧凑多列', '同屏展示更多海报卡片，适合快速浏览检索'),
              ],
              onSelected: (val) async {
                await widget.storage.setGridDensity(val);
                refreshBoth();
              },
            ),
            _buildExpandableChoiceDrawerTile<String>(
              settingKey: 'card_subtitle',
              icon: CupertinoIcons.text_badge_checkmark,
              iconBgColor: AppleColors.systemIndigo,
              title: '影视卡片副标题展示',
              subtitle: '选择海报下方展示的辅助信息类型',
              trailingText: _cardSubtitleModeLabel,
              currentValue: widget.storage.cardSubtitleMode,
              onStateChanged: refreshBoth,
              options: const [
                ('remarks', '更新集数与备注', '展示「更新至第X集 / 4K / HD中字」等状态信息'),
                ('year_area', '年份与地区', '展示「2026 · 中国大陆」等发行年份与地区'),
                ('site', '所属片源名称', '展示当前影片所属的订阅源站点名称'),
                ('none', '极简隐藏', '仅展示影片标题，隐藏下方副标题行'),
              ],
              onSelected: (val) async {
                await widget.storage.setCardSubtitleMode(val);
                refreshBoth();
              },
            ),
          ],
        ),
        const SizedBox(height: 22),
        AppleGroupedSection(
          header: '首页焦点模块',
          children: [
            AppleGroupedTile(
              icon: CupertinoIcons.rectangle_on_rectangle_angled,
              iconBgColor: AppleColors.systemOrange,
              title: '首页「今日首推」巨幕卡片',
              subtitle: '在首页推荐顶部展示焦点海报横幅',
              trailing: CupertinoSwitch(
                value: widget.storage.showHeroBanner,
                activeTrackColor: AppleColors.systemGreen,
                onChanged: (v) async {
                  await widget.storage.setShowHeroBanner(v);
                  refreshBoth();
                },
              ),
            ),
            AppleGroupedTile(
              icon: CupertinoIcons.play_rectangle_fill,
              iconBgColor: AppleColors.systemGreen,
              title: '首页「历史记录」快捷栏',
              subtitle: '在首页顶部显示最近观看进度以便一键续播',
              trailing: CupertinoSwitch(
                value: widget.storage.showContinueWatching,
                activeTrackColor: AppleColors.systemGreen,
                onChanged: (v) async {
                  await widget.storage.setShowContinueWatching(v);
                  refreshBoth();
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPlaybackSettingsSection(
    BuildContext context,
    VoidCallback refreshBoth,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppleGroupedSection(
          header: '画质与画面比例',
          children: [
            _buildExpandableChoiceDrawerTile<String>(
              settingKey: 'preferred_quality',
              icon: CupertinoIcons.tv_music_note_fill,
              iconBgColor: AppleColors.systemBlue,
              title: '默认画质与线路推荐',
              subtitle: '进入详情页时自动优选匹配的画质与线路',
              trailingText: _preferredQualityLabel,
              currentValue: widget.storage.preferredQuality,
              onStateChanged: refreshBoth,
              options: const [
                ('4k_netdisk', '4K 超清原画优先', '优先匹配 4K HDR / 杜比视界超清线路'),
                ('1080p_direct', '1080P 高清直连优先', '优先选择高码率 1080P 直连点播线路'),
                ('fast_hls', '极速 M3U8 流媒体优先', '优先选择秒开 M3U8 切片流媒体线路'),
                ('default', '站点默认顺序', '保持采集站原始线路排序'),
              ],
              onSelected: (val) async {
                await widget.storage.setPreferredQuality(val);
                refreshBoth();
              },
            ),
            _buildExpandableChoiceDrawerTile<String>(
              settingKey: 'player_kernel',
              icon: CupertinoIcons.slider_horizontal_3,
              iconBgColor: AppleColors.systemTeal,
              title: '默认播放策略',
              subtitle: '调整同一播放器的硬件解码偏好与缓冲大小',
              trailingText: switch (widget.storage.playerKernel) {
                'ijk' => '兼容缓冲',
                'mpv' => '大容量缓冲',
                _ => '均衡播放',
              },
              currentValue: widget.storage.playerKernel,
              onStateChanged: refreshBoth,
              options: const [
                ('exo', '均衡播放（默认）', '自动选择解码方式，使用 64 MB 前向缓冲'),
                ('ijk', '兼容缓冲', '硬件解码拷贝输出，增加媒体探测时间'),
                ('mpv', '大容量缓冲', '使用 128 MB 前向缓冲，占用更多内存'),
              ],
              onSelected: (val) async {
                await widget.storage.setPlayerKernel(val);
                refreshBoth();
              },
            ),
            _buildExpandableChoiceDrawerTile<String>(
              settingKey: 'aspect_mode',
              icon: CupertinoIcons.viewfinder,
              iconBgColor: AppleColors.systemPurple,
              title: '默认画面比例',
              subtitle: '播放器启动时的默认画面缩放模式',
              trailingText: _defaultAspectLabel,
              currentValue: widget.storage.defaultAspectMode,
              onStateChanged: refreshBoth,
              options: const [
                ('contain', '适应屏幕', '保持原始视频宽高比完整显示画面'),
                ('cover', '铺满裁剪', '等比放大铺满全屏区域，自动裁切黑边'),
                ('fill', '拉伸全屏', '拉伸画面填满整个屏幕显示区域'),
              ],
              onSelected: (val) async {
                await widget.storage.setDefaultAspectMode(val);
                refreshBoth();
              },
            ),
          ],
        ),
        const SizedBox(height: 22),
        AppleGroupedSection(
          header: '起播规则与选集',
          children: [
            _buildExpandableChoiceDrawerTile<double>(
              settingKey: 'play_speed',
              icon: CupertinoIcons.speedometer,
              iconBgColor: AppleColors.systemOrange,
              title: '默认起播倍速',
              subtitle: '选择播放器起播时的默认倍速',
              trailingText: '${widget.storage.playSpeed}x',
              currentValue: widget.storage.playSpeed,
              onStateChanged: refreshBoth,
              options: const [
                (0.75, '0.75x 慢速', '放慢语速与动作细节'),
                (1.0, '1.0x 正常原速', '标准原片播放速度'),
                (1.25, '1.25x 轻快倍速', '轻微提速，不损台词听感'),
                (1.5, '1.5x 高效倍速', '适合快速浏览剧情推进'),
                (2.0, '2.0x 二倍速播放', '高速刷剧模式'),
              ],
              onSelected: (val) async {
                await widget.storage.setPlaySpeed(val);
                refreshBoth();
              },
            ),
            _buildSettingDrawerContainer(
              settingKey: 'skip_intro_outro',
              icon: CupertinoIcons.forward_fill,
              iconBgColor: AppleColors.systemIndigo,
              title: '片头 / 片尾自动跳过',
              subtitle: '设置剧集统一的片头起播与片尾跳过秒数',
              trailingText: _skipIntroOutroSummary,
              onStateChanged: refreshBoth,
              drawerChild:
                  _buildSkipIntroOutroDrawerBody(onStateChanged: refreshBoth),
            ),
            _buildExpandableChoiceDrawerTile<bool>(
              settingKey: 'episodes_order',
              icon: CupertinoIcons.sort_down,
              iconBgColor: AppleColors.systemGreen,
              title: '默认剧集排序方式',
              subtitle: '详情页与选集列表的默认排列顺序',
              trailingText:
                  widget.storage.episodesDescending ? '倒序（最新集）' : '正序（第 1 集起）',
              currentValue: widget.storage.episodesDescending,
              onStateChanged: refreshBoth,
              options: const [
                (false, '正序（第 1 集起）', '从第 1 集开始依次排列，适合从头追剧'),
                (true, '倒序（最新集起）', '最新更新的集数排在最前，适合追更连载剧集'),
              ],
              onSelected: (val) async {
                await widget.storage.setEpisodesDescending(val);
                refreshBoth();
              },
            ),
            AppleGroupedTile(
              icon: CupertinoIcons.forward_end_fill,
              iconBgColor: AppleColors.systemBlue,
              title: '自动连播下一集',
              subtitle: '当前剧集播放完毕后无缝切换下一集',
              trailing: CupertinoSwitch(
                value: widget.storage.autoNext,
                activeTrackColor: AppleColors.systemGreen,
                onChanged: (v) async {
                  await widget.storage.setAutoNext(v);
                  refreshBoth();
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildCloudAndDataSettingsSection(
    BuildContext context,
    VoidCallback refreshBoth,
  ) {
    final depots = _config?.depots ?? const [];
    final subs = widget.storage.getSubscriptions();
    final publicSubs = subs.where((s) => !s.isEffectivelyPrivate).toList();
    final publicSites = _config?.publicSupportedSites ?? const [];
    final loggedDriveCount = NetdiskService.drives
        .where((d) => widget.storage.isNetdiskLoggedIn(d.key))
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppleGroupedSection(
          header: '云盘扫码与 4K 原画账号',
          footer: '扫码或粘贴 Cookie / Token 绑定后，玩偶哥哥、聚剧四盘、盘搜等 4K 原画线路将自动启用。',
          children: [
            AppleGroupedTile(
              icon: CupertinoIcons.qrcode_viewfinder,
              iconBgColor: const Color(0xFF0A84FF),
              title: '我的云盘 · 网盘扫码与账号中心',
              subtitle: '夸克（我的夸父）/ UC（我的优汐）/ 百度（我的嘟嘟）/ 阿里（我的阿狸）',
              trailingText:
                  loggedDriveCount > 0 ? '已登录 $loggedDriveCount 个' : '去扫码',
              onTap: () => showNetdiskAccountSheet(
                context,
                widget.storage,
                onChanged: () {
                  refreshBoth();
                  if (mounted) setState(() {});
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),
        AppleGroupedSection(
          header: '片源仓库与备份',
          children: [
            if (publicSites.any((s) => s.isCatPaw))
              AppleGroupedTile(
                icon: CupertinoIcons.slider_horizontal_3,
                iconBgColor: AppleColors.systemBlue,
                title: 'CatPaw 本机配置',
                subtitle: '管理该订阅的启用线路与来源设置',
                onTap: _showCatPawSettings,
              ),
            AppleGroupedTile(
              icon: CupertinoIcons.folder_fill,
              iconBgColor: AppleColors.systemPurple,
              title: '订阅源与分组管理中心',
              subtitle: publicSubs.isEmpty
                  ? '批量导入、多仓切换与自定义分组（当前 ${publicSites.length} 可用片源）'
                  : '已导入 ${publicSubs.length} 个订阅 · ${publicSites.length} 个可用片源${depots.isNotEmpty ? " · ${depots.length} 个子仓库" : ""}',
              trailingText: '${publicSubs.length} 订阅',
              onTap: () async {
                await _showSubscriptionManagerSheet();
                if (context.mounted) refreshBoth();
              },
            ),
            AppleGroupedTile(
              icon: CupertinoIcons.arrow_2_circlepath,
              iconBgColor: AppleColors.systemGreen,
              title: '跨平台备份导出 / 恢复',
              subtitle: '与 Android、Windows、Mac、iPad 双向互通备份',
              onTap: _showBackupRestoreDialog,
            ),
          ],
        ),
        const SizedBox(height: 22),
        AppleGroupedSection(
          header: '系统更新与缓存存储',
          children: [
            AppleGroupedTile(
              icon: CupertinoIcons.arrow_down_circle_fill,
              iconBgColor: AppleColors.systemOrange,
              title: '检查版本更新',
              subtitle: '当前正式版 $_currentAppVersion · 按当前设备检查更新',
              trailingText: '检测更新',
              onTap: _showUpdateCheckSheet,
            ),
            AppleGroupedTile(
              icon: CupertinoIcons.trash_fill,
              iconBgColor: AppleColors.systemRed,
              title: '清理海报与搜索缓存',
              subtitle:
                  '海报内存缓存：${PosterLoader.memoryCacheSizeLabel} · 搜索历史 ${widget.storage.getSearchHistory(forPrivate: _privateSessionUnlocked).length} 条',
              trailingText: '一键清理',
              onTap: () async {
                await PosterLoader.clearCache();
                await widget.storage.clearSearchHistory(
                  forPrivate: _privateSessionUnlocked,
                );
                refreshBoth();
                if (!context.mounted) return;
                showCupertinoDialog<void>(
                  context: context,
                  barrierDismissible: true,
                  builder: (ctx) => CupertinoAlertDialog(
                    title: const Text('缓存已清理'),
                    content: const Text('已清空内存与磁盘海报缓存及搜索历史记录。'),
                    actions: [
                      CupertinoDialogAction(
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: const Text('好的'),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _showCatPawSettings([CmsSite? requested]) async {
    final bundles = <String,CmsSite>{};
    for (final site in _config?.publicSupportedSites ?? <CmsSite>[]) {
      if (site.isCatPaw) bundles.putIfAbsent(Uri.parse(site.api).host, () => site);
    }
    if (bundles.isEmpty && requested == null) return;
    CmsSite? selected = requested ?? bundles.values.first;
    if (requested == null && bundles.length > 1) {
      selected = await showCupertinoModalPopup<CmsSite>(context:context,builder:(sheet) => CupertinoActionSheet(
        title: const Text('选择 CatPaw 订阅'),
        actions: [for (final site in bundles.values) CupertinoActionSheetAction(
          onPressed:()=>Navigator.pop(sheet,site),child:Text(site.name))],
        cancelButton:CupertinoActionSheetAction(onPressed:()=>Navigator.pop(sheet),child:const Text('取消')),
      ));
    }
    if (selected == null || !mounted) return;
    try {
      final url = await CatPawHost.instance.settings(selected.api);
      if (!mounted) return;
      final opened = await launchUrl(url,mode:Platform.isIOS ? LaunchMode.inAppBrowserView : LaunchMode.externalApplication);
      if (!opened) throw StateError('无法打开本机配置页');
    } catch (_) {
      if (!mounted) return;
      await showCupertinoDialog<void>(context:context,builder:(dialog)=>CupertinoAlertDialog(
        title:const Text('无法打开 CatPaw 配置'),
        content:const Text('请确认订阅已成功导入，并使用包含本机运行组件的完整版本。'),
        actions:[CupertinoDialogAction(onPressed:()=>Navigator.pop(dialog),child:const Text('好的'))],
      ));
    }
  }

  Widget _buildSettingDrawerContainer({
    required String settingKey,
    required IconData icon,
    required Color iconBgColor,
    required String title,
    required String subtitle,
    required String trailingText,
    required Widget drawerChild,
    VoidCallback? onStateChanged,
  }) {
    final expanded = _expandedSettings.contains(settingKey);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (expanded) {
              _expandedSettings.remove(settingKey);
            } else {
              _expandedSettings.add(settingKey);
            }
            if (onStateChanged != null) {
              onStateChanged();
            } else {
              setState(() {});
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            child: Row(
              children: [
                DecoratedBox(
                  decoration: ShapeDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color.alphaBlend(const Color(0x28FFFFFF), iconBgColor),
                        iconBgColor,
                      ],
                    ),
                    shape: RoundedSuperellipseBorder(
                      borderRadius: BorderRadius.circular(7.5),
                      side: const BorderSide(
                        color: Color(0x33FFFFFF),
                        width: 0.5,
                      ),
                    ),
                  ),
                  child: SizedBox(
                    width: 30,
                    height: 30,
                    child: Icon(icon, size: 17, color: Colors.white),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: AppleColors.labelPrimary,
                          fontSize: 15.5,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.1,
                          height: 1.28,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppleColors.labelSecondary,
                          fontSize: 12.5,
                          height: 1.35,
                          letterSpacing: 0.1,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      trailingText,
                      style: TextStyle(
                        color: expanded
                            ? AppleColors.systemBlue
                            : AppleColors.labelSecondary,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                    const SizedBox(width: 5),
                    AnimatedRotation(
                      turns: expanded ? 0.5 : 0.0,
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      child: Icon(
                        CupertinoIcons.chevron_down,
                        size: 13.5,
                        color: expanded
                            ? AppleColors.systemBlue
                            : AppleColors.labelTertiary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox(width: double.infinity, height: 0),
          secondChild: Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0x3D000000),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: const Color(0x24FFFFFF),
                  width: 0.7,
                ),
              ),
              child: drawerChild,
            ),
          ),
          crossFadeState:
              expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 220),
          sizeCurve: Curves.easeOutCubic,
        ),
      ],
    );
  }

  Widget _buildExpandableChoiceDrawerTile<T>({
    required String settingKey,
    required IconData icon,
    required Color iconBgColor,
    required String title,
    required String subtitle,
    required String trailingText,
    required T currentValue,
    required List<(T, String, String)> options,
    required Future<void> Function(T) onSelected,
    VoidCallback? onStateChanged,
  }) {
    return _buildSettingDrawerContainer(
      settingKey: settingKey,
      icon: icon,
      iconBgColor: iconBgColor,
      title: title,
      subtitle: subtitle,
      trailingText: trailingText,
      onStateChanged: onStateChanged,
      drawerChild: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (int i = 0; i < options.length; i++) ...[
            if (i > 0) const SizedBox(height: 6),
            Builder(
              builder: (context) {
                final opt = options[i];
                final selected = opt.$1 == currentValue;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onSelected(opt.$1),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 11,
                    ),
                    decoration: BoxDecoration(
                      color: selected
                          ? const Color(0x280A84FF)
                          : const Color(0x12FFFFFF),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: selected
                            ? const Color(0x775AC8FA)
                            : const Color(0x16FFFFFF),
                        width: 0.7,
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                opt.$2,
                                style: TextStyle(
                                  color: selected
                                      ? const Color(0xFF5AC8FA)
                                      : AppleColors.labelPrimary,
                                  fontSize: 14,
                                  fontWeight: selected
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 2.5),
                              Text(
                                opt.$3,
                                style: const TextStyle(
                                  color: AppleColors.labelSecondary,
                                  fontSize: 11.5,
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          selected
                              ? CupertinoIcons.checkmark_circle_fill
                              : CupertinoIcons.circle,
                          size: 19,
                          color: selected
                              ? AppleColors.systemBlue
                              : AppleColors.labelTertiary,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildWallpaperDrawerBody({VoidCallback? onStateChanged}) {
    const presets = <(String, String, String, Color)>[
      ('obsidian', '曜石纯黑', '经典深邃纯黑影院底色', Color(0xFF141824)),
      ('midnight', '午夜深蓝', '静谧冷调深海蓝', Color(0xFF0E2240)),
      ('aurora', '极光紫韵', '灵动流光暗夜紫', Color(0xFF281542)),
      ('amber', '流金琥珀', '温暖复古鎏金棕', Color(0xFF382210)),
      ('emerald', '翡翠幽林', '沉稳护眼墨绿调', Color(0xFF0F3026)),
    ];
    final currentPreset = widget.storage.wallpaperPreset;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < presets.length; i++) ...[
          if (i > 0) const SizedBox(height: 6),
          Builder(
            builder: (context) {
              final item = presets[i];
              final selected = currentPreset == item.$1 &&
                  widget.storage.customWallpaperUrl.isEmpty;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () async {
                  await widget.storage.setCustomWallpaperUrl('');
                  await widget.storage.setWallpaperPreset(item.$1);
                  if (onStateChanged != null) {
                    onStateChanged();
                  } else {
                    setState(() {});
                  }
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 11,
                  ),
                  decoration: BoxDecoration(
                    color: selected
                        ? const Color(0x280A84FF)
                        : const Color(0x12FFFFFF),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: selected
                          ? const Color(0x775AC8FA)
                          : const Color(0x16FFFFFF),
                      width: 0.7,
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: item.$4,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: const Color(0x66FFFFFF),
                            width: 1,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.$2,
                              style: TextStyle(
                                color: selected
                                    ? const Color(0xFF5AC8FA)
                                    : AppleColors.labelPrimary,
                                fontSize: 14,
                                fontWeight: selected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              item.$3,
                              style: const TextStyle(
                                color: AppleColors.labelSecondary,
                                fontSize: 11.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        selected
                            ? CupertinoIcons.checkmark_circle_fill
                            : CupertinoIcons.circle,
                        size: 19,
                        color: selected
                            ? AppleColors.systemBlue
                            : AppleColors.labelTertiary,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
        const SizedBox(height: 6),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            _showWallpaperSettingsSheet();
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: const Color(0x180A84FF),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: const Color(0x3D5AC8FA),
                width: 0.7,
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  CupertinoIcons.link,
                  size: 16,
                  color: AppleColors.systemBlue,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.storage.customWallpaperUrl.isNotEmpty
                        ? '修改自定义壁纸地址（已启用）'
                        : '输入自定义高清壁纸 URL / 本地路径…',
                    style: const TextStyle(
                      color: AppleColors.systemBlue,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Icon(
                  CupertinoIcons.chevron_right,
                  size: 14,
                  color: AppleColors.systemBlue,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSkipIntroOutroDrawerBody({VoidCallback? onStateChanged}) {
    const presets = <int>[0, 15, 30, 60, 90, 120, 180];
    final curIntro = widget.storage.skipIntroSec;
    final curOutro = widget.storage.skipOutroSec;
    String fmtSec(int s) {
      if (s <= 0) return '00:00 (关闭)';
      final m = s ~/ 60;
      final r = s % 60;
      return '${m.toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')} (${s}s)';
    }

    Future<void> updateIntro(int sec) async {
      await widget.storage.setSkipIntroSec(sec.clamp(0, 300));
      if (onStateChanged != null) {
        onStateChanged();
      } else {
        setState(() {});
      }
    }

    Future<void> updateOutro(int sec) async {
      await widget.storage.setSkipOutroSec(sec.clamp(0, 300));
      if (onStateChanged != null) {
        onStateChanged();
      } else {
        setState(() {});
      }
    }

    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '跳过片头时长',
                  style: TextStyle(
                    color: AppleColors.labelSecondary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                fmtSec(curIntro),
                style: const TextStyle(
                  color: AppleColors.systemBlue,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          SizedBox(
            width: double.infinity,
            child: CupertinoSlider(
              value: curIntro.clamp(0, 300).toDouble(),
              min: 0,
              max: 300,
              divisions: 300,
              activeColor: AppleColors.systemBlue,
              onChanged: (v) => updateIntro(v.round()),
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final delta in const [-5, -1, 1, 5])
                GestureDetector(
                  onTap: () => updateIntro(curIntro + delta),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0x18FFFFFF),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: const Color(0x2EFFFFFF),
                        width: 0.5,
                      ),
                    ),
                    child: Text(
                      delta > 0 ? '+${delta}s' : '${delta}s',
                      style: const TextStyle(
                        color: AppleColors.labelSecondary,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              for (final sec in presets)
                GestureDetector(
                  onTap: () => updateIntro(sec),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 13,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: curIntro == sec
                          ? AppleColors.systemBlue
                          : const Color(0x22FFFFFF),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      sec == 0 ? '关闭' : '${sec}s',
                      style: TextStyle(
                        color: curIntro == sec
                            ? Colors.white
                            : AppleColors.labelPrimary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Expanded(
                child: Text(
                  '跳过片尾时长',
                  style: TextStyle(
                    color: AppleColors.labelSecondary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                fmtSec(curOutro),
                style: const TextStyle(
                  color: AppleColors.systemBlue,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          SizedBox(
            width: double.infinity,
            child: CupertinoSlider(
              value: curOutro.clamp(0, 300).toDouble(),
              min: 0,
              max: 300,
              divisions: 300,
              activeColor: AppleColors.systemBlue,
              onChanged: (v) => updateOutro(v.round()),
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final delta in const [-5, -1, 1, 5])
                GestureDetector(
                  onTap: () => updateOutro(curOutro + delta),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0x18FFFFFF),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: const Color(0x2EFFFFFF),
                        width: 0.5,
                      ),
                    ),
                    child: Text(
                      delta > 0 ? '+${delta}s' : '${delta}s',
                      style: const TextStyle(
                        color: AppleColors.labelSecondary,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              for (final sec in presets)
                GestureDetector(
                  onTap: () => updateOutro(sec),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 13,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: curOutro == sec
                          ? AppleColors.systemBlue
                          : const Color(0x22FFFFFF),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      sec == 0 ? '关闭' : '${sec}s',
                      style: TextStyle(
                        color: curOutro == sec
                            ? Colors.white
                            : AppleColors.labelPrimary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _currentAppVersion = '读取中';

  Future<void> _loadInstalledVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _currentAppVersion = info.version);
    } catch (_) {
      if (mounted) setState(() => _currentAppVersion = '未知');
    }
  }

  static String _formatCleanReleaseNotes(String raw) {
    final lines = raw.split(RegExp(r'\r?\n'));
    final out = <String>[];
    for (var line in lines) {
      var trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      trimmed = trimmed
          .replaceFirst(RegExp(r'^#{1,6}\s*'), '')
          .replaceAll('**', '')
          .replaceAll('`', '')
          .trim();
      if (trimmed.startsWith('- Platform:') ||
          trimmed.startsWith('Platform:') ||
          trimmed.startsWith('- Commit:') ||
          trimmed.startsWith('Commit:')) {
        continue;
      }
      if (trimmed.toLowerCase() == 'changes') {
        trimmed = '本次更新内容：';
      } else if (trimmed.startsWith('- ')) {
        trimmed = '• ${trimmed.substring(2).trim()}';
      }
      out.add(trimmed);
    }
    return out.join('\n');
  }

  static bool _isRemoteVersionNewer(String remote, String current) {
    List<int> parseParts(String v) => v
        .replaceAll(RegExp(r'^[vV]'), '')
        .split(RegExp(r'[^0-9]+'))
        .where((s) => s.isNotEmpty)
        .map((s) => int.tryParse(s) ?? 0)
        .toList();
    final r = parseParts(remote);
    final c = parseParts(current);
    final len = math.max(r.length, c.length);
    for (var i = 0; i < len; i++) {
      final rv = i < r.length ? r[i] : 0;
      final cv = i < c.length ? c[i] : 0;
      if (rv != cv) return rv > cv;
    }
    return false;
  }

  void _showUpdateCheckSheet() {
    bool checking = true;
    bool downloading = false;
    double progress = 0.0;
    String statusText = '正在连接镜像站检测最新版本…';
    String latestVersion = _currentAppVersion;
    String releaseNotes = '';
    String downloadUrl = '';
    bool hasNewer = false;
    bool checkStarted = false;
    AppUpdate? release;

    showAppleModalSheet<void>(
      context: context,
      title: '检查版本更新',
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            Future<void> checkRemote() async {
              try {
                final installed = await PackageInfo.fromPlatform();
                if (installed.version.isEmpty) throw const FormatException('无法读取已安装版本');
                _currentAppVersion = installed.version;
                release = await AppUpdate.check();
                latestVersion = release!.version;
                releaseNotes = _formatCleanReleaseNotes(release!.notes);
                downloadUrl = release!.windowsUrl?.toString() ?? '';
                hasNewer = _isRemoteVersionNewer(latestVersion, _currentAppVersion);
                statusText = hasNewer ? '发现新版本 v$latestVersion（当前 v$_currentAppVersion）'
                    : '当前已是最新版本（v$_currentAppVersion）';
              } catch (_) {
                statusText = '暂时无法检查更新，请稍后重试或打开官方下载站';
              }
              if (ctx.mounted) setSheetState(() => checking = false);
            }

            if (!checkStarted) {
              checkStarted = true;
              Future.microtask(checkRemote);
            }

            Future<void> downloadAndInstallWindows() async {
              if (downloadUrl.isEmpty || downloading) return;
              setSheetState(() {
                downloading = true;
                progress = 0.02;
                statusText = '正在下载 Windows 安装更新包…';
              });
              final http = HttpClient()
                ..connectionTimeout = const Duration(seconds: 15);
              try {
                final uri = Uri.parse(downloadUrl);
                final req = await http.getUrl(uri);
                final resp = await req.close();
                if (resp.statusCode != 200) {
                  throw Exception('HTTP ${resp.statusCode}');
                }
                final total = release!.size!;
                if (resp.contentLength >= 0 && resp.contentLength != total) {
                  throw const FormatException('更新包大小与发布清单不一致');
                }
                final isExe =
                    downloadUrl.toLowerCase().contains('setup.exe') ||
                        downloadUrl.toLowerCase().endsWith('.exe');
                final ext = isExe ? 'exe' : 'zip';
                final filePath =
                    '${Directory.systemTemp.path}${Platform.pathSeparator}MarcoMovie-$latestVersion-update.$ext';
                final outFile = File(filePath);
                final sink = outFile.openWrite();
                var received = 0;
                try {
                await for (final chunk in resp.timeout(const Duration(seconds: 30))) {
                  received += chunk.length;
                  if (received > total) throw const FormatException('更新包超过发布大小');
                  sink.add(chunk);
                  if (total > 0 && ctx.mounted) {
                    setSheetState(() {
                      progress = (received / total).clamp(0.02, 0.99);
                    });
                  }
                }
                await sink.flush();
                } finally {
                  await sink.close();
                }
                await release!.verifyFile(outFile);
                if (!ctx.mounted) return;
                if (isExe) {
                  if (ctx.mounted) {
                    setSheetState(() {
                      progress = 1.0;
                      statusText = '下载完成，正在打开安装向导…';
                    });
                  }
                  await Process.start(
                    filePath,
                    const [],
                    mode: ProcessStartMode.detached,
                  );
                  if (ctx.mounted) setSheetState(() {
                    downloading = false;
                    statusText = '安装向导已打开，请按提示完成更新';
                  });
                } else {
                  await Process.start(
                    'explorer.exe',
                    ['/select,', filePath],
                    mode: ProcessStartMode.detached,
                  );
                  if (ctx.mounted) {
                    setSheetState(() {
                      downloading = false;
                      statusText = '更新包已保存至：$filePath';
                    });
                  }
                }
              } catch (e) {
                if (ctx.mounted) {
                  setSheetState(() {
                    downloading = false;
                    statusText = '自动下载失败：$e';
                  });
                }
              } finally {
                http.close(force: true);
              }
            }

            return Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (checking || downloading) ...[
                        const CupertinoActivityIndicator(radius: 10),
                        const SizedBox(width: 10),
                      ] else ...[
                        Icon(
                          hasNewer
                              ? CupertinoIcons.arrow_down_circle_fill
                              : CupertinoIcons.checkmark_seal_fill,
                          color: hasNewer
                              ? AppleColors.systemBlue
                              : AppleColors.systemGreen,
                          size: 22,
                        ),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: Text(
                          statusText,
                          style: const TextStyle(
                            color: AppleColors.labelPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (downloading) ...[
                    const SizedBox(height: 12),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 6,
                        backgroundColor: const Color(0x26FFFFFF),
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          AppleColors.systemBlue,
                        ),
                      ),
                    ),
                  ],
                  if (releaseNotes.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    Container(
                      width: double.infinity,
                      constraints: const BoxConstraints(maxHeight: 200),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppleColors.groupedSecondary,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: AppleColors.glassBorder,
                          width: 0.5,
                        ),
                      ),
                      child: SingleChildScrollView(
                        child: Text(
                          releaseNotes,
                          style: const TextStyle(
                            color: AppleColors.labelSecondary,
                            fontSize: 12.5,
                            height: 1.45,
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  if (!checking && !downloading)
                    Row(
                      children: [
                        if (!kIsWeb &&
                            Platform.isWindows &&
                            downloadUrl.isNotEmpty)
                          Expanded(
                            child: AppleCapsuleButton(
                              label: hasNewer
                                  ? '一键下载安装 v$latestVersion'
                                  : '重新下载安装 v$latestVersion',
                              icon: CupertinoIcons.arrow_down_to_line,
                              primary: true,
                              onPressed: downloadAndInstallWindows,
                            ),
                          ),
                        if (!kIsWeb &&
                            Platform.isWindows &&
                            downloadUrl.isNotEmpty)
                          const SizedBox(width: 10),
                        Expanded(
                          child: AppleCapsuleButton(
                            label: '打开官方下载站',
                            icon: CupertinoIcons.globe,
                            primary: kIsWeb || !Platform.isWindows,
                            onPressed: () async {
                              const mirror =
                                  'https://marcotv.wlj9919.top/movie/';
                              if (!kIsWeb && Platform.isWindows) {
                                await Process.run(
                                  'cmd',
                                  ['/c', 'start', '', mirror],
                                );
                              } else if (!kIsWeb && Platform.isMacOS) {
                                await Process.run('open', [mirror]);
                              } else {
                                await Clipboard.setData(
                                  const ClipboardData(text: mirror),
                                );
                                _showAppleNotice(
                                  '已复制下载站地址',
                                  '请在浏览器中打开：$mirror',
                                );
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showWallpaperSettingsSheet() {
    final urlCtrl = TextEditingController(
      text: widget.storage.customWallpaperUrl,
    );
    const presets = <(String, String, Color, Color)>[
      ('obsidian', '曜石纯黑', Color(0xFF141824), Color(0xFF050507)),
      ('midnight', '午夜深蓝', Color(0xFF0E2240), Color(0xFF060A14)),
      ('aurora', '极光紫韵', Color(0xFF281542), Color(0xFF090612)),
      ('amber', '流金琥珀', Color(0xFF382210), Color(0xFF0D0805)),
      ('emerald', '翡翠幽林', Color(0xFF0F3026), Color(0xFF050E0B)),
    ];
    showAppleModalSheet<void>(
      context: context,
      title: '背景壁纸与主题风格',
      ignoreKeyboardInsets: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          final currentPreset = widget.storage.wallpaperPreset;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Apple 影院级预设背景',
                  style: TextStyle(
                    color: AppleColors.labelSecondary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final (key, label, c1, c2) in presets)
                      GestureDetector(
                        onTap: () async {
                          await widget.storage.setCustomWallpaperUrl('');
                          await widget.storage.setWallpaperPreset(key);
                          urlCtrl.clear();
                          setModalState(() {});
                          if (mounted) setState(() {});
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: 112,
                          height: 68,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [c1, c2],
                            ),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: currentPreset == key &&
                                      widget.storage.customWallpaperUrl.isEmpty
                                  ? AppleColors.systemBlue
                                  : AppleColors.glassBorder,
                              width: currentPreset == key &&
                                      widget.storage.customWallpaperUrl.isEmpty
                                  ? 1.6
                                  : 0.6,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Container(
                                    width: 14,
                                    height: 14,
                                    decoration: BoxDecoration(
                                      color: c1,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: Colors.white38,
                                        width: 0.6,
                                      ),
                                    ),
                                  ),
                                  if (currentPreset == key &&
                                      widget.storage.customWallpaperUrl.isEmpty)
                                    const Icon(
                                      CupertinoIcons.checkmark_circle_fill,
                                      color: AppleColors.systemBlue,
                                      size: 16,
                                    ),
                                ],
                              ),
                              Text(
                                label,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                const Text(
                  '自定义高清壁纸（支持图片直链 URL 或本地图片路径）',
                  style: TextStyle(
                    color: AppleColors.labelSecondary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                CupertinoTextField(
                  controller: urlCtrl,
                  placeholder: 'https://wallpaper.example/cinema.jpg 或本地图片路径',
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: AppleColors.groupedSecondary,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: AppleColors.glassBorder,
                      width: 0.5,
                    ),
                  ),
                  style: const TextStyle(
                    color: AppleColors.labelPrimary,
                    fontSize: 13.5,
                  ),
                  placeholderStyle: const TextStyle(
                    color: AppleColors.labelTertiary,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (widget.storage.customWallpaperUrl.isNotEmpty) ...[
                      AppleCapsuleButton(
                        label: '恢复默认背景',
                        compact: true,
                        onPressed: () async {
                          urlCtrl.clear();
                          await widget.storage.setCustomWallpaperUrl('');
                          await widget.storage.setWallpaperPreset('obsidian');
                          setModalState(() {});
                          if (mounted) setState(() {});
                        },
                      ),
                      const SizedBox(width: 10),
                    ],
                    AppleCapsuleButton(
                      label: '应用壁纸',
                      icon: CupertinoIcons.checkmark_alt,
                      primary: true,
                      compact: true,
                      onPressed: () async {
                        final val = urlCtrl.text.trim();
                        await widget.storage.setCustomWallpaperUrl(val);
                        if (val.isNotEmpty) {
                          await widget.storage.setWallpaperPreset('custom');
                        }
                        if (ctx.mounted) Navigator.of(ctx).pop();
                        if (mounted) setState(() {});
                      },
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
  void _showPreferredQualityPickerSheet() {
    const options = <(String, String, String, IconData)>[
      (
        '4k_netdisk',
        '4K 超清原画优先',
        '优先匹配 4K HDR / 杜比视界超清高码率线路',
        CupertinoIcons.sparkles,
      ),
      (
        '1080p_direct',
        '1080P 高清直连优先',
        '优先匹配蓝光 1080P 直连点播线路，兼顾高画质与无需扫码',
        CupertinoIcons.tv_fill,
      ),
      (
        'fast_hls',
        '极速 M3U8 流媒体优先',
        '优先匹配秒开 M3U8 流媒体线路，适合移动网络或弱网环境',
        CupertinoIcons.bolt_fill,
      ),
      (
        'auto',
        '站点默认顺序',
        '保持片源原始线路排列顺序，不做自动重排',
        CupertinoIcons.layers_alt_fill,
      ),
    ];
    showAppleModalSheet<void>(
      context: context,
      title: '默认画质与线路推荐',
      builder: (ctx) => ListView.separated(
        shrinkWrap: true,
        padding: const EdgeInsets.all(16),
        itemCount: options.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (ctx, i) {
          final (key, title, subtitle, icon) = options[i];
          final selected = widget.storage.preferredQuality == key;
          return Container(
            decoration: BoxDecoration(
              color: selected
                  ? const Color(0x330A84FF)
                  : AppleColors.groupedSecondary,
              borderRadius: BorderRadius.circular(14),
            ),
            child: AppleGroupedTile(
              icon: icon,
              iconBgColor:
                  selected ? AppleColors.systemBlue : AppleColors.groupedTertiary,
              title: title,
              subtitle: subtitle,
              trailing: selected
                  ? const Icon(
                      CupertinoIcons.checkmark_circle_fill,
                      color: AppleColors.systemBlue,
                      size: 18,
                    )
                  : null,
              onTap: () async {
                await widget.storage.setPreferredQuality(key);
                if (ctx.mounted) Navigator.of(ctx).pop();
                if (mounted) setState(() {});
              },
            ),
          );
        },
      ),
    );
  }
  void _showSkipIntroOutroSheet() {
    showAppleModalSheet<void>(
      context: context,
      title: '片头 / 片尾自动跳过',
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final intro = widget.storage.skipIntroSec;
          final outro = widget.storage.skipOutroSec;
          const presets = [0, 15, 30, 45, 60, 90, 120];
          return Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '跳过片头：${intro == 0 ? "不跳过" : "$intro 秒"}',
                  style: const TextStyle(
                    color: AppleColors.labelPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final sec in presets)
                      _buildMiniFilterChip(
                        label: sec == 0 ? '关闭' : '${sec}s',
                        selected: intro == sec,
                        onTap: () async {
                          await widget.storage.setSkipIntroSec(sec);
                          setSheetState(() {});
                          if (mounted) setState(() {});
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                Text(
                  '跳过片尾：${outro == 0 ? "不跳过" : "$outro 秒"}',
                  style: const TextStyle(
                    color: AppleColors.labelPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final sec in presets)
                      _buildMiniFilterChip(
                        label: sec == 0 ? '关闭' : '${sec}s',
                        selected: outro == sec,
                        onTap: () async {
                          await widget.storage.setSkipOutroSec(sec);
                          setSheetState(() {});
                          if (mounted) setState(() {});
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 14),
              ],
            ),
          );
        },
      ),
    );
  }
  Future<void> _showSubscriptionManagerSheet() async {
    await showAppleModalSheet<void>(
      context: context,
      title: '订阅源与分组管理中心',
      trailingAction: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            minSize: 28,
            onPressed: () {
              Navigator.of(context).pop();
              _quickImportFromClipboard();
            },
            child: const Text(
              '剪贴板导入',
              style: TextStyle(color: AppleColors.labelSecondary, fontSize: 13),
            ),
          ),
          CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            minSize: 28,
            onPressed: () {
              Navigator.of(context).pop();
              _showImportConfigDialog();
            },
            child: const Text(
              '+ 批量导入',
              style: TextStyle(color: AppleColors.systemBlue, fontSize: 13.5),
            ),
          ),
        ],
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final depots = _config?.depots ?? const [];
          final subs = widget.storage
              .getSubscriptions()
              .where((s) => !s.isEffectivelyPrivate)
              .toList();
          if (subs.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    CupertinoIcons.folder_badge_plus,
                    color: AppleColors.labelTertiary,
                    size: 44,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '暂未添加多订阅分组',
                    style: TextStyle(
                      color: AppleColors.labelPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '支持同时导入多个 VOD / M3U / JSON 订阅地址，或一键从剪贴板读取并按分组归类管理。',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppleColors.labelSecondary,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    alignment: WrapAlignment.center,
                    children: [
                      AppleCapsuleButton(
                        label: '批量导入订阅',
                        icon: CupertinoIcons.add,
                        primary: true,
                        compact: true,
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          _showImportConfigDialog();
                        },
                      ),
                      AppleCapsuleButton(
                        label: '从剪贴板导入',
                        icon: CupertinoIcons.doc_on_clipboard,
                        compact: true,
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          _quickImportFromClipboard();
                        },
                      ),
                    ],
                  ),
                ],
              ),
            );
          }
          final byGroup = <String, List<SubscriptionEntry>>{};
          for (final s in subs) {
            byGroup.putIfAbsent(s.group, () => []).add(s);
          }
          return ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(16),
            children: [
              if (depots.isNotEmpty) ...[
                AppleGroupedSection(
                  header: '多仓子仓库切换 (${depots.length})',
                  children: [
                    AppleGroupedTile(
                      icon: CupertinoIcons.archivebox_fill,
                      iconBgColor: AppleColors.systemOrange,
                      title: '切换当前多仓子仓库',
                      subtitle: widget.storage.activeDepotName.isEmpty
                          ? '共 ${depots.length} 个可选子仓库'
                          : '当前：${widget.storage.activeDepotName}',
                      trailingText: '${depots.length} 个',
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _showDepotPickerDialog();
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 14),
              ],
              for (final entry in byGroup.entries) ...[
                AppleGroupedSection(
                  header: '${entry.key} (${entry.value.length})',
                  children: entry.value.map((sub) {
                    return AppleGroupedTile(
                      icon: sub.isPrivate
                          ? CupertinoIcons.lock_shield_fill
                          : CupertinoIcons.link,
                      iconBgColor: sub.enabled
                          ? AppleColors.systemBlue
                          : AppleColors.groupedTertiary,
                      title: '${sub.name} · [${sub.format}]',
                      subtitle:
                          '${sub.siteCount} 片源 · ${sub.liveCount} 直播${sub.warehouseUrl.isNotEmpty ? " · ${sub.warehouseUrl}" : (sub.url.isNotEmpty ? " · ${sub.url}" : "")}',
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CupertinoSwitch(
                            value: sub.enabled,
                            activeTrackColor: AppleColors.systemGreen,
                            onChanged: (v) async {
                              await widget.storage.toggleSubscriptionEnabled(
                                sub.id,
                                v,
                              );
                              _reloadSavedConfig();
                              setSheetState(() {});
                            },
                          ),
                          CupertinoButton(
                            padding: const EdgeInsets.only(left: 6),
                            minSize: 28,
                            onPressed: () async {
                              try {
                                await widget.storage.removeSubscription(sub.id);
                                if (!mounted) return;
                                _reloadSavedConfig();
                                if (ctx.mounted) setSheetState(() {});
                              } catch (_) {
                                if (mounted) {
                                  _showAppleNotice('删除未保存', '订阅变更未能保存，请重试。');
                                }
                              }
                            },
                            child: const Icon(
                              CupertinoIcons.trash,
                              color: AppleColors.systemRed,
                              size: 18,
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 14),
              ],
            ],
          );
        },
      ),
    );
  }
  void _showDepotPickerDialog() {
    final depots = _config?.depots ?? const [];
    if (depots.isEmpty) return;
    showAppleModalSheet<void>(
      context: context,
      title: '切换多仓子仓库 (${depots.length})',
      builder: (ctx) {
        bool loading = false;
        String? errorMsg;
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (loading)
                  const Padding(
                    padding: EdgeInsets.all(14),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CupertinoActivityIndicator(radius: 10),
                        SizedBox(width: 10),
                        Text(
                          '正在加载所选子仓库…',
                          style: TextStyle(
                            color: AppleColors.labelSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (errorMsg != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                    child: Text(
                      errorMsg!,
                      style: const TextStyle(
                        color: AppleColors.systemRed,
                        fontSize: 13,
                      ),
                    ),
                  ),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.all(16),
                    itemCount: depots.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (ctx, i) {
                      final d = depots[i];
                      final owners = widget.storage.getSubscriptions()
                          .where((sub) => sub.id == d.subscriptionId);
                      final owner = owners.isEmpty ? null : owners.first;
                      final isCurrent = d.url == (owner?.url ?? widget.storage.configOrigin);
                      return Container(
                        decoration: BoxDecoration(
                          color: isCurrent
                              ? const Color(0x330A84FF)
                              : AppleColors.groupedSecondary,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: AppleGroupedTile(
                          icon: CupertinoIcons.archivebox_fill,
                          iconBgColor: isCurrent
                              ? AppleColors.systemBlue
                              : AppleColors.groupedTertiary,
                          title: d.name,
                          subtitle: d.url,
                          trailing: isCurrent
                              ? const Icon(
                                  CupertinoIcons.checkmark_alt,
                                  color: AppleColors.systemBlue,
                                  size: 18,
                                )
                              : null,
                          onTap: loading
                              ? null
                              : () async {
                                  setModalState(() {
                                    loading = true;
                                    errorMsg = null;
                                  });
                                  try {
                                    if (owner != null) {
                                      final withDirectory = owner.copyWith(depots: depots
                                          .where((entry) => entry.subscriptionId == owner.id).toList());
                                      final updated = await widget.client.switchSubscriptionDepot(withDirectory, d);
                                      if (!ctx.mounted) return;
                                      await widget.storage.upsertSubscriptions([updated]);
                                    } else {
                                      final resolved = await widget.client.resolveConfigInput(urlInput: d.url);
                                      if (!ctx.mounted) return;
                                      await widget.storage.saveConfig(resolved.rawConfig,
                                        origin: resolved.origin,
                                        depots: [...depots, ...resolved.depots],
                                        activeDepotName: resolved.activeDepotName.isEmpty ? d.name : resolved.activeDepotName);
                                    }
                                    if (ctx.mounted) Navigator.of(ctx).pop();
                                    _reloadSavedConfig();
                                  } catch (e) {
                                    if (!ctx.mounted) return;
                                    setModalState(() {
                                      loading = false;
                                      errorMsg = '切换仓库失败：$e';
                                    });
                                  }
                                },
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
  Future<void> _managePickerSites(bool privateGroup) async {
    final ordered = (_config?.sites ?? const <CmsSite>[])
        .where((s) => s.isEffectivelyPrivate == privateGroup).toList();
    final removed = <CmsSite>[];
    bool saving = false;
    await showAppleModalSheet<void>(
      context: context, title: '管理线路',
      builder: (ctx) => StatefulBuilder(builder: (ctx, update) {
        return SizedBox(height: MediaQuery.sizeOf(ctx).height * .62, child: Column(children: [
          Expanded(child: ReorderableListView.builder(
            buildDefaultDragHandles: false, itemCount: ordered.length,
            onReorder: (from, to) => update(() {
              if (to > from) to--;
              ordered.insert(to, ordered.removeAt(from));
            }),
            itemBuilder: (_, i) {
              final site = ordered[i];
              return ListTile(key: ValueKey(site.key), title: Text(site.name),
                leading: ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_handle)),
                trailing: IconButton(tooltip: '删除这条线路', icon: const Icon(Icons.remove_circle_outline),
                  onPressed: saving ? null : () => update(() => removed.add(ordered.removeAt(i)))));
            },
          )),
          AppleCapsuleButton(label: removed.isEmpty ? '保存顺序' : '保存并移除 ${removed.length} 条线路',
            onPressed: saving ? null : () async {
              update(() => saving = true);
              try {
                await widget.storage.savePickerEdits(ordered, removed);
                if (ctx.mounted) Navigator.of(ctx).pop();
                if (mounted) _reloadSavedConfig();
              } catch (_) {
                if (mounted) _showAppleNotice('线路变更未保存', '保存未完成，请重试。');
              } finally {
                if (ctx.mounted) update(() => saving = false);
              }
            }),
        ]));
      }),
    );
  }

  void _showSitePickerDialog() {
    final inPrivacyMode = _privateSessionUnlocked;
    final defaultGroupName = inPrivacyMode ? '隐私分组' : '默认分组';
    final supported = inPrivacyMode
        ? (_config?.privateSupportedSites ?? const <CmsSite>[])
        : (_config?.publicSupportedSites ?? const <CmsSite>[]);
    final countSource = supported.isNotEmpty
        ? supported
        : (_config?.sites ?? const <CmsSite>[])
            .where((s) => inPrivacyMode ? s.isEffectivelyPrivate : !s.isEffectivelyPrivate)
            .toList();
    final groupCounts = <String, int>{'全部': countSource.length};
    final groups = <String>['全部'];
    for (final s in countSource) {
      if (!inPrivacyMode && s.isEffectivelyPrivate) continue;
      if (inPrivacyMode && !s.isEffectivelyPrivate) continue;
      final g = s.group.trim().isEmpty ? defaultGroupName : s.group.trim();
      if (!groups.contains(g)) groups.add(g);
      groupCounts[g] = (groupCounts[g] ?? 0) + 1;
    }
    String selectedGroup = '全部';
    String searchQuery = '';
    bool showUnsupported = false;
    final searchCtrl = TextEditingController();
    final plugins = (_config?.pluginOnlySites ?? const <CmsSite>[])
        .where((s) => inPrivacyMode ? s.isEffectivelyPrivate : !s.isEffectivelyPrivate)
        .toList();
    showAppleModalSheet<void>(
      context: context,
      title: inPrivacyMode
          ? '切换隐私片源 (${supported.length} 可用)'
          : '切换片源 (${supported.length} 可用)',
      maxWidth: 680,
      ignoreKeyboardInsets: true,
      trailingAction: inPrivacyMode
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minSize: 28,
                  onPressed: () {
                    Navigator.of(context).pop();
                    _showPrivateResourcesSheet();
                  },
                  child: const Text(
                    '管理 / 密码',
                    style: TextStyle(
                      color: Color(0xFFBF5AF2),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minSize: 28,
                  onPressed: () {
                    Navigator.of(context).pop();
                    _showImportConfigDialog(
                      initialGroup: '隐私分组',
                      initialIsPrivate: true,
                    );
                  },
                  child: const Text(
                    '+ 导入隐私源',
                    style: TextStyle(color: AppleColors.systemBlue, fontSize: 13),
                  ),
                ),
              ],
            )
          : CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minSize: 28,
              onPressed: () {
                Navigator.of(context).pop();
                _showImportConfigDialog();
              },
              child: const Text(
                '+ 导入订阅',
                style: TextStyle(color: AppleColors.systemBlue, fontSize: 13.5),
              ),
            ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setPickerState) {
          final size = MediaQuery.sizeOf(ctx);
          bool matchesFilter(CmsSite s) {
            final g =
                s.group.trim().isEmpty ? defaultGroupName : s.group.trim();
            final groupMatch = selectedGroup == '全部' || g == selectedGroup;
            if (!groupMatch) return false;
            final q = searchQuery.trim().toLowerCase();
            if (q.isEmpty) return true;
            return s.name.toLowerCase().contains(q) ||
                g.toLowerCase().contains(q) ||
                s.api.toLowerCase().contains(q);
          }
          final filteredSites = supported.where(matchesFilter).toList();
          final filteredPlugins = plugins.where(matchesFilter).toList();

          String siteBadgeLabel(CmsSite s) {
            final lower = '${s.name} ${s.api} ${s.key}'.toLowerCase();
            if (lower.contains('豆瓣') || lower.contains('douban')) {
              return '官方片单';
            }
            if (lower.contains('4k') || lower.contains('2160')) {
              return '4K超清';
            }
            if (s.isScriptOrJarApi) return '专用适配';
            return '直连点播';
          }

          Color siteBadgeColor(CmsSite s) {
            final badge = siteBadgeLabel(s);
            return switch (badge) {
              '4K超清' => const Color(0xFF30D158),
              '官方片单' => const Color(0xFFFF9F0A),
              '专用适配' => const Color(0xFF5E5CE6),
              _ => const Color(0xFF0A84FF),
            };
          }

          return SizedBox(
            height: (size.height * 0.72).clamp(380.0, 620.0),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: CustomScrollView(
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                physics: const BouncingScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Row(
                    children: [
                      Expanded(
                        child: AppleSearchField(
                          controller: searchCtrl,
                          placeholder: '快速筛选片源名称或分组…',
                          onChanged: (v) => setPickerState(() => searchQuery = v),
                        ),
                      ),
                      const SizedBox(width: 10),
                      CupertinoButton(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                        minSize: 28,
                        child: const Text(
                          '管理线路',
                          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                        ),
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          _managePickerSites(inPrivacyMode);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  // Centered Group Pills Row
                  SizedBox(
                    height: MediaQuery.textScalerOf(ctx).scale(16) + 20,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      physics: const BouncingScrollPhysics(),
                      itemCount: groups.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (ctx, idx) {
                        final g = groups[idx];
                        final count = groupCounts[g] ?? 0;
                        final isSelected = selectedGroup == g;
                        return GestureDetector(
                          onTap: () => setPickerState(() => selectedGroup = g),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOutCubic,
                            height: MediaQuery.textScalerOf(ctx).scale(16) + 20,
                            alignment: Alignment.center,
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            decoration: BoxDecoration(
                              gradient: isSelected
                                  ? const LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Color(0xFF0A84FF),
                                        Color(0xFF0066CC),
                                      ],
                                    )
                                  : const LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Color(0xCC2A2A32),
                                        Color(0xB81D1D24),
                                      ],
                                    ),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: isSelected
                                    ? const Color(0x995AC8FA)
                                    : const Color(0x2EFFFFFF),
                                width: 0.65,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Text(
                                  g,
                                  textAlign: TextAlign.center,
                                  strutStyle: const StrutStyle(
                                    forceStrutHeight: true,
                                    height: 1.1,
                                    fontSize: 13,
                                  ),
                                  style: TextStyle(
                                    color: isSelected
                                        ? Colors.white
                                        : AppleColors.labelPrimary,
                                    fontSize: 13,
                                    height: 1.1,
                                    fontWeight: isSelected
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                    '$count',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: isSelected
                                          ? Colors.white
                                          : AppleColors.labelSecondary,
                                      fontSize: 11,
                                      height: 1.0,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                    ],
                  )),
                  if (filteredSites.isEmpty && filteredPlugins.isEmpty)
                    const SliverToBoxAdapter(child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('未找到匹配的片源', style: TextStyle(
                        color: AppleColors.labelSecondary, fontSize: 14)),
                    ))
                  else
                              SourceChoiceSliver(
                                sites: filteredSites,
                                selectedKey: _activeSite?.key,
                                preferredKey: widget.storage.preferredSiteKey,
                                onPreferred: inPrivacyMode ? null : (s) async {
                                  await widget.storage.setPreferredSiteKey(
                                    widget.storage.preferredSiteKey == s.key ? '' : s.key);
                                  if (ctx.mounted) setPickerState(() {});
                                },
                                badgeLabel: siteBadgeLabel,
                                badgeColor: siteBadgeColor,
                                onSelected: (s) {
                                  Navigator.of(ctx).pop();
                                  if (s.isCatPaw && Uri.parse(s.api).path == '/api/baseset') {
                                    _showCatPawSettings(s);
                                    return;
                                  }
                                  if (inPrivacyMode) {
                                    setState(() {
                                      _privateSessionUnlocked = true;
                                      _selectedPrivateSiteKey = s.key;
                                      _activeSite = s;
                                    });
                                  } else {
                                    widget.storage.setSelectedSiteKey(s.key);
                                    unawaited(CmsClient.retainScriptSessions(
                                      (_config?.scriptOwners ?? const <CmsSite>[])
                                          .where((site) => !site.isEffectivelyPrivate),
                                    ));
                                    setState(() {
                                      _privateSessionUnlocked = false;
                                      _activeSite = s;
                                    });
                                  }
                                  _loadSiteHome();
                                },
                              ),
                              if (filteredPlugins.isNotEmpty) ...[
                                SliverToBoxAdapter(
                                  child: Padding(
                                    padding: const EdgeInsets.only(top: 12),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onTap: () => setPickerState(
                                            () => showUnsupported =
                                                !showUnsupported,
                                          ),
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 6,
                                              vertical: 6,
                                            ),
                                            child: Row(
                                              children: [
                                                Text(
                                                  '当前设备未适配 (${filteredPlugins.length})',
                                                  style: const TextStyle(
                                                    color: AppleColors
                                                        .labelSecondary,
                                                    fontSize: 12.5,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                                const Spacer(),
                                                Icon(
                                                  (showUnsupported ||
                                                          searchQuery
                                                              .trim()
                                                              .isNotEmpty ||
                                                          filteredSites.isEmpty)
                                                      ? CupertinoIcons
                                                          .chevron_up
                                                      : CupertinoIcons
                                                          .chevron_down,
                                                  size: 13,
                                                  color: AppleColors
                                                      .labelSecondary,
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                        if (showUnsupported ||
                                            searchQuery.trim().isNotEmpty ||
                                            filteredSites.isEmpty)
                                          AppleGroupedSection(
                                            children: filteredPlugins.map((s) {
                                              return AppleGroupedTile(
                                                icon: CupertinoIcons
                                                    .lock_shield_fill,
                                                iconBgColor: AppleColors
                                                    .groupedTertiary,
                                                title: s.name,
                                                subtitle: s.unsupportedReason,
                                              );
                                            }).toList(),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
  Future<bool> _connectEmby(
    BuildContext parent,
    String group,
    bool isPrivate,
  ) async {
    String server = '', username = '', password = '', error = '';
    bool busy = false;
    return await showAppleModalSheet<bool>(
          context: parent,
          title: '连接 Emby 媒体库',
          builder: (sheet) => StatefulBuilder(
            builder: (ctx, update) => SingleChildScrollView(
              padding: const EdgeInsets.all(18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CupertinoTextField(
                    placeholder: '服务器地址（含端口或子路径）',
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    onChanged: (v) => server = v,
                  ),
                  const SizedBox(height: 10),
                  CupertinoTextField(
                    placeholder: '用户名',
                    autocorrect: false,
                    onChanged: (v) => username = v,
                  ),
                  const SizedBox(height: 10),
                  CupertinoTextField(
                    placeholder: '密码',
                    obscureText: true,
                    onChanged: (v) => password = v,
                  ),
                  if (error.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(error),
                    ),
                  CupertinoButton(
                    onPressed: busy
                        ? null
                        : () async {
                            if (server.trim().isEmpty ||
                                username.trim().isEmpty) {
                              update(() => error = '请填写服务器地址和用户名');
                              return;
                            }
                            update(() {
                              busy = true;
                              error = '';
                            });
                            try {
                              final entry = await EmbyLibrary.login(
                                server,
                                username,
                                password,
                                group: group.isEmpty ? '默认分组' : group,
                                isPrivate: isPrivate,
                              );
                              if (!ctx.mounted) return;
                              await widget.storage.upsertSubscriptions([entry]);
                              if (ctx.mounted) Navigator.of(ctx).pop(true);
                            } catch (e) {
                              if (ctx.mounted)
                                update(() {
                                  busy = false;
                                  error = e.toString();
                                });
                            }
                          },
                    child: Text(busy ? '正在连接…' : '登录并添加'),
                  ),
                ],
              ),
            ),
          ),
        ) ??
        false;
  }
  void _showImportConfigDialog({
    String? initialInput,
    String? initialError,
    String initialGroup = '默认分组',
    bool initialIsPrivate = false,
  }) {
    final urlCtrl = TextEditingController(
      text: initialInput ??
          (initialIsPrivate ? '' : widget.storage.configOrigin),
    );
    final jsonCtrl = TextEditingController();
    final groupCtrl = TextEditingController(text: initialGroup);
    bool isPrivate = initialIsPrivate;
    bool submitting = false;
    String? errorText = initialError;
    final showPrivacyToggle =
        initialIsPrivate || !widget.storage.hasPrivacyConfigured;
    const presetGroups = ['默认分组', '主力影视', '超清专线', '电视直播', '动漫番剧'];
    showAppleModalSheet<void>(
      context: context,
      title: initialIsPrivate
          ? '导入隐私订阅资源'
          : '导入订阅资源（支持分组 / 批量导入）',
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          Future<void> handleImport() async {
            setModalState(() {
              submitting = true;
              errorText = null;
            });
            try {
              final urlText = urlCtrl.text.trim();
              final jsonText = jsonCtrl.text.trim();
              final selectedGroup = groupCtrl.text.trim().isEmpty
                  ? '默认分组'
                  : groupCtrl.text.trim();
              final effectivePrivate = isPrivate ||
                  selectedGroup.contains('隐私') ||
                  selectedGroup.contains('私密');
              final candidateBackup =
                  jsonText.isNotEmpty ? jsonText : urlText;
              if (CmsParser.isBackupPayload(candidateBackup)) {
                await widget.storage.importBackupJson(candidateBackup);
                if (ctx.mounted) Navigator.of(ctx).pop();
                _reloadSavedConfig();
                return;
              }
              final entries = await widget.client.resolveBatchSubscriptions(
                urlInput: urlText,
                rawTextInput: jsonText,
                defaultGroup: selectedGroup,
                isPrivate: effectivePrivate,
              );
              await widget.storage.upsertSubscriptions(entries);
              if (!initialIsPrivate) {
                _privateSessionUnlocked = false;
              }
              if (ctx.mounted) Navigator.of(ctx).pop();
              _reloadSavedConfig();
              if (effectivePrivate && !widget.storage.hasPrivacyPassword) {
                _showSetPrivacyPasswordDialog(
                  title: '设置隐私访问密码',
                  subtitle: '请为隐私分组设置访问密码：',
                );
              }
            } catch (e) {
              setModalState(() {
                submitting = false;
                errorText = '导入失败：$e';
              });
            }
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                CupertinoButton(padding: EdgeInsets.zero, child: const Text('连接 Emby 媒体库'),
                  onPressed: submitting ? null : () async {
                    final added = await _connectEmby(ctx,groupCtrl.text.trim(),isPrivate);
                    if (added && ctx.mounted) {
                      Navigator.of(ctx).pop();
                      _reloadSavedConfig();
                    }
                  }),
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: submitting ? null : () async {
                    try {
                      final picked = await FilePicker.platform.pickFiles(type: FileType.any, withData: false);
                      final entry = picked?.files.single;
                      if (entry == null || entry.path == null || !ctx.mounted) return;
                      final file = File(entry.path!);
                      if (await file.length() > CmsClient.maxResponseBytes) throw const FormatException('文件超过 6 MB');
                      final body = CmsClient.readSubscriptionFile(await file.readAsBytes(), entry.name);
                      if (!ctx.mounted) return;
                      setModalState(() { jsonCtrl.text = body; urlCtrl.clear(); errorText = null; });
                    } catch (e) {
                      if (ctx.mounted) setModalState(() => errorText = '读取本地订阅失败：$e');
                    }
                  },
                  child: const Text('选择本地订阅或 ZIP 配置包'),
                ),
                // 1. Group Selector
                const Text(
                  '订阅分组（可选择预设或直接输入自定义分组名）',
                  style: TextStyle(
                    color: AppleColors.labelSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final g in presetGroups)
                      _buildMiniFilterChip(
                        label: g,
                        selected: groupCtrl.text.trim() == g,
                        onTap: () => setModalState(() => groupCtrl.text = g),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                CupertinoTextField(
                  controller: groupCtrl,
                  placeholder: '输入自定义分组名称（如：主力4K、少儿专区）',
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  style: const TextStyle(
                    color: AppleColors.labelPrimary,
                    fontSize: 13.5,
                  ),
                  placeholderStyle: const TextStyle(
                    color: AppleColors.labelTertiary,
                    fontSize: 13,
                  ),
                  onChanged: (_) => setModalState(() {}),
                  decoration: BoxDecoration(
                    color: AppleColors.groupedSecondary,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: AppleColors.glassBorder,
                      width: 0.5,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                if (showPrivacyToggle) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: AppleColors.groupedSecondary,
                      borderRadius: BorderRadius.circular(11),
                      border: Border.all(
                        color: AppleColors.glassBorder,
                        width: 0.5,
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          CupertinoIcons.lock_shield_fill,
                          color: AppleColors.systemPurple,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            '设为隐私分组',
                            style: TextStyle(
                              color: AppleColors.labelPrimary,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        CupertinoSwitch(
                          value: isPrivate,
                          activeTrackColor: AppleColors.systemPurple,
                          onChanged: (v) => setModalState(() {
                            isPrivate = v;
                            if (v && groupCtrl.text.trim() == '默认分组') {
                              groupCtrl.text = '隐私分组';
                            } else if (!v &&
                                groupCtrl.text.trim() == '隐私分组') {
                              groupCtrl.text = '默认分组';
                            }
                          }),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                ],
                // 3. Multi-subscription URLs input
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '订阅地址（支持多行批量导入 · 兼容 VOD / M3U / JSON / 多仓）',
                        style: TextStyle(
                          color: AppleColors.labelSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      minSize: 26,
                      onPressed: () async {
                        final data =
                            await Clipboard.getData(Clipboard.kTextPlain);
                        final clip = (data?.text ?? '').trim();
                        if (clip.isEmpty) return;
                        if (clip.startsWith('{') ||
                            clip.startsWith('[') ||
                            clip.startsWith('#EXTM3U') ||
                            clip.startsWith('<')) {
                          jsonCtrl.text = clip;
                        } else {
                          urlCtrl.text = clip;
                        }
                        setModalState(() => errorText = null);
                      },
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            CupertinoIcons.doc_on_clipboard,
                            size: 14,
                            color: AppleColors.systemBlue,
                          ),
                          SizedBox(width: 4),
                          Text(
                            '粘贴剪贴板',
                            style: TextStyle(
                              color: AppleColors.systemBlue,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                CupertinoTextField(
                  controller: urlCtrl,
                  placeholder:
                      '每行一个订阅地址（如：https://config.example/config.json）\n支持 JSON单仓/多仓、MacCMS VOD接口、M3U/M3U8/TXT 直播与点播',
                  maxLines: 4,
                  minLines: 2,
                  autocorrect: false,
                  enableSuggestions: false,
                  smartQuotesType: SmartQuotesType.disabled,
                  smartDashesType: SmartDashesType.disabled,
                  keyboardType: TextInputType.multiline,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  style: const TextStyle(
                    color: AppleColors.labelPrimary,
                    fontSize: 13.5,
                  ),
                  placeholderStyle: const TextStyle(
                    color: AppleColors.labelTertiary,
                    fontSize: 12.5,
                  ),
                  decoration: BoxDecoration(
                    color: AppleColors.groupedSecondary,
                    borderRadius: BorderRadius.circular(11),
                    border: Border.all(
                      color: AppleColors.glassBorder,
                      width: 0.5,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  '或粘贴 JSON / M3U / TXT / JS / PY 配置内容（脚本是否可用取决于运行环境）',
                  style: TextStyle(
                    color: AppleColors.labelSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                CupertinoTextField(
                  controller: jsonCtrl,
                  placeholder:
                      '{"sites": [...]} 或 #EXTM3U 播放列表 或 频道名,https://live.example/tv.m3u8',
                  maxLines: 4,
                  minLines: 2,
                  autocorrect: false,
                  enableSuggestions: false,
                  smartQuotesType: SmartQuotesType.disabled,
                  smartDashesType: SmartDashesType.disabled,
                  padding: const EdgeInsets.all(12),
                  style: const TextStyle(
                    color: AppleColors.labelPrimary,
                    fontSize: 13,
                  ),
                  placeholderStyle: const TextStyle(
                    color: AppleColors.labelTertiary,
                    fontSize: 12.5,
                  ),
                  decoration: BoxDecoration(
                    color: AppleColors.groupedSecondary,
                    borderRadius: BorderRadius.circular(11),
                    border: Border.all(
                      color: AppleColors.glassBorder,
                      width: 0.5,
                    ),
                  ),
                ),
                if (errorText != null) ...[
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0x26FF453A),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: const Color(0x66FF453A),
                        width: 0.5,
                      ),
                    ),
                    child: Text(
                      errorText!,
                      style: const TextStyle(
                        color: AppleColors.systemRed,
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: submitting
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.symmetric(vertical: 10),
                            child: CupertinoActivityIndicator(radius: 12),
                          ),
                        )
                      : AppleCapsuleButton(
                          label: isPrivate ? '保存至隐私隐藏列表' : '导入并启用订阅',
                          icon: isPrivate
                              ? CupertinoIcons.lock_fill
                              : CupertinoIcons.checkmark_circle_fill,
                          primary: true,
                          onPressed: handleImport,
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
  void _showBackupRestoreDialog() {
    final ctrl = TextEditingController(text: widget.storage.exportBackupJson());
    String? errorText;
    showAppleModalSheet<void>(
      context: context,
      title: '跨平台备份导出 / 恢复',
      trailingAction: CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        minSize: 28,
        onPressed: () {
          Clipboard.setData(ClipboardData(text: ctrl.text));
          _showAppleNotice('已复制备份', '备份 JSON 已复制到剪贴板，可发送至其他设备恢复。');
        },
        child: const Text(
          '复制导出',
          style: TextStyle(color: AppleColors.systemBlue, fontSize: 14),
        ),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '与 Android 电视/手机端 MarcoMovie-1 备份格式双向兼容：',
                style: TextStyle(
                  color: AppleColors.labelSecondary,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 10),
              CupertinoTextField(
                controller: ctrl,
                maxLines: 9,
                minLines: 6,
                autocorrect: false,
                enableSuggestions: false,
                smartQuotesType: SmartQuotesType.disabled,
                smartDashesType: SmartDashesType.disabled,
                padding: const EdgeInsets.all(12),
                style: const TextStyle(
                  color: AppleColors.labelPrimary,
                  fontSize: 12,
                ),
                decoration: BoxDecoration(
                  color: AppleColors.groupedSecondary,
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(
                    color: AppleColors.glassBorder,
                    width: 0.5,
                  ),
                ),
              ),
              if (errorText != null) ...[
                const SizedBox(height: 12),
                Text(
                  errorText!,
                  style: const TextStyle(
                    color: AppleColors.systemRed,
                    fontSize: 13,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: AppleCapsuleButton(
                  label: '从此备份文本恢复',
                  icon: CupertinoIcons.arrow_counterclockwise,
                  primary: true,
                  onPressed: () async {
                    try {
                      await widget.storage.importBackupJson(ctrl.text);
                      if (ctx.mounted) Navigator.of(ctx).pop();
                      _reloadSavedConfig();
                    } catch (e) {
                      setModalState(() => errorText = '恢复备份失败：$e');
                    }
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// iOS-style left-swipe row that reveals a red "删除" action button on the right,
/// and also supports full swipe or tapping the red delete button to remove a single watch history item.
class _SwipeToDeleteHistoryTile extends StatefulWidget {
  final WatchHistoryEntry entry;
  final String? posterUrl;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _SwipeToDeleteHistoryTile({
    super.key,
    required this.entry,
    this.posterUrl,
    required this.onTap,
    required this.onDelete,
  });

  @override
  State<_SwipeToDeleteHistoryTile> createState() =>
      _SwipeToDeleteHistoryTileState();
}

class _SwipeToDeleteHistoryTileState extends State<_SwipeToDeleteHistoryTile> {
  static const double _actionWidth = 86.0;
  double _dragOffset = 0.0;
  bool _dragging = false;

  void _handleDragStart(DragStartDetails _) {
    setState(() => _dragging = true);
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    final next = (_dragOffset + details.delta.dx).clamp(-150.0, 0.0);
    setState(() => _dragOffset = next);
  }

  void _handleDragEnd(DragEndDetails details) {
    final vx = details.primaryVelocity ?? 0.0;
    if (_dragOffset <= -125.0 || vx < -950.0) {
      HapticFeedback.mediumImpact();
      setState(() {
        _dragging = false;
        _dragOffset = 0.0;
      });
      widget.onDelete();
      return;
    }
    final shouldOpen = _dragOffset < -(_actionWidth * 0.42) || vx < -280.0;
    setState(() {
      _dragging = false;
      _dragOffset = shouldOpen ? -_actionWidth : 0.0;
    });
  }

  void _closeIfOpen() {
    if (_dragOffset != 0.0) {
      setState(() => _dragOffset = 0.0);
    }
  }

  Widget _buildFallbackPosterPlaceholder() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF26262C), Color(0xFF17171B)],
        ),
      ),
      alignment: Alignment.center,
      child: const Icon(
        CupertinoIcons.film,
        color: AppleColors.labelTertiary,
        size: 22,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.entry;
    final effectivePoster = (widget.posterUrl ?? h.poster).trim();
    final pct = (h.progressFraction * 100).round();
    final epLabel = h.episode.isEmpty ? '第 ${h.index + 1} 集' : h.episode;
    final revealProgress = (-_dragOffset / _actionWidth).clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: _handleDragStart,
        onHorizontalDragUpdate: _handleDragUpdate,
        onHorizontalDragEnd: _handleDragEnd,
        child: Stack(
          children: [
            Positioned.fill(
              child: Align(
                alignment: Alignment.centerRight,
                child: Opacity(
                  opacity: revealProgress,
                  child: GestureDetector(
                    onTap: () {
                      HapticFeedback.mediumImpact();
                      setState(() => _dragOffset = 0.0);
                      widget.onDelete();
                    },
                    child: Container(
                      width: _actionWidth + 16,
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 18),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [
                            Color(0xFFE0352B),
                            Color(0xFFFF453A),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            CupertinoIcons.trash_fill,
                            color: Colors.white,
                            size: 18,
                          ),
                          SizedBox(height: 3),
                          Text(
                            '删除',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            AnimatedContainer(
              duration: _dragging
                  ? Duration.zero
                  : const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              transform: Matrix4.translationValues(_dragOffset, 0, 0),
              child: Listener(
                onPointerDown: (_) {
                  if (_dragOffset <= -10) {
                    _closeIfOpen();
                  }
                },
                child: ApplePressableScale(
                  pressedScale: 0.97,
                  pressedOpacity: 0.88,
                  onTap: () {
                    if (_dragOffset <= -10) {
                      _closeIfOpen();
                      return;
                    }
                    widget.onTap();
                  },
                  child: AppleSettingsGlassCard(
                    borderRadius: BorderRadius.circular(18),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 52,
                          height: 72,
                          child: AppleSmoothClipCard(
                            borderRadius: 12,
                            backgroundColor: const Color(0xFF1A1A20),
                            rimStrength: 0.85,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                PosterImage(
                                  url: effectivePoster,
                                  title: h.title,
                                  placeholder:
                                      _buildFallbackPosterPlaceholder(),
                                ),
                                Positioned(
                                  right: 4,
                                  bottom: 4,
                                  child: Container(
                                    width: 18,
                                    height: 18,
                                    decoration: BoxDecoration(
                                      color: const Color(0xB8000000),
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: const Color(0x66FFFFFF),
                                        width: 0.6,
                                      ),
                                    ),
                                    alignment: Alignment.center,
                                    child: const Icon(
                                      CupertinoIcons.play_fill,
                                      color: Colors.white,
                                      size: 9.5,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 13),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                h.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: AppleColors.labelPrimary,
                                  fontSize: 15.5,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: -0.25,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '$epLabel · 已看 $pct%',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: AppleColors.labelSecondary,
                                  fontSize: 12.5,
                                ),
                              ),
                              const SizedBox(height: 8),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(999),
                                child: LinearProgressIndicator(
                                  value: h.progressFraction > 0
                                      ? h.progressFraction
                                      : 0.12,
                                  minHeight: 3.5,
                                  backgroundColor: AppleColors.groupedTertiary,
                                  valueColor:
                                      const AlwaysStoppedAnimation<Color>(
                                    AppleColors.systemBlue,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0x260A84FF),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: const Color(0x550A84FF),
                              width: 0.6,
                            ),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '继续播放',
                                style: TextStyle(
                                  color: Color(0xFF5AC8FA),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              SizedBox(width: 3),
                              Icon(
                                CupertinoIcons.chevron_right,
                                color: Color(0xFF5AC8FA),
                                size: 12,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Full-screen iOS 27 Liquid Glass Cyber-Aurora portal animation played when entering Privacy Mode.
class _PrivacyModePortalAnimation extends StatefulWidget {
  final VoidCallback onFinished;

  const _PrivacyModePortalAnimation({
    super.key,
    required this.onFinished,
  });

  @override
  State<_PrivacyModePortalAnimation> createState() =>
      _PrivacyModePortalAnimationState();
}

class _PrivacyModePortalAnimationState
    extends State<_PrivacyModePortalAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1280),
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          widget.onFinished();
        }
      });
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        // Fade in quickly (0..0.22), hold (0.22..0.72), fade out smoothly (0.72..1.0)
        final double masterOpacity;
        if (t < 0.22) {
          masterOpacity = Curves.easeOutCubic.transform(t / 0.22);
        } else if (t < 0.72) {
          masterOpacity = 1.0;
        } else {
          masterOpacity =
              1.0 - Curves.easeInOutCubic.transform((t - 0.72) / 0.28);
        }

        final ring1Scale = 0.35 + Curves.easeOutExpo.transform(t) * 2.45;
        final ring2Scale =
            0.2 + Curves.easeOutCubic.transform((t - 0.08).clamp(0.0, 1.0)) * 1.85;
        final shieldScale = t < 0.32
            ? 0.68 + Curves.easeOutBack.transform(t / 0.32) * 0.36
            : 1.04 + (t - 0.32) * 0.14;
        final blurSigma = (26.0 * masterOpacity).clamp(0.01, 28.0);

        return Opacity(
          opacity: masterOpacity.clamp(0.0, 1.0),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
            child: Container(
              decoration: const BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(0.0, -0.08),
                  radius: 1.05,
                  colors: [
                    Color(0xEE2B124C),
                    Color(0xF2120924),
                    Color(0xF807070C),
                  ],
                  stops: [0.0, 0.52, 1.0],
                ),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Expanding Liquid Aurora Wave Ring 1
                  Transform.scale(
                    scale: ring1Scale,
                    child: Container(
                      width: 260,
                      height: 260,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: const Color(0xFFBF5AF2).withValues(
                            alpha: ((1.0 - t) * 0.65).clamp(0.0, 1.0),
                          ),
                          width: 2.2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF5E5CE6).withValues(
                              alpha: ((1.0 - t) * 0.42).clamp(0.0, 1.0),
                            ),
                            blurRadius: 42,
                            spreadRadius: 8,
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Expanding Liquid Aurora Wave Ring 2
                  Transform.scale(
                    scale: ring2Scale,
                    child: Container(
                      width: 210,
                      height: 210,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: const Color(0xFF5AC8FA).withValues(
                            alpha: ((1.0 - t) * 0.5).clamp(0.0, 1.0),
                          ),
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                  // Center Shield & Status Badge
                  Transform.scale(
                    scale: shieldScale,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 88,
                          height: 88,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                Color(0xFFBF5AF2),
                                Color(0xFF5E5CE6),
                                Color(0xFF0A84FF),
                              ],
                            ),
                            border: Border.all(
                              color: const Color(0x99FFFFFF),
                              width: 1.2,
                            ),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x88BF5AF2),
                                blurRadius: 36,
                                spreadRadius: 4,
                              ),
                            ],
                          ),
                          child: Icon(
                            t < 0.28
                                ? CupertinoIcons.lock_shield
                                : CupertinoIcons.lock_shield_fill,
                            color: Colors.white,
                            size: 42,
                          ),
                        ),
                        const SizedBox(height: 22),
                        const Text(
                          '已进入隐私专属空间',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 21,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.6,
                            decoration: TextDecoration.none,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0x28FFFFFF),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: const Color(0x45BF5AF2),
                              width: 0.7,
                            ),
                          ),
                          child: const Text(
                            '无痕播放 · 独立片源与搜索 · 数据零留存隔离',
                            style: TextStyle(
                              color: Color(0xFFE5D4FF),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.2,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
