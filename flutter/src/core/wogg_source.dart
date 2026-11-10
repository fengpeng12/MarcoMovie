import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

import 'models.dart';

/// Data-only catalogue adapter for the original WoGG website. Android plugin
/// bytes supply reviewed configuration; they are never loaded or executed.
class WoggSource {
  final Future<String> Function(String, Map<String, String>) read;
  final Future<Uint8List> Function(String, Map<String, String>) readBytes;
  final Future<List<CmsEpisode>> Function(String) listShare;
  final Future<List<CmsEpisode>> Function(String, Completer<void>)?
      listShareWithCancellation;
  final Duration shareTimeout;
  final _configs =
      <String, ({WoggPluginConfiguration value, DateTime expires})>{};
  final _selectedOrigins = <String, String>{};

  WoggSource({
    required this.read,
    required this.readBytes,
    required this.listShare,
    this.listShareWithCancellation,
    this.shareTimeout = const Duration(seconds: 40),
  });

  static bool supports(CmsSite site) {
    if (site.type != 3 ||
        !RegExp(r'^csp_wogg(?:guard)?$', caseSensitive: false)
            .hasMatch(site.api.trim())) {
      return false;
    }
    if (site.pluginReference.trim().isNotEmpty) return true;
    try {
      final ext = jsonDecode(site.ext);
      return ext is Map && (ext['siteUrl'] ?? '').toString().trim().isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static const categories = [
    {'type_id': '1', 'type_name': '电影'},
    {'type_id': '2', 'type_name': '剧集'},
    {'type_id': '44', 'type_name': '臻彩'},
    {'type_id': '6', 'type_name': '短漫剧'},
    {'type_id': '3', 'type_name': '动漫'},
    {'type_id': '4', 'type_name': '综艺'},
    {'type_id': '46', 'type_name': '纪录片'},
    {'type_id': '5', 'type_name': '音乐'},
  ];

  String _scope(CmsSite site) => sha256
      .convert(utf8.encode(jsonEncode([
        site.subscriptionId,
        site.sourceKey,
        site.pluginReference,
        site.ext,
        site.headers,
        site.isEffectivelyPrivate,
      ])))
      .toString();

  static Uri _origin(String address) {
    final value = Uri.tryParse(address.trim());
    if (value == null ||
        !['http', 'https'].contains(value.scheme) ||
        value.host.isEmpty ||
        value.userInfo.isNotEmpty ||
        value.hasQuery ||
        value.hasFragment) {
      throw const FormatException('玩偶站点地址无效');
    }
    return value.replace(
        path: value.path.endsWith('/') ? value.path : '${value.path}/');
  }

  Future<WoggPluginConfiguration> _configuration(CmsSite site) async {
    Object? ext;
    try {
      ext = jsonDecode(site.ext);
    } catch (_) {/* Optional JSON ext. */}
    if (ext is Map && (ext['siteUrl'] ?? '').toString().trim().isNotEmpty) {
      return WoggPluginConfiguration(
        origins: [_origin(ext['siteUrl'].toString()).toString()],
        userAgent: 'Mozilla/5.0',
      );
    }
    final scope = _scope(site);
    final existing = _configs[scope];
    if (existing != null && DateTime.now().isBefore(existing.expires)) {
      return existing.value;
    }
    final declaration = site.pluginReference.trim();
    final parts = declaration.split(RegExp(';md5;', caseSensitive: false));
    if (parts.length > 2 ||
        (parts.length == 2 &&
            !RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(parts[1]))) {
      throw const FormatException('玩偶插件摘要格式无效');
    }
    final uri = Uri.tryParse(parts.first);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('玩偶源需要原订阅插件或明确的 siteUrl');
    }
    final bytes = await readBytes(uri.toString(), site.headers)
        .timeout(const Duration(seconds: 25));
    if (parts.length == 2 &&
        md5.convert(bytes).toString() != parts[1].toLowerCase()) {
      throw const FormatException('玩偶插件摘要不匹配，请刷新原订阅');
    }
    final result = WoggPluginConfiguration.extract(bytes);
    if (_configs.length >= 32) _configs.remove(_configs.keys.first);
    _configs[scope] = (
      value: result,
      expires: DateTime.now().add(const Duration(minutes: 5))
    );
    return result;
  }

  Future<String> invoke(CmsSite site, String method, List<Object?> args,
      {Completer<void>? cancellation}) async {
    void check() {
      if (cancellation?.isCompleted == true) {
        throw const FormatException('搜索已取消');
      }
    }

    check();
    if (!supports(site)) throw const FormatException('不是 WoGG 源');
    method = const {
          'home': 'homeContent',
          'homeVod': 'homeVideoContent',
          'category': 'categoryContent',
          'search': 'searchContent',
          'detail': 'detailContent',
        }[method] ??
        method;
    String path;
    var page = 1;
    switch (method) {
      case 'homeContent':
      case 'homeVideoContent':
        path = '';
      case 'categoryContent':
        final category = args.isEmpty ? '' : args[0].toString();
        page = args.length > 1 ? int.tryParse(args[1].toString()) ?? 1 : 1;
        if (page < 1 || !RegExp(r'^\d+$').hasMatch(category)) {
          throw const FormatException('玩偶分类或页码无效');
        }
        final slots = List<String>.filled(12, '');
        slots[0] = category;
        slots[8] = '$page';
        if (args.length > 3 && args[3] is Map) {
          for (final entry in (args[3] as Map).entries) {
            final slot = int.tryParse(entry.key.toString());
            if (slot == null || slot < 0 || slot > 11) {
              throw const FormatException('玩偶筛选项无效');
            }
            slots[slot] = Uri.encodeQueryComponent(entry.value.toString());
          }
        }
        path = 'vodshow/${slots.join('-')}.html';
      case 'searchContent':
        if (args.length > 2 && (int.tryParse(args[2].toString()) ?? 1) > 1) {
          return jsonEncode({'list': [], 'page': args[2], 'pagecount': 1});
        }
        final keyword = args.isEmpty ? '' : args[0].toString().trim();
        if (keyword.isEmpty) return jsonEncode({'list': []});
        path =
            'vodsearch/-------------.html?wd=${Uri.encodeQueryComponent(keyword)}';
      case 'detailContent':
        final ids = args.isEmpty ? null : args[0];
        final id = ids is List && ids.isNotEmpty
            ? ids.first.toString()
            : ids?.toString() ?? '';
        if (!RegExp(r'^\d+$').hasMatch(id)) {
          throw const FormatException('玩偶详情编号无效');
        }
        path = 'voddetail/$id.html';
      default:
        throw const FormatException('玩偶播放由原网盘线路解析');
    }
    final config = await _configuration(site);
    check();
    final scope = _scope(site);
    final origins = <String>{
      if (_selectedOrigins[scope] != null) _selectedOrigins[scope]!,
      ...config.origins,
    };
    Document? document;
    Uri? base;
    for (final origin in origins) {
      check();
      try {
        final candidate = _origin(origin).resolve(path);
        // Subscription download credentials must not escape to catalogue hosts.
        final body = await read(candidate.toString(), {
          'User-Agent': config.userAgent,
        }).timeout(const Duration(seconds: 12));
        check();
        if (utf8.encode(body).length > 2 * 1024 * 1024) {
          throw const FormatException('玩偶目录响应过大');
        }
        final parsed = html.parse(body);
        if (!parsed.documentElement!.text.contains('玩偶') ||
            parsed.querySelector('div.module-item, div.module-search-item, '
                    'div.video-info, div.video-info-items, #search') ==
                null) {
          continue;
        }
        document = parsed;
        base = candidate;
        if (_selectedOrigins.length >= 32 &&
            !_selectedOrigins.containsKey(scope)) {
          _selectedOrigins.remove(_selectedOrigins.keys.first);
        }
        _selectedOrigins[scope] = origin;
        break;
      } catch (_) {
        check();
      }
    }
    if (document == null || base == null) {
      throw const FormatException('玩偶原站暂时无法访问，请稍后重试或更新原订阅');
    }
    if (method == 'detailContent') {
      final id = args[0] is List
          ? (args[0] as List).first.toString()
          : args[0].toString();
      return jsonEncode(await _detail(document, base, id, check, cancellation));
    }
    final entries = _listing(document, base, search: method == 'searchContent');
    final result = <String, dynamic>{
      'list': entries,
      'page': page,
      'pagecount': _pageCount(document, page, entries.isNotEmpty),
      'limit': entries.length,
      'total': entries.length,
    };
    if (method == 'homeContent') {
      result['class'] = categories;
      result['filters'] = _filters();
    }
    return jsonEncode(result);
  }

  static List<Map<String, dynamic>> _listing(Document doc, Uri base,
      {required bool search}) {
    final result = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final item in doc.querySelectorAll(
        search ? 'div.module-search-item' : 'div.module-item')) {
      final anchor = item.querySelector(
          search ? 'div.video-info-header h3 a' : 'div.module-item-pic > a');
      final id = RegExp(r'/voddetail/(\d+)\.html')
          .firstMatch(anchor?.attributes['href'] ?? '')
          ?.group(1);
      if (id == null || !seen.add(id)) continue;
      final image = item.querySelector('.module-item-pic img');
      result.add({
        'vod_id': id,
        'vod_name': search
            ? _text(anchor)
            : anchor?.attributes['title'] ?? _text(anchor),
        'vod_pic': _image(image, base),
        'vod_remarks': _text(item.querySelector(search
            ? '.video-info-header a.video-serial'
            : '.module-item-text')),
        'vod_year': _text(item.querySelector('.module-item-caption span')),
      });
    }
    return result;
  }

  Future<Map<String, dynamic>> _detail(
      Document doc, Uri base, String id, void Function() check,
      Completer<void>? cancellation) async {
    final image = doc.querySelector('div.video-cover div.module-item-pic img');
    final title = image?.attributes['alt'] ?? _text(doc.querySelector('h1'));
    final video = <String, dynamic>{
      'vod_id': id,
      'vod_name': title,
      'vod_pic': _image(image, base)
    };
    const fields = {
      '备注：': 'vod_remarks',
      '导演：': 'vod_director',
      '主演：': 'vod_actor',
      '年代：': 'vod_year',
      '剧情：': 'vod_content'
    };
    for (final row in doc.querySelectorAll('div.video-info-items')) {
      final label = _text(row.querySelector('span.video-info-itemtitle'));
      final key = fields[label];
      if (key != null) {
        video[key] = _text(row.querySelector('div.video-info-item'))
            .replaceAll('[收起部分]', '');
      }
    }
    final lines = <Map<String, dynamic>>[];
    final errors = <Map<String, String>>[];
    final seen = <String>{};
    var index = 0;
    final tabs = doc.querySelectorAll('.module-tab-item.downtab-item');
    final panels = doc.querySelectorAll('.module-downlist');
    for (final link in doc.querySelectorAll('div.module-row-info > a')) {
      final share = (link.attributes['data-clipboard-text'] ?? '').trim();
      if (share.isEmpty || !seen.add(share)) continue;
      index++;
      var label = '';
      Element? ancestor = link.parent;
      while (ancestor != null) {
        final panel = panels.indexOf(ancestor);
        if (panel >= 0 && panel < tabs.length) {
          label = _text(tabs[panel]).replaceFirst(RegExp(r'\d+$'), '');
          break;
        }
        ancestor = ancestor.parent;
      }
      if (label.isEmpty) label = _providerLabel(share);
      label = '$label $index';
      check();
      final shareAbort = Completer<void>();
      void cancelShare() {
        if (!shareAbort.isCompleted) shareAbort.complete();
      }
      final subscription = cancellation?.future.asStream().listen((_) => cancelShare());
      try {
        final episodes = await (listShareWithCancellation?.call(share, shareAbort) ??
                listShare(share)).timeout(shareTimeout, onTimeout: () {
          cancelShare();
          throw TimeoutException('原网盘目录读取超时');
        });
        check();
        if (episodes.isEmpty) throw const FormatException('分享中没有可播放视频');
        lines.add({
          'name': label,
          'episodes': episodes
              .map((episode) => {
                    'name': episode.name,
                    'url': episode.url,
                    if (episode.headers.isNotEmpty) 'headers': episode.headers,
                  })
              .toList()
        });
      } catch (_) {
        check();
        errors.add({'line': label, 'message': '原网盘分享暂不可用，请检查网盘登录或分享状态'});
      } finally {
        cancelShare();
        if (subscription != null) unawaited(subscription.cancel());
      }
    }
    if (lines.isEmpty) {
      throw FormatException(
          index == 0 ? '玩偶原站尚未提供此片分享' : '玩偶原网盘分享暂不可用，请检查网盘登录或分享状态');
    }
    // Native CMS parsing accepts structured lines, preserving episode headers
    // and opaque provider references without delimiter-based re-encoding.
    video['lines'] = lines;
    if (errors.isNotEmpty) video['wogg_share_errors'] = errors;
    return {
      'list': [video]
    };
  }

  static String _providerLabel(String share) {
    final host = Uri.tryParse(share)?.host.toLowerCase() ?? '';
    if (host == 'drive.uc.cn') return 'UC网盘';
    if (host == 'pan.quark.cn') return '夸克网盘';
    if (host == 'pan.baidu.com') return '百度网盘';
    if (host == 'www.alipan.com' || host == 'www.aliyundrive.com') {
      return '阿里云盘';
    }
    return '原站分享';
  }

  static String _text(Element? element) =>
      (element?.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _image(Element? image, Uri base) {
    final raw = image?.attributes['data-src'] ?? image?.attributes['src'] ?? '';
    if (raw.isEmpty) return '';
    final uri = base.resolve(raw.replaceFirst('/db.php?url=', ''));
    return ['http', 'https'].contains(uri.scheme) ? uri.toString() : '';
  }

  static int _pageCount(Document doc, int page, bool hasItems) {
    var count = page;
    for (final link in doc.querySelectorAll('.page a, .pagination a')) {
      final number = int.tryParse(_text(link));
      if (number != null && number > count) count = number;
      final href = link.attributes['href'] ?? '';
      final match = RegExp(r'/vodshow/([^-]*)-.*\.html').firstMatch(href);
      if (match != null) {
        final slots = Uri.tryParse(href)
                ?.path
                .split('/')
                .last
                .replaceFirst('.html', '')
                .split('-') ??
            [];
        final candidate = slots.length == 12 ? int.tryParse(slots[8]) : null;
        if (candidate != null && candidate > count) count = candidate;
      }
    }
    return count;
  }

  static Map<String, Object> _filters() {
    Map<String, Object> dimension(
            String key, String name, List<String> values) =>
        {
          'key': key,
          'name': name,
          'value': [
            {'n': '全部', 'v': ''},
            for (final value in values) {'n': value, 'v': value},
          ],
        };
    final years =
        dimension('11', '年代', [for (var y = 2026; y >= 2011; y--) '$y']);
    final areas = dimension('1', '地区', [
      '中国大陆',
      '中国香港',
      '中国台湾',
      '美国',
      '韩国',
      '日本',
      '西班牙',
      '泰国',
      '法国',
      '英国',
      '德国',
      '印度',
      '其他'
    ]);
    final genres = dimension('3', '类型', [
      '喜剧',
      '爱情',
      '动作',
      '恐怖',
      '科幻',
      '剧情',
      '犯罪',
      '奇幻',
      '战争',
      '悬疑',
      '武侠',
      '冒险',
      '古装',
      '历史',
      '惊悚'
    ]);
    return {
      for (final id in ['1', '2', '44']) id: [genres, years, areas],
      '3': [years, areas],
      '4': [years, areas],
      '46': [years],
      '6': [
        dimension('3', '类型', [
          '男频',
          '女频',
          '都市',
          '甜宠',
          '年代',
          '穿越',
          '古装',
          '亲情',
          '奇幻',
          '萌宝',
          '重生',
          '冒险',
          '逆袭',
          '虐恋',
          '复仇',
          '修仙',
          '鉴宝'
        ]),
        years
      ],
      '5': [
        dimension('5', '字母',
            [for (var i = 65; i <= 90; i++) String.fromCharCode(i), '0-9'])
      ],
    };
  }
}

/// The fixed offsets are reviewed data locations in one exact DEX, not an
/// interpreter. An updated plugin fails closed until its data layout is reviewed.
class WoggPluginConfiguration {
  final List<String> origins;
  final String userAgent;
  const WoggPluginConfiguration(
      {required this.origins, required this.userAgent});

  static WoggPluginConfiguration extract(Uint8List bytes) {
    if (bytes.isEmpty ||
        bytes.length > 16 * 1024 * 1024 ||
        sha256.convert(bytes).toString() !=
            'da3f3a7afcfcded4d58d9c3a574dfb5cb2ddcc3db4290b7d8b3a7346f9ee8096') {
      throw const FormatException('此版本玩偶插件尚未完成适配，请保留原订阅并更新应用');
    }
    Uint8List member(Uint8List data, String name) {
      final archive = ZipDecoder().decodeBytes(data, verify: true);
      final matches =
          archive.files.where((f) => f.name == name && f.isFile).toList();
      if (matches.length != 1 || matches.single.size > 16 * 1024 * 1024) {
        throw const FormatException('玩偶插件结构无效');
      }
      return Uint8List.fromList(matches.single.content);
    }

    final payload = member(bytes, 'assets/ftyshinidie.guard');
    for (var i = 0; i < payload.length; i++) {
      if (const [1, 2, 5, 6].contains(payload[i])) payload[i] ^= 7;
    }
    final dex = member(payload, 'classes.dex');
    if (sha256.convert(dex).toString() !=
        '3d92d4cd3d3c11896d4a2a576e06fd68748b4944c6bc2330357c4c2085ffa47d') {
      throw const FormatException('玩偶插件数据校验失败');
    }
    final data = ByteData.sublistView(dex, 1620732, 1620732 + 1548 * 2);
    String decode(int start, int length, int mask) => String.fromCharCodes([
          for (var i = start; i < start + length; i++)
            data.getUint16(i * 2, Endian.little) ^ mask,
        ]);
    return WoggPluginConfiguration(
      origins: [
        decode(796, 26, 1112),
        decode(822, 31, 1852),
        decode(853, 21, 1824),
        decode(874, 26, 1782),
        decode(900, 20, 1412)
      ],
      userAgent: decode(43, 111, 974),
    );
  }
}
