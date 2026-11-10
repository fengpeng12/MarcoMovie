import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_parser.dart';
import 'package:marco_movie/core/csp_bridge.dart';
import 'package:marco_movie/core/models.dart';
void main() {
  test('parses CMS config with relative URLs and strips JSON comments', () {
    const raw = '''
    {
      // sample comment
      "sites": [
        {"key": "demo", "name": "Demo VOD", "type": 1, "api": "/api.php/provide/vod/"}
      ],
      "lives": [
        {"name": "Demo Live", "url": "live/channels.m3u"}
      ]
    }
    ''';
    final config =
        CmsParser.parseConfig(raw, origin: 'https://config.example/root/tv.json');
    expect(config.supportedSites.length, 1);
    expect(
      config.supportedSites.first.api,
      'https://config.example/api.php/provide/vod/',
    );
    expect(config.lives.length, 1);
    expect(config.lives.first.url, 'https://config.example/root/live/channels.m3u');
  });
  test('handles trailing commas, string/bool fields, Base64 steganography, IDN URLs, and multi-depot configs', () {
    const lenientJson = '''
    \uFEFF{
      "urls": [
        {"name": "主力仓", "url": "https://depot.example/main.json",},
      ],
      "sites": [
        {
          "key": "s1",
          "name": "站点一",
          "type": "1",
          "searchable": true,
          "api": "https://cms.example/api.php",
          "header": "{\\"Referer\\":\\"https://cms.example\\"}",
        },
      ],
    }
    ''';
    final parsed = CmsParser.parseConfig(lenientJson);
    expect(parsed.depots.length, 1);
    expect(parsed.depots.first.name, '主力仓');
    expect(parsed.supportedSites.length, 1);
    expect(parsed.supportedSites.first.type, 1);
    expect(parsed.supportedSites.first.searchable, isTrue);
    expect(parsed.supportedSites.first.headers['Referer'], 'https://cms.example');
    // Test JPEG + ** + Base64 steganography
    final b64Payload = base64Encode(utf8.encode(lenientJson));
    final fakeJpegBytes = <int>[
      0xFF, 0xD8, 0xFF, 0xD9, 0x2A, 0x2A, // **
      ...ascii.encode(b64Payload),
    ];
    final unpackedDoc = CmsParser.decodeConfigDocument(fakeJpegBytes);
    final fromStego = CmsParser.parseConfig(unpackedDoc);
    expect(fromStego.supportedSites.length, 1);
    expect(fromStego.supportedSites.first.key, 's1');
    // Test Chinese IDN domain normalization and messy text URL extraction
    final normalizedIdn = CmsParser.extractAndNormalizeUrl('最新接口：http://肥猫.example/tv 欢迎使用');
    expect(normalizedIdn, 'http://xn--z7x900a.example/tv');
  });
  test('parses multi-line and multi-episode vod_play_url', () {
    const raw = '''
    {
      "page": 1,
      "pagecount": 2,
      "list": [
        {
          "vod_id": "101",
          "vod_name": "测试剧集",
          "vod_play_from": "线路A\$\$\$线路B",
          "vod_play_url": "第1集\$https://media.test/a1.m3u8#第2集\$https://media.test/a2.m3u8\$\$\$正片\$https://media.test/b1.mp4"
        }
      ]
    }
    ''';
    final listing = CmsParser.parseListing(raw);
    expect(listing.videos.length, 1);
    final video = listing.videos.first;
    expect(video.lines.length, 2);
    expect(video.lines[0].name, '线路A');
    expect(video.lines[0].episodes.length, 2);
    expect(video.lines[0].episodes[1].url, 'https://media.test/a2.m3u8');
    expect(video.lines[1].name, '线路B');
  });
  test('parses M3U and TXT live playlists', () {
    const playlist = '''
    #EXTM3U
    #EXTINF:-1 group-title="新闻",综合台
    https://media.test/live1.m3u8
    电影频道,#genre#
    经典剧场,https://media.test/movie1.m3u8#https://media.test/movie2.m3u8
    ''';
    final groups = CmsParser.parseLivePlaylist(playlist);
    expect(groups.length, 2);
    expect(groups[0].name, '新闻');
    expect(groups[0].channels.first.name, '综合台');
    expect(groups[1].name, '电影频道');
    expect(groups[1].channels.first.urls.length, 2);
  });
  test('enforces 60-entry watch history cap and 95% completion reset', () {
    var history = <WatchHistoryEntry>[];
    for (int i = 0; i < 65; i++) {
      history = CmsParser.upsertHistory(
        history,
        WatchHistoryEntry(
          site: 's',
          id: 'id_$i',
          title: 'Title $i',
          position: 30000,
          duration: 120000,
        ),
      );
    }
    expect(history.length, 60);
    expect(history.first.id, 'id_64');
    const completed = WatchHistoryEntry(
      site: 's',
      id: 'done',
      title: 'Done',
      position: 118000,
      duration: 120000,
    );
    expect(completed.complete, isTrue);
    expect(completed.resumePosition, 0);
  });
  test('parses XML CMS type 0 categories and video listings and checks direct playability', () {
    const xmlRaw = '''<?xml version="1.0" encoding="utf-8"?>
    <rss version="5.1">
      <class>
        <ty id="1">电影</ty>
        <ty id="2">剧集</ty>
      </class>
      <list page="1" pagecount="3" total="2">
        <video>
          <id>201</id>
          <name><![CDATA[XML测试片]]></name>
          <type>电影</type>
          <pic>https://img.test/p.jpg</pic>
          <note><![CDATA[HD]]></note>
          <dl>
            <dd flag="m3u8"><![CDATA[正片\$https://media.test/play.m3u8#花絮\$jx://custom/id]]></dd>
          </dl>
        </video>
      </list>
    </rss>''';
    final categories = CmsParser.parseCategories(xmlRaw);
    expect(categories.length, 2);
    expect(categories.first.name, '电影');
    final listing = CmsParser.parseListing(xmlRaw);
    expect(listing.pageCount, 3);
    expect(listing.videos.length, 1);
    final video = listing.videos.first;
    expect(video.title, 'XML测试片');
    expect(video.lines.first.episodes.length, 2);
    expect(video.lines.first.episodes[0].isDirectPlayable, isTrue);
    expect(video.lines.first.episodes[1].isDirectPlayable, isFalse);
  });
  test('supports bidirectional Android and Flutter backup formats and rejects invalid backups', () {
    const androidBackup = '''
    {
      "format": "MarcoMovie-1",
      "exported": 1700000000000,
      "origin": "https://mirror.example/config.json",
      "config": {
        "sites": [
          {"key": "vod1", "name": "VOD 1", "type": 1, "api": "https://vod.example/api"}
        ]
      },
      "settings": {
        "selected_site": "vod1",
        "play_speed": 1.25,
        "scale_mode": "fit",
        "auto_next": true,
        "watch_history": [
          {"site": "vod1", "id": "99", "title": "旧番", "position": 15000, "duration": 90000}
        ],
        "favorites": [
          {"site": "vod1", "id": "99", "title": "旧番"}
        ],
        "global_search_history": ["星际", "流浪"]
      }
    }
    ''';
    final decoded = CmsParser.decodeBackupPayload(androidBackup);
    expect(decoded.origin, 'https://mirror.example/config.json');
    expect(decoded.parsedConfig, isNotNull);
    expect(decoded.parsedConfig!.sites.first.key, 'vod1');
    expect(decoded.settings['selected_site'], 'vod1');
    expect(decoded.settings['play_speed'], 1.25);
    expect((decoded.settings['watch_history'] as List).length, 1);
    expect((decoded.settings['favorites'] as List).length, 1);
    expect(decoded.settings['global_search_history'], ['星际', '流浪']);
    final reEncoded = CmsParser.encodeBackupPayload(
      origin: decoded.origin,
      rawConfig: decoded.rawConfig,
      settings: decoded.settings,
      exportedAt: 1700000001000,
    );
    final roundTrip = CmsParser.decodeBackupPayload(reEncoded);
    expect(roundTrip.origin, decoded.origin);
    expect(roundTrip.parsedConfig!.sites.first.key, 'vod1');
    expect(roundTrip.settings['selected_site'], 'vod1');
    expect((roundTrip.settings['watch_history'] as List).first['id'], '99');
    expect((roundTrip.settings['favorites'] as List).first['id'], '99');
    expect(
      () => CmsParser.decodeBackupPayload('{"format":"unknown","settings":{}}'),
      throwsFormatException,
    );
  });

  test('normalizes raw MacCMS line codes, broken poster domains, and preserves episode metadata', () async {
    expect(CmsParser.friendlyLineName('modum3u8'), '魔都超清');
    expect(CmsParser.friendlyLineName('bfzym3u8'), '暴风蓝光');
    expect(CmsParser.friendlyLineName('dyttm3u8'), '电影天堂');
    expect(CmsParser.isBrokenPosterUrl('https://www.mdzypic.com/upload/vod/1.jpg'), isTrue);
    expect(CmsParser.isBrokenPosterUrl('https://img.example/poster.jpg'), isFalse);
    expect(CmsParser.formatNetdiskEpisodeName('第08集', 7, 24), '第08集');
    expect(CmsParser.formatNetdiskEpisodeName('第1集', 0, 24), '第1集');

    const myDriveSite = CmsSite(
      key: 'csp_MyDriveGuard',
      name: '📁 我的云盘 | 配置',
      type: 3,
      api: 'csp_MyDriveGuard',
    );
    expect(CspBridge.isMyDriveSite(myDriveSite), isTrue);
    expect(CspBridge.isNetdiskSite(myDriveSite), isTrue);
    expect(CspBridge.backendsForSite(myDriveSite), isEmpty);

    final (cats, listing) = await CspBridge.fetchHome(
      myDriveSite,
      (url, {headers = const {}, requestTimeout}) async => '{"list":[]}',
    );
    expect(cats.map((c) => c.name).toList(), containsAll(['网盘配置', '我的夸父', '我的优汐', '我的嘟嘟', '我的阿狸']));
    expect(listing.videos.take(4).map((v) => v.id), containsAll([
      'netdisk_qr:quark',
      'netdisk_qr:uc',
      'netdisk_qr:baidu',
      'netdisk_qr:ali',
    ]));
  });
  test('maps parent categories to leaf categories and merges child pages', () {
    const raw = '''
    {"class": [
      {"type_id": 1, "type_name": "电影片", "type_pid": 0},
      {"type_id": 2, "type_name": "连续剧", "type_pid": 0},
      {"type_id": 6, "type_name": "动作片", "type_pid": 1},
      {"type_id": 7, "type_name": "喜剧片", "type_pid": 1},
      {"type_id": 13, "type_name": "国产剧", "type_pid": 2}
    ]}
    ''';
    final categories = CmsParser.parseCategories(raw);
    expect(categories.first.isTopLevel, isTrue);
    expect(CmsParser.childCategoryIds(categories, '1'), ['6', '7']);
    expect(CmsParser.childCategoryIds(categories, '2'), ['13']);
    expect(CmsParser.childCategoryIds(categories, '6'), isEmpty);
    final merged = CspBridge.mergeChildListings(const [
      CmsListing(pageCount: 3, videos: [
        CmsVideo(id: 'a', title: 'A'),
        CmsVideo(id: 'b', title: 'B'),
      ]),
      CmsListing(pageCount: 5, videos: [
        CmsVideo(id: 'c', title: 'C'),
        CmsVideo(id: 'a', title: 'A'),
      ]),
    ], 1);
    expect(merged.videos.map((v) => v.id), ['a', 'c', 'b']);
    expect(merged.pageCount, 5);
  });
  test('parses universal VOD, M3U, TXT, and batch subscription formats with groups & privacy', () {
    // 1. Direct MacCMS VOD JSON response
    const vodJson = '{"code": 1, "msg": "数据列表", "class": [{"type_id": 1, "type_name": "电影"}], "list": [{"vod_id": 99, "vod_name": "星际穿越"}]}';
    final vodCfg = CmsParser.parseConfig(
      vodJson,
      origin: 'https://vod.example/api.php/provide/vod/?ac=list',
      defaultGroup: '主力影视',
      isPrivate: true,
      defaultName: '量子VOD',
    );
    expect(vodCfg.supportedSites.length, 1);
    expect(vodCfg.supportedSites.first.name, '量子VOD');
    expect(vodCfg.supportedSites.first.api, 'https://vod.example/api.php/provide/vod/');
    expect(vodCfg.supportedSites.first.group, '主力影视');
    expect(vodCfg.supportedSites.first.isPrivate, isTrue);
    expect(vodCfg.privateSupportedSites.length, 1);
    expect(vodCfg.publicSupportedSites, isEmpty);
    expect(CmsParser.detectSubscriptionFormat(vodJson, origin: 'https://vod.example/api.php/provide/vod/'), 'VOD');

    final privGroupCfg = CmsParser.parseConfig(
      vodJson,
      origin: 'https://vod.example/api.php/provide/vod/',
      defaultGroup: '隐私分组',
      isPrivate: false,
    );
    expect(privGroupCfg.supportedSites.first.isEffectivelyPrivate, isTrue);
    expect(privGroupCfg.publicSupportedSites, isEmpty);
    expect(privGroupCfg.privateSupportedSites.length, 1);

    // 2. M3U subscription playlist
    const m3uRaw = '''
#EXTM3U
#EXTINF:-1 group-title="央视频道",CCTV-1 综合
https://live.example/cctv1.m3u8
#EXTINF:-1 group-title="4K电影",奥本海默 4K
https://vod.example/oppenheimer.mp4
''';
    final m3uCfg = CmsParser.parseConfig(
      m3uRaw,
      origin: 'https://live.example/playlist.m3u',
      defaultGroup: '电视直播',
    );
    expect(m3uCfg.lives.length, 1);
    expect(m3uCfg.supportedSites.length, 1);
    expect(m3uCfg.supportedSites.first.isM3uVodApi, isTrue);
    final (m3uCats, m3uListing) = CmsParser.parseM3uVodHome(m3uRaw);
    expect(m3uCats.map((c) => c.name), ['央视频道', '4K电影']);
    expect(m3uListing.videos.length, 2);

    // 3. Batch multi-subscription URL splitting
    const batchText = '''
主力影视|非凡资源|https://ffzy.example/api.php/provide/vod/
央卫直播,https://live.example/tv.m3u
https://depot.example/config.json
''';
    final split = CmsParser.splitBatchSubscriptionUrls(batchText, defaultGroup: '默认分组');
    expect(split.length, 3);
    expect(split[0].group, '主力影视');
    expect(split[0].name, '非凡资源');
    expect(split[1].name, '央卫直播');
    expect(split[2].group, '默认分组');
  });
  test('resolves 5 primary home tabs and filters videos by category, area, and year', () {
    const raw = '''
    {"class": [
      {"type_id": 1, "type_name": "电影片", "type_pid": 0},
      {"type_id": 2, "type_name": "连续剧", "type_pid": 0},
      {"type_id": 3, "type_name": "综艺片", "type_pid": 0},
      {"type_id": 4, "type_name": "动漫片", "type_pid": 0},
      {"type_id": 6, "type_name": "动作片", "type_pid": 1},
      {"type_id": 13, "type_name": "国产剧", "type_pid": 2}
    ]}
    ''';
    final cats = CmsParser.parseCategories(raw);
    expect(CmsParser.resolvePrimaryTabCategory(cats, 'movie').categoryId, '1');
    expect(CmsParser.resolvePrimaryTabCategory(cats, 'movie').childIds, ['6']);
    expect(CmsParser.resolvePrimaryTabCategory(cats, 'series').categoryId, '2');
    expect(CmsParser.resolvePrimaryTabCategory(cats, 'anime').categoryId, '4');
    expect(CmsParser.resolvePrimaryTabCategory(cats, 'variety').categoryId, '3');

    const videos = [
      CmsVideo(id: '1', title: '流浪地球2', year: '2023', area: '中国大陆', tag: '科幻,冒险'),
      CmsVideo(id: '2', title: '奥本海默', year: '2023', area: '美国', tag: '传记,剧情'),
      CmsVideo(id: '3', title: '繁花', year: '2024', area: '大陆', tag: '剧情,爱情'),
    ];
    final filtered = CmsParser.filterVideos(
      videos,
      const CmsFilter(area: '大陆', year: '2023', genreLabel: '科幻'),
    );
    expect(filtered.map((v) => v.id), ['1']);
  });
  test('upgrades Douban and Bilibili poster URLs to 1080p HD variants', () {
    expect(
      CmsParser.upgradePosterUrlToHd(
        'https://img1.doubanio.com/view/photo/s_ratio_poster/public/p2912345.webp',
      ),
      'https://img1.doubanio.com/view/photo/l_ratio_poster/public/p2912345.jpg',
    );
    expect(
      CmsParser.upgradePosterUrlToHd(
        'https://i0.hdslb.com/bfs/archive/abc.jpg@320w_200h_1c.webp',
      ),
      'https://i0.hdslb.com/bfs/archive/abc.jpg',
    );
  });
  test('parses multi-season titles, matches franchise seasons, and extracts in-line season groups', () {
    expect(CmsParser.parseChineseNumber('一'), 1);
    expect(CmsParser.parseChineseNumber('六'), 6);
    expect(CmsParser.parseChineseNumber('十'), 10);
    expect(CmsParser.parseChineseNumber('十二'), 12);
    expect(CmsParser.parseChineseNumber('二十'), 20);
    expect(CmsParser.parseChineseNumber('二十一'), 21);

    final s6 = CmsParser.parseSeriesSeasonInfo('披荆斩棘第六季');
    expect(s6.baseTitle, '披荆斩棘');
    expect(s6.seasonNumber, 6);
    expect(s6.seasonLabel, '第 6 季');
    expect(s6.hasExplicitSeason, isTrue);

    final s21 = CmsParser.parseSeriesSeasonInfo('全美超模大赛第二十一季');
    expect(s21.baseTitle, '全美超模大赛');
    expect(s21.seasonNumber, 21);
    expect(s21.seasonLabel, '第 21 季');
    expect(s21.hasExplicitSeason, isTrue);

    final sYear = CmsParser.parseSeriesSeasonInfo('我家那闺女2026');
    expect(sYear.baseTitle, '我家那闺女');
    expect(sYear.seasonNumber, 2026);
    expect(sYear.seasonLabel, '2026 季');
    expect(sYear.hasExplicitSeason, isTrue);

    final seq = CmsParser.parseSeriesSeasonInfo('庆余年2');
    expect(seq.baseTitle, '庆余年');
    expect(seq.seasonNumber, 2);
    expect(seq.seasonLabel, '第 2 季');
    expect(seq.hasExplicitSeason, isTrue);

    final baseOnly = CmsParser.parseSeriesSeasonInfo('谷雨');
    expect(baseOnly.baseTitle, '谷雨');
    expect(baseOnly.seasonNumber, 1);
    expect(baseOnly.seasonLabel, '第 1 季');
    expect(baseOnly.hasExplicitSeason, isFalse);

    expect(
      CmsParser.isSameFranchiseSeasonCandidate('披荆斩棘第六季', '披荆斩棘 第一季'),
      isTrue,
    );
    expect(
      CmsParser.isSameFranchiseSeasonCandidate('庆余年', '庆余年 第二季'),
      isTrue,
    );
    expect(
      CmsParser.isSameFranchiseSeasonCandidate('庆余年 第二季', '庆余年 花絮特辑'),
      isFalse,
    );

    const inLineEps = [
      CmsEpisode(name: '[4K]S01E01.mkv', url: 'https://v.example/1'),
      CmsEpisode(name: '[4K]S01E02.mkv', url: 'https://v.example/2'),
      CmsEpisode(name: '[4K]S02E01.mkv', url: 'https://v.example/3'),
      CmsEpisode(name: '[4K]S02E02.mkv', url: 'https://v.example/4'),
      CmsEpisode(name: '[4K]S02E03.mkv', url: 'https://v.example/5'),
    ];
    final groups = CmsParser.extractInLineSeasons(inLineEps);
    expect(groups.length, 2);
    expect(groups[0].seasonNumber, 1);
    expect(groups[0].seasonLabel, '第 1 季');
    expect(groups[0].episodeIndexes, [0, 1]);
    expect(groups[1].seasonNumber, 2);
    expect(groups[1].seasonLabel, '第 2 季');
    expect(groups[1].episodeIndexes, [2, 3, 4]);

    final rawConfig = '''
{
  "jar": "./custom_spider.jar;md5;abcd",
  "parses": [
    {"name": "WebParse", "type": 0, "url": "https://parse.example/web?url="},
    {"name": "JsonParse", "type": 1, "url": "https://parse.example/json?url="}
  ],
  "sites": [
    {
      "key": "appv2_site",
      "name": "AppV2站点",
      "type": 3,
      "api": "csp_AppYsV2",
      "ext": {
        "url": "https://cms.example/api.php/app/",
        "ua": "CustomAppUA/1.0",
        "headers": {"Referer": "https://cms.example/"}
      }
    },
    {
      "key": "mydrive",
      "name": "🗂我的云盘┃配置",
      "type": 3,
      "api": "csp_MyDriveGuard"
    }
  ]
}
''';
    final gzipped = const GZipEncoder().encode(utf8.encode(rawConfig))!;
    final decodedGzip = CmsParser.decodeConfigDocument(gzipped);
    final parsedBundle = CmsParser.parseConfig(
      decodedGzip,
      origin: 'https://sub.example/box/config.json',
    );
    expect(
      parsedBundle.spider,
      'https://sub.example/box/custom_spider.jar;md5;abcd',
    );
    final appSite = parsedBundle.sites.firstWhere((s) => s.key == 'appv2_site');
    expect(appSite.playUrl, 'https://parse.example/json?url=');
    expect(appSite.headers['User-Agent'], 'CustomAppUA/1.0');
    expect(appSite.headers['Referer'], 'https://cms.example/');
    expect(appSite.canBrowse, isTrue);

    final myDrive = parsedBundle.sites.firstWhere((s) => s.key == 'mydrive');
    expect(myDrive.canBrowse, isFalse);

    final livePlain = '#EXTM3U\n#EXTINF:-1 tvg-name="CCTV-1" group-title="央视",\nhttp://live.example/cctv1.m3u8';
    final liveObfuscated = 'PNG_STEG**${base64Encode(utf8.encode(livePlain))}';
    final liveGroups = CmsParser.parseLivePlaylist(liveObfuscated);
    expect(liveGroups.length, 1);
    expect(liveGroups.first.name, '央视');
    expect(liveGroups.first.channels.first.name, 'CCTV-1');

    final appV2HomeJson = '''
{
  "code": 1,
  "msg": "ok",
  "data": {
    "list": [
      {
        "vod_id": "901",
        "vod_name": "测试影片",
        "vod_pic": "https://img.example/901.jpg",
        "vod_url_with_player": [
          {
            "code": "lineA",
            "name": "蓝光专线",
            "url": "第1集\$https://cdn.example/901-1.m3u8#第2集\$https://cdn.example/901-2.m3u8"
          }
        ]
      }
    ]
  }
}
''';
    final appV2Listing = CmsParser.parseListing(appV2HomeJson);
    expect(appV2Listing.videos.length, 1);
    expect(appV2Listing.videos.first.title, '测试影片');
    expect(appV2Listing.videos.first.lines.length, 1);
    expect(appV2Listing.videos.first.lines.first.name, '蓝光专线');
    expect(appV2Listing.videos.first.lines.first.episodes.length, 2);

    const tvboxJsonWithCommentsAndExtinfRules = r'''
{
"spider":"https://cdn.example/posters/spider.jpg;md5;b3fb6f369726e9c688dd5a7ad017d0dd",
"sites":[
{"key":"doudou","name":"豆豆┃片单","type":3,"api":"csp_DouDouGuard","searchable":0},
{"key":"t4_1","name":"光影┃不卡","type":3,"api":"csp_T4Guard","searchable":1,"ext":"Zmlyc3Q="},
//{"key":"commented","name":"已注释站点","type":3,"api":"csp_YCyzGuard","searchable":1},
{"key":"bttwoo","name":"比特┃不卡","type":3,"api":"csp_BttwooGuard","searchable":1},
{"key":"fy","name":"风云┃多线","type":3,"api":"csp_FyGuard","searchable":1,"ext":{"type":"video","name":"Fy"}},
{"key":"auete","name":"奥特┃多线","type":3,"api":"csp_AueteGuard","searchable":1},
{"key":"dm84","name":"巴士┃动漫","type":3,"api":"csp_Dm84Guard","searchable":1},
{"key":"zpan","name":"盘搜┃四盘","type":3,"api":"csp_S_zpsGuard","searchable":1,"ext":{"siteUrl":"https://so.example/"}}
],
"rules":[{"name":"ad_filter","hosts":["cdn.example"],"regex":["#EXT-X-DISCONTINUITY\\r*\\n*#EXTINF:5.480000,[\\s\\S]*?#EXT-X-DISCONTINUITY"]}],
"lives":[
{"name":"综合直播","type":0,"url":"https://live.example/iptv.m3u","ua":"okHttp/Mod-1.5.0.0"}
]
}
''';
    expect(
      CmsParser.detectSubscriptionFormat(tvboxJsonWithCommentsAndExtinfRules),
      'JSON',
    );
    final parsedWithRules = CmsParser.parseConfig(
      tvboxJsonWithCommentsAndExtinfRules,
      origin: 'https://sub.example/tv',
    );
    expect(parsedWithRules.sites.length, 7);
    expect(parsedWithRules.supportedSites.map((s) => s.key).toList(), [
      'doudou',
      't4_1',
      'bttwoo',
      'fy',
      'auete',
      'dm84',
    ]);
    expect(parsedWithRules.sites.singleWhere((s) => s.key == 'zpan').canBrowse, isFalse);
    expect(parsedWithRules.lives.length, 1);
    expect(parsedWithRules.lives.first.name, '综合直播');
  });
}
