import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'cms_parser.dart';
import 'models.dart';
import 'quark_account.dart';
import 'netdisk_session.dart';
/// Persistent preferences and backup serializer compatible with Android `Prefs.java`.
class StorageService {
  static const String keyOrigin = 'origin';
  static const String keyRawConfig = 'config_raw_json';
  static const String keySelectedSite = 'selected_site';
  static const String keyPreferredSite = 'preferred_site';
  static const String keyPreferredLine = 'preferred_line';
  static const String keyWatchHistory = 'watch_history';
  static const String keyFavorites = 'favorites';
  static const String keyPrivateFavorites = 'private_favorites';
  static const String keySearchHistory = 'global_search_history';
  static const String keyPrivateSearchHistory = 'private_search_history';
  static const String keyEpisodesDescending = 'episodes_descending';
  static const String keyPlaySpeed = 'play_speed';
  static const String keyAutoNext = 'auto_next';
  static const String keySkipIntroSec = 'skip_intro_sec';
  static const String keySkipOutroSec = 'skip_outro_sec';
  static const String keyRepeatMode = 'repeat_mode';
  static const String keyQuarkCookie = 'netdisk_quark_cookie';
  static const String keyUcCookie = 'netdisk_uc_cookie';
  static const String keyBaiduCookie = 'netdisk_baidu_cookie';
  static const String keyAliToken = 'netdisk_ali_token';
  static const String keyDriveOrder = 'netdisk_drive_order';
  static const String keyDepots = 'saved_depots';
  static const String keyActiveDepotName = 'active_depot_name';
  static const String keySubscriptions = 'saved_subscriptions';
  static const String keyPrivacyPassword = 'privacy_password';
  static const String keyWallpaperPreset = 'wallpaper_preset';
  static const String keyCustomWallpaperUrl = 'custom_wallpaper_url';
  static const String keyAmbientGlow = 'ambient_glow_enabled';
  static const String keyGlassBlurLevel = 'glass_blur_level';
  static const String keyGlassBlurStrength = 'glass_blur_strength';
  static const String keyGridDensity = 'grid_density';
  static const String keyShowHeroBanner = 'show_hero_banner';
  static const String keyShowContinueWatching = 'show_continue_watching';
  static const String keyCardSubtitleMode = 'card_subtitle_mode';
  static const String keyPreferredQuality = 'preferred_quality';
  static const String keyDefaultAspectMode = 'default_aspect_mode';
  static const String keyPlayerKernel = 'player_kernel';
  final SharedPreferences _prefs;
  static final Expando<QuarkAccountProvider> _quarkProviders = Expando();
  QuarkAccountProvider get quarkAccounts => _quarkProviders[_prefs] ??=
      QuarkAccountProvider(
        readCredential: () => getNetdiskCred('quark'),
        writeCredential: (value) async { await _prefs.setString(keyQuarkCookie, value); },
      );
  Future<void> _subscriptionQueue = Future<void>.value();
  StorageService(this._prefs);
  Future<T> _editSubscriptions<T>(Future<T> Function() edit) {
    final next = _subscriptionQueue.then((_) => edit());
    _subscriptionQueue = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }
  static Future<StorageService> init() async {
    final prefs = await SharedPreferences.getInstance();
    return StorageService(prefs);
  }
  String get configOrigin => _prefs.getString(keyOrigin) ?? '';
  String get rawConfig => _prefs.getString(keyRawConfig) ?? '';
  String get selectedSiteKey => _prefs.getString(keySelectedSite) ?? '';
  String get activeDepotName => _prefs.getString(keyActiveDepotName) ?? '';
  bool get episodesDescending => _prefs.getBool(keyEpisodesDescending) ?? false;
  double get playSpeed =>
      (_prefs.getDouble(keyPlaySpeed) ?? 1.0).clamp(0.5, 2.0);
  bool get autoNext => _prefs.getBool(keyAutoNext) ?? true;
  int get skipIntroSec => (_prefs.getInt(keySkipIntroSec) ?? 0).clamp(0, 600);
  int get skipOutroSec => (_prefs.getInt(keySkipOutroSec) ?? 0).clamp(0, 600);
  String get repeatMode => _prefs.getString(keyRepeatMode) ?? 'off';
  String get wallpaperPreset =>
      _prefs.getString(keyWallpaperPreset) ?? 'obsidian';
  String get customWallpaperUrl =>
      _prefs.getString(keyCustomWallpaperUrl) ?? '';
  bool get ambientGlowEnabled => _prefs.getBool(keyAmbientGlow) ?? true;
  String get glassBlurLevel =>
      _prefs.getString(keyGlassBlurLevel) ?? 'standard';
  double get glassBlurStrength {
    final saved = _prefs.getDouble(keyGlassBlurStrength);
    if (saved != null) return saved.clamp(0.0, 1.0);
    return switch (glassBlurLevel) {
      'solid' => 0.0,
      'light' => 0.35,
      'deep' => 1.0,
      _ => 0.68,
    };
  }
  String get gridDensity => _prefs.getString(keyGridDensity) ?? 'standard';
  bool get showHeroBanner => _prefs.getBool(keyShowHeroBanner) ?? true;
  bool get showContinueWatching =>
      _prefs.getBool(keyShowContinueWatching) ?? true;
  String get cardSubtitleMode =>
      _prefs.getString(keyCardSubtitleMode) ?? 'remarks';
  String get preferredQuality =>
      _prefs.getString(keyPreferredQuality) ?? '4k_netdisk';
  String get defaultAspectMode =>
      _prefs.getString(keyDefaultAspectMode) ?? 'contain';
  String get playerKernel =>
      _prefs.getString(keyPlayerKernel) ?? 'exo';
  String get quarkCookie => _prefs.getString(keyQuarkCookie) ?? '';
  String get ucCookie => _prefs.getString(keyUcCookie) ?? '';
  String get baiduCookie => _prefs.getString(keyBaiduCookie) ?? '';
  String get aliToken => _prefs.getString(keyAliToken) ?? '';
  List<String> get driveOrder {
    const defaults = ['quark', 'uc', 'baidu', 'ali'];
    final raw = _prefs.getStringList(keyDriveOrder);
    if (raw == null || raw.isEmpty) return defaults;
    final out = <String>[
      for (final d in raw)
        if (defaults.contains(d)) d,
    ];
    for (final d in defaults) {
      if (!out.contains(d)) out.add(d);
    }
    return out;
  }
  List<CmsDepot> getSavedDepots() {
    final raw = _prefs.getString(keyDepots) ?? '[]';
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return list
          .whereType<Map>()
          .map((m) => CmsDepot.fromJson(Map<String, dynamic>.from(m)))
          .where((d) => d.url.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }
  String get privacyPassword => _prefs.getString(keyPrivacyPassword) ?? '';
  bool get hasPrivacyPassword => privacyPassword.trim().isNotEmpty;
  bool get hasPrivacyConfigured =>
      hasPrivacyPassword ||
      getSubscriptions().any((s) => s.isEffectivelyPrivate);
  bool verifyPrivacyPassword(String input) =>
      hasPrivacyPassword && input.trim() == privacyPassword.trim();
  Future<void> setPrivacyPassword(String password) async {
    await _prefs.setString(keyPrivacyPassword, password.trim());
  }

  List<SubscriptionEntry> getSubscriptions() {
    final raw = _prefs.getString(keySubscriptions) ?? '[]';
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return list
          .whereType<Map>()
          .map((m) => SubscriptionEntry.fromJson(Map<String, dynamic>.from(m)))
          .where((s) => s.id.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  List<String> getSubscriptionGroups({bool includePrivate = false}) {
    final groups = <String>['默认分组'];
    for (final s in getSubscriptions()) {
      if (!includePrivate && s.isEffectivelyPrivate) continue;
      final g = s.group.trim();
      if (g.isNotEmpty && !groups.contains(g)) {
        groups.add(g);
      }
    }
    return groups;
  }

  Future<void> saveSubscriptions(List<SubscriptionEntry> subs) async {
    try {
      final saved = await _prefs.setString(
        keySubscriptions,
        jsonEncode(subs.map((s) => s.toJson()).toList()),
      );
      if (!saved) throw StateError('订阅变更未能保存，请重试');
    } catch (_) {
      // The plugin updates its cache before the platform write completes.
      // Re-read disk so a failed write does not look like a successful deletion.
      await _prefs.reload();
      rethrow;
    }
  }

  Future<CmsConfig?> upsertSubscriptions(
    List<SubscriptionEntry> incoming, {
    List<CmsDepot>? depots,
    String? activeDepotName,
  }) => _editSubscriptions(() => _upsertSubscriptions(incoming,
      depots: depots, activeDepotName: activeDepotName));

  Future<CmsConfig?> _upsertSubscriptions(
    List<SubscriptionEntry> incoming, {
    List<CmsDepot>? depots,
    String? activeDepotName,
  }) async {
    if (incoming.isEmpty) return loadSavedConfig();
    final current = getSubscriptions().toList();
    // Migrate legacy single config into subscriptions list if not yet present
    if (!_prefs.containsKey(keySubscriptions) && rawConfig.trim().isNotEmpty) {
      try {
        final legacyParsed = CmsParser.parseConfig(
          rawConfig,
          origin: configOrigin,
        );
        final fmt = CmsParser.detectSubscriptionFormat(
          rawConfig,
          origin: configOrigin,
        );
        current.add(
          SubscriptionEntry(
            id: 'legacy_primary',
            name: this.activeDepotName.isNotEmpty
                ? this.activeDepotName
                : (configOrigin.isNotEmpty
                    ? (Uri.tryParse(configOrigin)?.host ?? '默认仓库')
                    : '默认配置'),
            url: configOrigin,
            group: '默认分组',
            format: legacyParsed.depots.isNotEmpty ? '多仓' : fmt,
            isPrivate: false,
            enabled: true,
            rawContent: rawConfig,
            siteCount: legacyParsed.supportedSites.length,
            liveCount: legacyParsed.lives.length,
            updatedAt: DateTime.now().millisecondsSinceEpoch - 1000,
          ),
        );
      } catch (_) {}
    }
    _ownLegacyDepots(current);
    for (var index = 0; index < incoming.length; index++) {
      final original = incoming[index];
      final entry = index == 0 ? original.copyWith(
        depots: depots ?? original.depots,
        activeDepotName: activeDepotName ?? original.activeDepotName,
      ) : original;
      final existingIdx = current.indexWhere(
        (s) =>
            s.id == entry.id ||
            (s.group == entry.group && s.isEffectivelyPrivate == entry.isEffectivelyPrivate &&
              (entry.warehouseUrl.isNotEmpty ? s.warehouseUrl == entry.warehouseUrl :
                (s.warehouseUrl.isEmpty && entry.url.isNotEmpty && s.url == entry.url))),
      );
      if (existingIdx >= 0) {
        current[existingIdx] = entry.copyWith(id: current[existingIdx].id);
      } else {
        current.add(entry);
      }
    }
    await saveSubscriptions(current);

    final primary = incoming.first;
    if (primary.rawContent.isNotEmpty && !primary.isEffectivelyPrivate) {
      await _prefs.setString(keyRawConfig, primary.rawContent);
      await _prefs.setString(keyOrigin, primary.url);
    }
    // Directories now belong to registry entries, including private subscriptions.
    await _prefs.setString(keyDepots, '[]');
    if (!primary.isEffectivelyPrivate) {
      await _prefs.setString(keyActiveDepotName, activeDepotName ?? primary.activeDepotName);
    }
    final merged = loadSavedConfig();
    if (merged != null &&
        merged.publicSupportedSites.isNotEmpty &&
        !merged.supportedSites.any((s) => s.key == selectedSiteKey)) {
      await _prefs.setString(
        keySelectedSite,
        merged.publicSupportedSites.first.key,
      );
    }
    return merged;
  }

  Future<CmsConfig?> removeSubscription(String id) =>
      _editSubscriptions(() => _removeSubscription(id));

  Future<CmsConfig?> _removeSubscription(String id) async {
    final current = getSubscriptions();
    final removed = current.where((s) => s.id == id).toList();
    if (removed.isEmpty) return loadSavedConfig();
    final next = current.where((s) {
      if (s.id == id) return false;
      // Older first-time pasted imports created these two IDs from the same
      // payload. Remove that known accidental twin, not independent subscriptions.
      if (removed.isNotEmpty &&
          ((id == 'legacy_primary' && s.id == 'sub_primary') ||
           (id == 'sub_primary' && s.id == 'legacy_primary'))) {
        final old = removed.first;
        if (s.url.isEmpty && old.url.isEmpty && s.rawContent == old.rawContent &&
            s.group == old.group && s.isEffectivelyPrivate == old.isEffectivelyPrivate) {
          return false;
        }
      }
      return true;
    }).toList();
    // Move old global warehouse directories to their surviving owner before
    // clearing the compatibility mirror. Never transfer a removed owner's dirs.
    _ownLegacyDepots(next);
    // The persisted registry, including [], is authoritative before legacy cleanup.
    await saveSubscriptions(next);
    final public = next.where((s) => !s.isEffectivelyPrivate).toList();
    await _prefs.setString(keyRawConfig, public.isEmpty ? '' : public.first.rawContent);
    await _prefs.setString(keyOrigin, public.isEmpty ? '' : public.first.url);
    await _prefs.setString(keyDepots, '[]');
    await _prefs.setString(keyActiveDepotName, public.isEmpty ? '' : public.first.activeDepotName);
    final config = loadSavedConfig();
    final sites = config?.publicSupportedSites ?? const <CmsSite>[];
    if (!sites.any((s) => s.key == selectedSiteKey)) {
      await _prefs.setString(keySelectedSite, sites.isEmpty ? '' : sites.first.key);
    }
    if (!sites.any((s) => s.key == (_prefs.getString(keyPreferredSite) ?? ''))) {
      await _prefs.remove(keyPreferredSite);
    }
    return config;
  }

  void _ownLegacyDepots(List<SubscriptionEntry> subscriptions) {
    final legacyOwner = subscriptions.indexWhere((s) => !s.isEffectivelyPrivate &&
        s.url == configOrigin && (s.format == '多仓' || s.id == 'legacy_primary'));
    if (legacyOwner >= 0) {
      final owner = subscriptions[legacyOwner];
      final dirs = <String, CmsDepot>{
        for (final d in [...getSavedDepots(), ...owner.depots]) d.url: d,
      };
      subscriptions[legacyOwner] = owner.copyWith(depots: dirs.values.toList(),
        activeDepotName: owner.activeDepotName.isNotEmpty ? owner.activeDepotName : activeDepotName);
    }
  }

  Future<CmsConfig?> toggleSubscriptionPrivacy(
    String id,
    bool isPrivate,
  ) => _editSubscriptions(() async {
    final next = [
      for (final s in getSubscriptions())
        if (s.id == id) s.copyWith(isPrivate: isPrivate) else s,
    ];
    await saveSubscriptions(next);
    return loadSavedConfig();
  });

  Future<CmsConfig?> toggleSubscriptionEnabled(String id, bool enabled) => _editSubscriptions(() async {
    final next = [
      for (final s in getSubscriptions())
        if (s.id == id) s.copyWith(enabled: enabled) else s,
    ];
    await saveSubscriptions(next);
    return loadSavedConfig();
  });

  Future<CmsConfig?> updateSubscriptionGroup(String id, String group) => _editSubscriptions(() async {
    final cleanGroup = group.trim().isEmpty ? '默认分组' : group.trim();
    final next = [
      for (final s in getSubscriptions())
        if (s.id == id) s.copyWith(group: cleanGroup) else s,
    ];
    await saveSubscriptions(next);
    return loadSavedConfig();
  });

  String _siteIdentity(CmsSite s) => jsonEncode([s.subscriptionId, s.sourceKey, s.api]);
  Map<String, String> _pickerIdentities(Iterable<CmsSite> sites) {
    final identities = <String, String>{};
    for (final site in sites) {
      final canonical = _siteIdentity(site);
      identities[canonical] = canonical;
      identities[jsonEncode([site.subscriptionId, site.key, site.api])] = canonical;
      identities[jsonEncode([site.subscriptionId, '${site.sourceKey}_${site.subscriptionId}', site.api])] = canonical;
    }
    return identities;
  }
  static const _siteOrder = 'picker_site_order';
  static const _removedSites = 'picker_removed_sites';
  static const _siteAliases = 'site_key_aliases';
  Map<String, String> _savedAliases() {
    try { return Map<String, String>.from(jsonDecode(_prefs.getString(_siteAliases) ?? '{}')); } catch (_) { return {}; }
  }

  Future<void> savePickerEdits(List<CmsSite> ordered, List<CmsSite> removed) => _editSubscriptions(() async {
    final oldOrder = _prefs.getStringList(_siteOrder) ?? [];
    final ids = ordered.map(_siteIdentity).toList();
    final hidden = {...?_prefs.getStringList(_removedSites), ...removed.map(_siteIdentity)};
    try {
      final orderSaved = await _prefs.setStringList(_siteOrder, [...ids, ...oldOrder.where((id) => !ids.contains(id))]);
      if (!orderSaved) throw StateError('线路顺序未能保存，请重试');
      final removalSaved = await _prefs.setStringList(_removedSites, hidden.toList());
      if (!removalSaved) throw StateError('线路删除未能保存，请重试');
    } catch (_) {
      await _prefs.reload();
      rethrow;
    }
  });

  CmsConfig? loadSavedConfig() {
    final config = _loadImportedConfig();
    if (config == null) return null;
    final identities = _pickerIdentities(config.sites);
    final hidden = (_prefs.getStringList(_removedSites) ?? []).map((id) => identities[id] ?? id).toSet();
    final byId = {for (final s in config.sites) if (!hidden.contains(_siteIdentity(s))) _siteIdentity(s): s};
    final sites = <CmsSite>[];
    for (final id in _prefs.getStringList(_siteOrder) ?? const <String>[]) {
      final site = byId.remove(identities[id] ?? id);
      if (site != null) sites.add(site);
    }
    return CmsConfig(sites: [...sites, ...byId.values], lives: config.lives,
        depots: config.depots, parses: config.parses, spider: config.spider);
  }

  CmsConfig? _loadImportedConfig() {
    final subs = getSubscriptions().where((s) => s.enabled).toList();
    final savedDepots = getSavedDepots();
    final aliases = _savedAliases();
    if (_prefs.containsKey(keySubscriptions)) {
      if (getSubscriptions().isEmpty) return null;
      final mergedSites = <CmsSite>[];
      final mergedLives = <LiveSource>[];
      final mergedDepots = <CmsDepot>[];
      final mergedParses = <CmsParse>[];
      final seenDepotUrls = <String>{};
      final seenParseUrls = <String>{};
      final legacyOwners = subs.where((s) => !s.isEffectivelyPrivate &&
          s.url == configOrigin && (s.format == '多仓' || s.id == 'legacy_primary'));
      if (legacyOwners.isNotEmpty) {
        final owner = legacyOwners.first;
        for (final d in savedDepots) {
          if (seenDepotUrls.add('${owner.id}|${d.url}')) {
            mergedDepots.add(CmsDepot(name: d.name, url: d.url, subscriptionId: owner.id));
          }
        }
      }
      final seenSiteKeys = <String>{};
      String spider = '';

      for (final sub in subs) {
        if (sub.rawContent.trim().isEmpty) continue;
        try {
          final parsed = CmsParser.parseConfig(
            sub.rawContent,
            origin: sub.url,
            defaultGroup: sub.group,
            isPrivate: sub.isEffectivelyPrivate,
            subscriptionId: sub.id,
            defaultName: sub.name,
          );
          if (spider.isEmpty && parsed.spider.isNotEmpty) {
            spider = parsed.spider;
          }
          for (final p in parsed.parses) {
            if (seenParseUrls.add(p.url) && mergedParses.length < 100) {
              mergedParses.add(p);
            }
          }
          for (final d in [...sub.depots, ...parsed.depots]) {
            if (!sub.isEffectivelyPrivate && seenDepotUrls.add('${sub.id}|${d.url}')) {
              mergedDepots.add(CmsDepot(name: d.name, url: d.url, subscriptionId: sub.id));
            }
          }
          for (final site in parsed.sites) {
            var uniqueKey = aliases[jsonEncode([sub.id, site.key, site.api])] ?? site.key;
            if (!seenSiteKeys.add(uniqueKey)) {
              uniqueKey = '${site.key}_${sub.id}';
              seenSiteKeys.add(uniqueKey);
            }
            mergedSites.add(
              site.copyWith(
                key: uniqueKey,
                group: site.group.isEmpty ? sub.group : site.group,
                isPrivate: site.isEffectivelyPrivate || sub.isEffectivelyPrivate,
                subscriptionId: sub.id,
              ),
            );
          }
          for (final live in parsed.lives) {
            mergedLives.add(
              live.copyWith(
                group: live.group.isEmpty ? sub.group : live.group,
                isPrivate: live.isEffectivelyPrivate || sub.isEffectivelyPrivate,
                subscriptionId: sub.id,
              ),
            );
          }
        } catch (_) {}
      }
      {
        return CmsConfig(
          sites: mergedSites,
          lives: mergedLives,
          depots: mergedDepots,
          parses: mergedParses,
          spider: spider,
        );
      }
    }

    final raw = rawConfig;
    if (raw.trim().isEmpty) return null;
    try {
      final parsed = CmsParser.parseConfig(raw, origin: configOrigin);
      if (parsed.depots.isEmpty && savedDepots.isNotEmpty) {
        return CmsConfig(
          sites: parsed.sites,
          lives: parsed.lives,
          depots: savedDepots,
          parses: parsed.parses,
          spider: parsed.spider,
        );
      }
      return parsed;
    } catch (_) {
      return null;
    }
  }
  Future<CmsConfig> saveConfig(
    String rawJson, {
    String origin = '',
    List<CmsDepot>? depots,
    String? activeDepotName,
    String group = '默认分组',
    bool isPrivate = false,
    String customName = '',
  }) async {
    final parsed = CmsParser.parseConfig(
      rawJson,
      origin: origin,
      defaultGroup: group,
      isPrivate: isPrivate,
      defaultName: customName,
    );
    // upsert migrates only pre-existing legacy data, before storing this import.
    final effectiveDepots = depots ?? parsed.depots;
    final fmt = CmsParser.detectSubscriptionFormat(rawJson, origin: origin);
    final entryName = customName.trim().isNotEmpty
        ? customName.trim()
        : ((activeDepotName != null && activeDepotName.trim().isNotEmpty)
            ? activeDepotName.trim()
            : (parsed.sites.length == 1
                ? parsed.sites.first.name
                : (origin.trim().isNotEmpty
                    ? (Uri.tryParse(origin.trim())?.host ?? '订阅资源')
                    : '$fmt 订阅')));
    await upsertSubscriptions([
      SubscriptionEntry(
        id: origin.trim().isNotEmpty
            ? 'sub_${origin.trim().hashCode.abs()}'
            : 'sub_primary',
        name: entryName,
        url: origin.trim(),
        group: group.trim().isEmpty ? '默认分组' : group.trim(),
        format: effectiveDepots.isNotEmpty ? '多仓' : fmt,
        isPrivate: isPrivate,
        enabled: true,
        rawContent: rawJson,
        depots: effectiveDepots,
        activeDepotName: activeDepotName ?? '',
        siteCount: parsed.supportedSites.length,
        liveCount: parsed.lives.length,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    ]);
    final merged = loadSavedConfig() ??
        CmsConfig(
          sites: parsed.sites,
          lives: parsed.lives,
          depots: effectiveDepots,
          parses: parsed.parses,
          spider: parsed.spider,
        );
    final visibleSites =
        isPrivate ? merged.supportedSites : merged.publicSupportedSites;
    if (visibleSites.isNotEmpty &&
        !visibleSites.any((s) => s.key == selectedSiteKey)) {
      await _prefs.setString(keySelectedSite, visibleSites.first.key);
    } else if (merged.supportedSites.isEmpty && merged.sites.isNotEmpty) {
      await _prefs.setString(keySelectedSite, merged.sites.first.key);
    }
    return merged;
  }
  String get preferredSiteKey {
    final key = _prefs.getString(keyPreferredSite) ?? '';
    return (loadSavedConfig()?.publicSupportedSites ?? const <CmsSite>[])
        .any((s) => s.key == key) ? key : '';
  }
  String get preferredLineName => _prefs.getString(keyPreferredLine) ?? '';
  Future<void> setPreferredSiteKey(String key) async {
    if (key.isNotEmpty && !(loadSavedConfig()?.publicSupportedSites ?? const <CmsSite>[])
        .any((s) => s.key == key)) throw const FormatException('请选择已启用的公开片源');
    await _prefs.setString(keyPreferredSite, key);
  }
  Future<void> setPreferredLineName(String name) => _prefs.setString(keyPreferredLine, name);
  List<CmsSite> prioritizeSites(Iterable<CmsSite> sites) {
    final all = sites.toList();
    final key = preferredSiteKey;
    return [...all.where((s) => s.key == key), ...all.where((s) => s.key != key)];
  }

  Future<void> setSelectedSiteKey(String key) async {
    await _prefs.setString(keySelectedSite, key);
  }
  Future<void> setEpisodesDescending(bool value) async {
    await _prefs.setBool(keyEpisodesDescending, value);
  }
  Future<void> setPlaySpeed(double speed) async {
    await _prefs.setDouble(keyPlaySpeed, speed.clamp(0.5, 2.0));
  }
  Future<void> setAutoNext(bool value) async {
    await _prefs.setBool(keyAutoNext, value);
  }
  Future<void> setSkipIntroSec(int seconds) async {
    await _prefs.setInt(keySkipIntroSec, seconds.clamp(0, 600));
  }
  Future<void> setSkipOutroSec(int seconds) async {
    await _prefs.setInt(keySkipOutroSec, seconds.clamp(0, 600));
  }
  Future<void> setRepeatMode(String mode) async {
    await _prefs.setString(keyRepeatMode, mode);
  }
  Future<void> setWallpaperPreset(String preset) async {
    await _prefs.setString(keyWallpaperPreset, preset.trim());
  }
  Future<void> setCustomWallpaperUrl(String url) async {
    await _prefs.setString(keyCustomWallpaperUrl, url.trim());
  }
  Future<void> setAmbientGlowEnabled(bool enabled) async {
    await _prefs.setBool(keyAmbientGlow, enabled);
  }
  Future<void> setGlassBlurLevel(String level) async {
    final trimmed = level.trim();
    await _prefs.setString(keyGlassBlurLevel, trimmed);
    final mapped = switch (trimmed) {
      'solid' => 0.0,
      'light' => 0.35,
      'deep' => 1.0,
      _ => 0.68,
    };
    await _prefs.setDouble(keyGlassBlurStrength, mapped);
  }
  Future<void> setGlassBlurStrength(double strength) async {
    final clamped = strength.clamp(0.0, 1.0);
    await _prefs.setDouble(keyGlassBlurStrength, clamped);
    final level = clamped <= 0.05
        ? 'solid'
        : clamped < 0.50
            ? 'light'
            : clamped < 0.85
                ? 'standard'
                : 'deep';
    await _prefs.setString(keyGlassBlurLevel, level);
  }
  Future<void> setGridDensity(String density) async {
    await _prefs.setString(keyGridDensity, density.trim());
  }
  Future<void> setShowHeroBanner(bool show) async {
    await _prefs.setBool(keyShowHeroBanner, show);
  }
  Future<void> setShowContinueWatching(bool show) async {
    await _prefs.setBool(keyShowContinueWatching, show);
  }
  Future<void> setCardSubtitleMode(String mode) async {
    await _prefs.setString(keyCardSubtitleMode, mode.trim());
  }
  Future<void> setPreferredQuality(String quality) async {
    await _prefs.setString(keyPreferredQuality, quality.trim());
  }
  Future<void> setDefaultAspectMode(String mode) async {
    await _prefs.setString(keyDefaultAspectMode, mode.trim());
  }
  Future<void> setPlayerKernel(String kernel) async {
    await _prefs.setString(keyPlayerKernel, kernel.trim());
  }
  /// Selects the recommended line index from [lines] based on [preferredQuality]
  /// and the user's configured Netdisk drive order.
  int pickRecommendedLineIndex(List<CmsLine> lines) {
    final preferred = lines.indexWhere((line) => line.name == preferredLineName && line.episodes.isNotEmpty);
    if (preferred >= 0) return preferred;
    if (lines.isEmpty) return 0;
    final pref = preferredQuality;
    if (pref == 'auto') return 0;
    bool isNetdiskLine(String name) {
      final n = name.toLowerCase();
      return n.contains('4k') ||
          n.contains('原画') ||
          n.contains('夸父') ||
          n.contains('夸克') ||
          n.contains('优汐') ||
          n.contains('uc') ||
          n.contains('嘟嘟') ||
          n.contains('百度') ||
          n.contains('阿狸') ||
          n.contains('阿里');
    }
    if (pref == '4k_netdisk') {
      // First check according to driveOrder
      for (final drive in driveOrder) {
        final alias = switch (drive) {
          'quark' => '夸',
          'uc' => '优',
          'baidu' => '嘟',
          'ali' => '阿',
          _ => '',
        };
        if (alias.isNotEmpty) {
          final idx = lines.indexWhere((l) => l.name.contains(alias));
          if (idx >= 0) return idx;
        }
      }
      final idx = lines.indexWhere((l) => isNetdiskLine(l.name));
      if (idx >= 0) return idx;
    } else if (pref == '1080p_direct') {
      final idx = lines.indexWhere(
        (l) =>
            !isNetdiskLine(l.name) &&
            (l.name.contains('蓝光') ||
                l.name.contains('超清') ||
                l.name.contains('1080') ||
                l.name.contains('暴风') ||
                l.name.contains('天堂') ||
                l.name.contains('非凡') ||
                l.name.contains('量子')),
      );
      if (idx >= 0) return idx;
      final nonNetdisk = lines.indexWhere((l) => !isNetdiskLine(l.name));
      if (nonNetdisk >= 0) return nonNetdisk;
    } else if (pref == 'fast_hls') {
      final idx = lines.indexWhere((l) => !isNetdiskLine(l.name));
      if (idx >= 0) return idx;
    }
    return 0;
  }
  String getNetdiskCred(String driveKey) {
    switch (driveKey) {
      case 'quark':
        return quarkCookie;
      case 'uc':
        return ucCookie;
      case 'baidu':
        return baiduCookie;
      case 'ali':
        return aliToken;
      default:
        return '';
    }
  }
  bool isNetdiskLoggedIn(String driveKey) {
    final credential = getNetdiskCred(driveKey).trim();
    if (driveKey == 'quark') {
      return QuarkAccountSession.tryParseCredential(credential) != null;
    }
    return NetdiskSession.isUsable(driveKey, credential);
  }
  String netdiskCredential(String driveKey) {
    return getNetdiskCred(driveKey);
  }
  Future<void> setNetdiskCredential(String driveKey, String value) {
    return setNetdiskCred(driveKey, value);
  }
  Future<void> setNetdiskCred(String driveKey, String value) async {
    final trimmed = value.trim();
    switch (driveKey) {
      case 'quark':
        quarkAccounts.invalidate();
        await _prefs.setString(keyQuarkCookie, trimmed);
        break;
      case 'uc':
        await _prefs.setString(keyUcCookie, trimmed);
        break;
      case 'baidu':
        await _prefs.setString(keyBaiduCookie, trimmed);
        break;
      case 'ali':
        await _prefs.setString(keyAliToken, trimmed);
        break;
    }
  }
  Future<void> setDriveOrder(List<String> order) async {
    await _prefs.setStringList(keyDriveOrder, order);
  }
  Set<String> _privateSiteKeySet() {
    final cfg = loadSavedConfig();
    if (cfg == null) return const <String>{};
    return <String>{
      for (final s in cfg.sites)
        if (s.isEffectivelyPrivate) s.key,
    };
  }
  List<WatchHistoryEntry> getWatchHistory() {
    final raw = _prefs.getString(keyWatchHistory) ?? '[]';
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      final privKeys = _privateSiteKeySet();
      return list
          .whereType<Map>()
          .map((m) => WatchHistoryEntry.fromJson(Map<String, dynamic>.from(m)))
          .where((e) => !privKeys.contains(e.site))
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }
  Future<void> upsertWatchHistory(WatchHistoryEntry entry) async {
    if (_privateSiteKeySet().contains(entry.site)) {
      return;
    }
    final updated = CmsParser.upsertHistory(getWatchHistory(), entry);
    await _prefs.setString(
      keyWatchHistory,
      jsonEncode(updated.map((e) => e.toJson()).toList()),
    );
  }
  Future<void> removeWatchHistoryItem(String siteKey, String videoId) async {
    final targetKey = '$siteKey\n$videoId';
    final updated =
        getWatchHistory().where((e) => e.key != targetKey).toList();
    await _prefs.setString(
      keyWatchHistory,
      jsonEncode(updated.map((e) => e.toJson()).toList()),
    );
  }
  Future<void> clearWatchHistory() async {
    await _prefs.setString(keyWatchHistory, '[]');
  }
  List<FavoriteEntry> getFavorites({bool forPrivate = false}) {
    final storageKey = forPrivate ? keyPrivateFavorites : keyFavorites;
    final raw = _prefs.getString(storageKey) ?? '[]';
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      final privKeys = _privateSiteKeySet();
      return list
          .whereType<Map>()
          .map((m) => FavoriteEntry.fromJson(Map<String, dynamic>.from(m)))
          .where((f) => forPrivate ? true : !privKeys.contains(f.site))
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }
  bool isFavorite(
    String siteKey,
    String videoId, {
    bool forPrivate = false,
  }) {
    final effectivePrivate = forPrivate || _privateSiteKeySet().contains(siteKey);
    final target = '$siteKey\n$videoId';
    return getFavorites(forPrivate: effectivePrivate)
        .any((f) => f.key == target);
  }
  Future<bool> toggleFavorite(CmsSite site, CmsVideo video) async {
    final forPrivate =
        site.isEffectivelyPrivate || _privateSiteKeySet().contains(site.key);
    final storageKey = forPrivate ? keyPrivateFavorites : keyFavorites;
    final current = getFavorites(forPrivate: forPrivate).toList();
    final targetKey = '${site.key}\n${video.id}';
    final existingIdx = current.indexWhere((f) => f.key == targetKey);
    bool nowFav;
    if (existingIdx >= 0) {
      current.removeAt(existingIdx);
      nowFav = false;
    } else {
      current.insert(
        0,
        FavoriteEntry(
          site: site.key,
          id: video.id,
          title: video.title,
          poster: video.poster,
          remarks: video.remarks,
          updated: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      if (current.length > CmsParser.maxFavoriteEntries) {
        current.removeRange(CmsParser.maxFavoriteEntries, current.length);
      }
      nowFav = true;
    }
    await _prefs.setString(
      storageKey,
      jsonEncode(current.map((e) => e.toJson()).toList()),
    );
    return nowFav;
  }
  List<String> getSearchHistory({bool forPrivate = false}) {
    final storageKey = forPrivate ? keyPrivateSearchHistory : keySearchHistory;
    final raw = _prefs.getString(storageKey) ?? '[]';
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return list.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
    } catch (_) {
      return const [];
    }
  }
  Future<void> addSearchKeyword(
    String keyword, {
    bool forPrivate = false,
  }) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) return;
    final storageKey = forPrivate ? keyPrivateSearchHistory : keySearchHistory;
    final list =
        getSearchHistory(forPrivate: forPrivate).where((k) => k != trimmed).toList();
    list.insert(0, trimmed);
    if (list.length > 16) list.removeRange(16, list.length);
    await _prefs.setString(storageKey, jsonEncode(list));
  }
  Future<void> clearSearchHistory({bool forPrivate = false}) async {
    final storageKey = forPrivate ? keyPrivateSearchHistory : keySearchHistory;
    await _prefs.setString(storageKey, '[]');
  }
  /// Exports a backup JSON string compatible with both Android (`MarcoMovie-1`) and Flutter.
  String publicSupportedKey() {
    final publicSites = loadSavedConfig()?.publicSupportedSites ?? const <CmsSite>[];
    return publicSites.any((s) => s.key == selectedSiteKey) ? selectedSiteKey : '';
  }
  String _publicRawConfig(String raw, String origin) {
    if (raw.isEmpty) return raw;
    final parsed = CmsParser.parseConfig(raw, origin: origin);
    if (parsed.sites.every((s) => s.isEffectivelyPrivate) &&
        parsed.lives.every((s) => s.isEffectivelyPrivate) && parsed.depots.isEmpty) return '';
    if (!parsed.sites.any((s) => s.isEffectivelyPrivate) && !parsed.lives.any((s) => s.isEffectivelyPrivate)) return raw;
    bool privateItem(dynamic item) {
      if (item is! Map) return false;
      final flag = item['isPrivate'] ?? item['hidden'];
      final group = (item['group'] ?? '').toString();
      return flag == true || flag == 1 || flag == 'true' || flag == '1' || group.contains('隐私') || group.contains('私密');
    }
    try {
      final value = jsonDecode(CmsParser.stripJsonComments(CmsParser.unpackConfigText(raw)));
      if (value is Map) {
        if (value['api'] != null && privateItem(value)) return '{"sites":[]}';
        for (final key in ['sites', 'lives']) {
          if (value[key] is List) value[key] = (value[key] as List).where((entry) => !privateItem(entry)).toList();
          else if (value[key] is Map && privateItem(value[key])) value[key] = [];
        }
        return jsonEncode(value);
      }
    } catch (_) { /* Inline playlists have no JSON container to filter. */ }
    return jsonEncode({
      'spider': parsed.spider,
      'sites': [for (final s in parsed.sites.where((s) => !s.isEffectivelyPrivate)) {
        'key': s.key, 'name': s.name, 'api': s.api, 'type': s.type,
        'playUrl': s.playUrl, 'ext': s.rawExtension ?? s.ext, 'header': s.headers, 'group': s.group, 'searchable': s.searchable,
        if (s.pluginReference.isNotEmpty) 'jar': s.pluginReference,
      }],
      'lives': [for (final l in parsed.publicLives) {
        'name': l.name, 'url': l.url, 'header': l.headers, 'group': l.group,
        if (l.inlineContent.isNotEmpty) ...jsonDecode(l.inlineContent) as Map,
        if (l.plugin != null) ...{
          'api': l.plugin!.api, 'ext': l.plugin!.rawExtension ?? l.plugin!.ext,
          if (l.plugin!.pluginReference.isNotEmpty) 'jar': l.plugin!.pluginReference,
        },
      }],
    });
  }

  static const _appearanceStrings = [keyWallpaperPreset, keyGlassBlurLevel, keyGridDensity,
    keyCardSubtitleMode, keyPreferredQuality, keyDefaultAspectMode, keyPreferredLine];
  static const _appearanceBooleans = [keyAmbientGlow, keyShowHeroBanner, keyShowContinueWatching];

  String exportBackupJson() {
    final all = getSubscriptions();
    final public = all.where((s) => !s.isEffectivelyPrivate).map((s) => s.copyWith(rawContent: _publicRawConfig(s.rawContent, s.url))).where((s) => s.rawContent.isNotEmpty).toList();
    final primary = public.isEmpty ? null : public.first;
    final publicIds = (_loadImportedConfig()?.sites ?? const <CmsSite>[]).where((s) => !s.isEffectivelyPrivate).map(_siteIdentity).toSet();
    final identityAliases = _pickerIdentities(_loadImportedConfig()?.sites ?? const <CmsSite>[]);
    final publicSites = (_loadImportedConfig()?.sites ?? const <CmsSite>[]).where((s) => !s.isEffectivelyPrivate).toList();
    final aliases = <String, String>{};
    for (final sub in public) {
      final parsed = CmsParser.parseConfig(sub.rawContent, origin: sub.url, subscriptionId: sub.id);
      for (final site in parsed.sites) {
        final existingKey = _savedAliases()[jsonEncode([sub.id, site.key, site.api])] ?? site.key;
        final matches = publicSites.where((s) => s.subscriptionId == sub.id && s.api == site.api &&
            (s.key == existingKey || s.key == '${site.key}_${sub.id}'));
        if (matches.isNotEmpty) aliases[jsonEncode([sub.id, site.key, site.api])] = matches.first.key;
      }
    }
    String exportedIdentity(String identity) {
      if (all.isNotEmpty) return identity;
      final parts = (jsonDecode(identity) as List).toList();
      parts[0] = 'restored_primary';
      return jsonEncode(parts);
    }
    return CmsParser.encodeBackupPayload(
      origin: !_prefs.containsKey(keySubscriptions) ? configOrigin : primary?.url ?? '',
      rawConfig: !_prefs.containsKey(keySubscriptions) ? _publicRawConfig(rawConfig, configOrigin) : primary?.rawContent ?? '',
      settings: <String, dynamic>{
        if (_prefs.containsKey(keySubscriptions)) keySubscriptions: public.map((s) => s.toJson()).toList(),
        for (final key in [_siteOrder, _removedSites]) key: (_prefs.getStringList(key) ?? []).map((id) => identityAliases[id] ?? id).where(publicIds.contains).map(exportedIdentity).toList(),
        _siteAliases: aliases,
        keyPreferredSite: preferredSiteKey,
        for (final key in _appearanceStrings) if (_prefs.containsKey(key)) key: _prefs.getString(key),
        for (final key in _appearanceBooleans) if (_prefs.containsKey(key)) key: _prefs.getBool(key),
        keySkipIntroSec: skipIntroSec,
        keySkipOutroSec: skipOutroSec,
        keyRepeatMode: repeatMode,
        keySelectedSite: publicSupportedKey(),
        keyWatchHistory: _prefs.getString(keyWatchHistory) ?? '[]',
        keyFavorites: _prefs.getString(keyFavorites) ?? '[]',
        keySearchHistory: _prefs.getString(keySearchHistory) ?? '[]',
        keyEpisodesDescending: episodesDescending,
        keyPlaySpeed: playSpeed,
        keyAutoNext: autoNext,
      },
    );
  }
  static String? _normalizeJsonArraySetting(dynamic value, {bool search = false}) {
    final decoded = value is String ? jsonDecode(value) : value;
    if (decoded is! List) throw const FormatException('备份记录必须是列表');
    for (final item in decoded) {
      if (search) {
        if (item is! String) throw const FormatException('搜索记录格式无效');
      } else {
        if (item is! Map || item['site'] is! String || item['id'] is! String ||
            (item['site'] as String).isEmpty || (item['id'] as String).isEmpty) {
          throw const FormatException('观看记录或收藏缺少来源及影片标识');
        }
        for (final field in ['position', 'duration', 'index', 'updated']) {
          if (item.containsKey(field) && (item[field] is! num || item[field] < 0)) {
            throw FormatException('备份记录的 $field 无效');
          }
        }
      }
    }
    return jsonEncode(decoded);
  }
  /// Imports a backup JSON generated by either Android TV/Phone or Windows/Mac/iOS.
  /// Validates all fields before mutating preferences so failed restores preserve existing state.
  Future<CmsConfig?> importBackupJson(String rawBackup) async {
    final decoded = CmsParser.decodeBackupPayload(rawBackup);
    final settings = decoded.settings;
    final nextHistory = settings.containsKey(keyWatchHistory)
        ? _normalizeJsonArraySetting(settings[keyWatchHistory])
        : null;
    final nextFavorites = settings.containsKey(keyFavorites)
        ? _normalizeJsonArraySetting(settings[keyFavorites])
        : null;
    final nextSearch = settings.containsKey(keySearchHistory)
        ? _normalizeJsonArraySetting(settings[keySearchHistory], search: true)
        : null;
    if (settings.containsKey(keyPreferredSite) && settings[keyPreferredSite] is! String) {
      throw const FormatException('偏好源设置格式无效');
    }
    final incomingAliases = settings[_siteAliases];
    if (incomingAliases != null && (incomingAliases is! Map || incomingAliases.entries.any((e) => e.key is! String || e.value is! String || (e.value as String).isEmpty))) {
      throw const FormatException('来源标识记录无效');
    }
    final aliases = incomingAliases == null ? <String, String>{} : Map<String, String>.from(incomingAliases as Map);
    for (final identity in aliases.keys) {
      final parts = jsonDecode(identity);
      if (parts is! List || parts.length != 3 || parts.any((p) => p is! String)) throw const FormatException('来源标识记录无效');
    }
    final pickerEdits = <String, List<String>>{};
    final privateIdentities = (_loadImportedConfig()?.sites ?? const <CmsSite>[]).where((s) => s.isEffectivelyPrivate).map(_siteIdentity).toSet();
    for (final key in [_siteOrder, _removedSites]) {
      final value = settings[key];
      if (value == null) continue;
      if (value is! List || value.any((v) => v is! String)) throw const FormatException('线路排序记录无效');
      for (final identity in value.cast<String>()) {
        final parts = jsonDecode(identity);
        if (parts is! List || parts.length != 3 || parts.any((p) => p is! String) || privateIdentities.contains(identity)) {
          throw const FormatException('线路排序标识无效');
        }
      }
      pickerEdits[key] = value.cast<String>();
    }
    for (final key in _appearanceStrings) {
      if (settings.containsKey(key) && settings[key] is! String) throw const FormatException('外观设置格式无效');
    }
    for (final key in _appearanceBooleans) {
      if (settings.containsKey(key) && settings[key] is! bool) throw const FormatException('外观设置格式无效');
    }
    final incoming = <SubscriptionEntry>[];
    final ids = <String>{};
    final updatedSubs = settings[keySubscriptions];
    if (updatedSubs != null) {
      if (updatedSubs is! List) throw const FormatException('订阅列表格式无效');
      for (final item in updatedSubs) {
        if (item is! Map) throw const FormatException('订阅条目格式无效');
        final sub = SubscriptionEntry.fromJson(Map<String, dynamic>.from(item));
        if (sub.id.isEmpty || !ids.add(sub.id) || sub.isEffectivelyPrivate || sub.rawContent.isEmpty) {
          throw const FormatException('常规备份包含无效订阅');
        }
        CmsParser.parseConfig(sub.rawContent, origin: sub.url);
        incoming.add(sub);
      }
    } else if (decoded.rawConfig.isNotEmpty) {
      incoming.add(SubscriptionEntry(id: 'restored_primary', name: '已恢复的订阅',
          url: decoded.origin, rawContent: decoded.rawConfig));
    }
    final incomingIds = incoming.map((s) => s.id).toSet();
    final rawIdentities = <String>{};
    for (final sub in incoming) {
      final parsed = CmsParser.parseConfig(sub.rawContent, origin: sub.url);
      for (final site in parsed.sites) {
        rawIdentities.add(jsonEncode([sub.id, site.key, site.api]));
      }
    }
    if (aliases.keys.any((identity) => !rawIdentities.contains(identity)) ||
        aliases.values.toSet().length != aliases.length ||
        pickerEdits.values.expand((v) => v).any((identity) =>
            !incomingIds.contains((jsonDecode(identity) as List).first))) {
      throw const FormatException('线路管理记录与订阅不匹配');
    }
    if (updatedSubs != null || incoming.isNotEmpty) {
      final privateSubs = getSubscriptions().where((s) => s.isEffectivelyPrivate).toList();
      final privateIds = privateSubs.map((s) => s.id).toSet();
      if (incoming.any((s) => privateIds.contains(s.id))) throw const FormatException('订阅标识冲突');
      await saveSubscriptions([...incoming, ...privateSubs]);
      if (incoming.isEmpty) {
        await _prefs.remove(keyRawConfig);
        await _prefs.remove(keyOrigin);
      }
    }
    final privateSubIds = getSubscriptions().where((s) => s.isEffectivelyPrivate).map((s) => s.id).toSet();
    final retainedAliases = _savedAliases()..removeWhere((key, _) {
      try { return !privateSubIds.contains((jsonDecode(key) as List).first); } catch (_) { return true; }
    });
    retainedAliases.addAll(aliases);
    await _prefs.setString(_siteAliases, jsonEncode(retainedAliases));
    for (final entry in pickerEdits.entries) {
      final retainedPrivate = (_prefs.getStringList(entry.key) ?? []).where(privateIdentities.contains);
      await _prefs.setStringList(entry.key, [...entry.value, ...retainedPrivate]);
    }
    for (final key in _appearanceStrings) {
      if (settings[key] is String) await _prefs.setString(key, settings[key] as String);
    }
    for (final key in _appearanceBooleans) {
      if (settings[key] is bool) await _prefs.setBool(key, settings[key] as bool);
    }
    for (final key in [keySkipIntroSec, keySkipOutroSec]) {
      final value = settings[key];
      if (value is int && value >= 0 && value <= 600) await _prefs.setInt(key, value);
    }
    if (['off','one','all'].contains(settings[keyRepeatMode])) await setRepeatMode(settings[keyRepeatMode] as String);
    CmsConfig? parsedConfig = decoded.parsedConfig;
    if (decoded.rawConfig.isNotEmpty) {
      await _prefs.setString(keyRawConfig, decoded.rawConfig);
      await _prefs.setString(keyOrigin, decoded.origin);
      if (parsedConfig != null &&
          parsedConfig.supportedSites.isNotEmpty &&
          !parsedConfig.supportedSites.any((s) => s.key == selectedSiteKey)) {
        await _prefs.setString(
          keySelectedSite,
          parsedConfig.supportedSites.first.key,
        );
      }
    }
    if (settings[keyPreferredSite] is String) {
      final key = settings[keyPreferredSite] as String;
      final exists = (loadSavedConfig()?.publicSupportedSites ?? const <CmsSite>[]).any((s) => s.key == key);
      await setPreferredSiteKey(exists ? key : '');
    }
    if (settings[keySelectedSite] is String) {
      await setSelectedSiteKey(settings[keySelectedSite] as String);
    }
    if (nextHistory != null) {
      await _prefs.setString(keyWatchHistory, nextHistory);
    }
    if (nextFavorites != null) {
      await _prefs.setString(keyFavorites, nextFavorites);
    }
    if (nextSearch != null) {
      await _prefs.setString(keySearchHistory, nextSearch);
    }
    if (settings[keyEpisodesDescending] is bool) {
      await setEpisodesDescending(settings[keyEpisodesDescending] as bool);
    }
    if (settings[keyPlaySpeed] is num) {
      final speed = (settings[keyPlaySpeed] as num).toDouble();
      if (speed >= 0.5 && speed <= 2.0) {
        await setPlaySpeed(speed);
      }
    }
    if (settings[keyAutoNext] is bool) {
      await setAutoNext(settings[keyAutoNext] as bool);
    }
    return loadSavedConfig();
  }
}
