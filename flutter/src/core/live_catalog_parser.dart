import 'dart:convert';

import 'cms_parser.dart';
import 'models.dart';
import 'source_playback.dart';

/// Shared catalogue decoder. It never fetches URLs or executes a plugin.
class LiveCatalogParser {
  static const maxBytes = 6 * 1024 * 1024;

  static Map<String, String> merge(Iterable<Map<String, String>> layers) {
    final result = <String, String>{};
    for (final layer in layers) {
      for (final entry in layer.entries) {
        if (entry.key.isEmpty ||
            RegExp(r'[\r\n]').hasMatch(entry.key + entry.value))
          continue;
        result.removeWhere(
          (key, _) => key.toLowerCase() == entry.key.toLowerCase(),
        );
        result[entry.key] = entry.value;
      }
    }
    return result;
  }

  static Map<String, String> headers(Map item) {
    Map<String, String> read(dynamic value) {
      if (value is String) {
        try {
          value = jsonDecode(value);
        } on FormatException {
          return {};
        }
      }
      return value is Map
          ? value.map((key, value) => MapEntry('$key', '$value'))
          : {};
    }

    return merge([
      read(item['headers']),
      read(item['header']),
      for (final pair in {
        'ua': 'User-Agent',
        'referer': 'Referer',
        'origin': 'Origin',
      }.entries)
        if (item[pair.key] is String && (item[pair.key] as String).isNotEmpty)
          {pair.value: item[pair.key] as String},
    ]);
  }

  /// Only TVBox's explicit live-directory wrapper is decoded. Other proxy
  /// protocols belong to an engine, and must never become remote file reads.
  static String? directoryUrl(String raw) {
    final value = raw.trim();
    if (!value.startsWith('proxy://')) return null;
    final query = value
        .substring('proxy://'.length)
        .replaceFirst(RegExp(r'^\?'), '');
    try {
      final params = Uri(query: query).queryParametersAll;
      if (params.values.any((v) => v.length != 1) ||
          params['do']?.single != 'live' ||
          params['type']?.single != 'txt')
        return null;
      final ext = params['ext']?.single;
      if (ext == null || ext.length > 32768) return null;
      final decoded = utf8.decode(base64Decode(base64.normalize(ext))).trim();
      final uri = Uri.tryParse(decoded);
      return uri != null &&
              ['http', 'https'].contains(uri.scheme) &&
              uri.host.isNotEmpty
          ? uri.toString()
          : null;
    } on FormatException {
      return null;
    }
  }

  static String? _tryDecodeBase64LiveText(String raw) {
    var candidate = raw;
    final star = candidate.lastIndexOf('**');
    if (star >= 0 && star + 2 < candidate.length) {
      candidate = candidate.substring(star + 2).trim();
    }
    final compact = candidate.replaceAll(RegExp(r'\s+'), '');
    if (compact.length < 16 ||
        !RegExp(r'^[A-Za-z0-9+/_-]+={0,2}$').hasMatch(compact)) {
      return null;
    }
    var normalized = compact.replaceAll('-', '+').replaceAll('_', '/');
    while (normalized.length % 4 != 0) {
      normalized += '=';
    }
    try {
      final decoded = utf8
          .decode(base64Decode(normalized), allowMalformed: true)
          .replaceFirst(RegExp(r'^\uFEFF'), '')
          .trim();
      if (decoded.startsWith('#EXTM3U') ||
          decoded.contains('#EXTINF:') ||
          decoded.contains(',#genre#') ||
          decoded.startsWith('{') ||
          decoded.startsWith('[') ||
          RegExp(
            r'(?:^|\n)[^\r\n,]+,\s*(?:https?|rtmps?|rtsp)://',
            caseSensitive: false,
          ).hasMatch(decoded)) {
        return decoded;
      }
    } catch (_) {}
    return null;
  }

  static List<LiveGroup> parse(
    String content, {
    String origin = '',
    Map<String, String> sourceHeaders = const {},
    required String Function(String, String) resolve,
  }) {
    if (content.length > maxBytes || utf8.encode(content).length > maxBytes) {
      throw const FormatException('直播列表超过 6 MB');
    }
    final groups = <String, Map<String, List<CmsEpisode>>>{};
    final logos = <String, String>{};
    var count = 0;
    String absolute(String value) {
      final base = Uri.tryParse(origin);
      return base != null && ['http', 'https'].contains(base.scheme)
          ? resolve(origin, value)
          : value;
    }

    String channelKey(String group, String name) => jsonEncode([group, name]);
    void add(
      String group,
      String name,
      String raw,
      Map<String, String> explicit, {
      String logo = '',
      bool marked = false,
      String label = '',
    }) {
      var value = raw.trim();
      if (value.isEmpty) return;
      final pipe = value.indexOf('|');
      var streamHeaders = explicit;
      if (pipe >= 0) {
        try {
          streamHeaders = merge([
            explicit,
            Uri.splitQueryString(value.substring(pipe + 1)),
          ]);
        } on FormatException {
          return;
        }
        value = value.substring(0, pipe).trim();
      }
      // TXT has no entry marker: an error CSV must not become a relative URL.
      if (!marked &&
          !(Uri.tryParse(value)?.hasScheme ?? false) &&
          !value.startsWith('/') &&
          !value.startsWith('./') &&
          !value.startsWith('../') &&
          !RegExp(
            r'^[^\s?#]+\.(?:m3u8?|mp4|mkv|ts|flv|mp3|aac)(?:[?#]|$)',
            caseSensitive: false,
          ).hasMatch(value))
        return;
      final url = absolute(value);
      final uri = Uri.tryParse(url);
      if (uri == null ||
          !['http', 'https', 'rtmp', 'rtsp'].contains(uri.scheme) ||
          uri.host.isEmpty)
        return;
      final g = group.trim().isEmpty ? '默认频道' : group.trim();
      final c = name.trim().isEmpty ? '未命名频道' : name.trim();
      final streams = groups.putIfAbsent(g, () => {}).putIfAbsent(c, () => []);
      final episode = SourcePlayback.inheritSourceHeaders(
        CmsEpisode(
          name: label.isEmpty ? '线路 ${streams.length + 1}' : label,
          url: url,
          headers: streamHeaders,
        ),
        sourceHeaders: sourceHeaders,
        sourceOrigin: Uri.tryParse(origin),
      );
      if (!streams.any(
        (s) =>
            s.url == url &&
            jsonEncode(s.headers) == jsonEncode(episode.headers),
      )) {
        if (++count > 12000) throw const FormatException('直播线路数量超过限制');
        streams.add(episode);
      }
      final image = absolute(logo);
      if (logo.isNotEmpty &&
          ['http', 'https'].contains(Uri.tryParse(image)?.scheme)) {
        logos.putIfAbsent(channelKey(g, c), () => image);
      }
    }

    List<String> splitUrls(String value) => value.split(
      RegExp(r'#(?=(?:https?|rtmps?|rtsp)://)', caseSensitive: false),
    );
    void jsonItem(
      dynamic item,
      String group,
      Map<String, String> inherited,
      int depth,
    ) {
      if (depth > 24) throw const FormatException('直播目录嵌套过深');
      if (item is List) {
        for (final child in item) {
          jsonItem(child, group, inherited, depth + 1);
        }
        return;
      }
      if (item is! Map) return;
      final h = merge([inherited, headers(item)]);
      for (final field in ['lives', 'groups', 'channels']) {
        if (item[field] is List || item[field] is Map) {
          jsonItem(
            item[field],
            field == 'channels'
                ? '${item['name'] ?? item['group'] ?? group}'
                : group,
            h,
            depth + 1,
          );
          return;
        }
      }
      final g = '${item['group'] ?? item['group-title'] ?? group}';
      final name = '${item['name'] ?? item['title'] ?? '频道'}';
      final logo = '${item['logo'] ?? item['tvg-logo'] ?? ''}';
      final raw = item['urls'] ?? item['url'];
      for (final stream in raw is List ? raw : [raw]) {
        final url = stream is Map ? stream['url'] : stream;
        if (url is! String) continue;
        for (final part in splitUrls(url)) {
          add(
            g,
            name,
            part,
            stream is Map ? merge([h, headers(stream)]) : h,
            logo: logo,
            marked: true,
            label: stream is Map ? '${stream['name'] ?? ''}' : '',
          );
        }
      }
    }

    var text = content.replaceFirst(RegExp(r'^\uFEFF'), '').trim();
    if (!text.startsWith('{') &&
        !text.startsWith('[') &&
        !text.startsWith('"') &&
        !text.startsWith('#EXTM3U') &&
        !text.startsWith('<') &&
        !text.contains('#EXTINF:') &&
        !text.contains(',#genre#') &&
        !text.contains('://')) {
      final unpacked = _tryDecodeBase64LiveText(text);
      if (unpacked != null) text = unpacked;
    }
    dynamic decoded;
    final cleanedText = CmsParser.stripJsonComments(text);
    if (cleanedText.startsWith('[') ||
        cleanedText.startsWith('{') ||
        cleanedText.startsWith('"')) {
      decoded = jsonDecode(cleanedText);
      if (decoded is String) {
        text = decoded.trim();
        final innerCleaned = CmsParser.stripJsonComments(text);
        decoded = innerCleaned.startsWith('[') || innerCleaned.startsWith('{')
            ? jsonDecode(innerCleaned)
            : null;
      }
    }
    if (decoded is Map || decoded is List) {
      jsonItem(decoded, '直播频道', {}, 0);
    } else {
      final lines = const LineSplitter().convert(text);
      if (lines.length > 60000) throw const FormatException('直播列表行数超过限制');
      var group = '精选频道';
      var title = '', m3uGroup = '', logo = '';
      var pendingHeaders = <String, String>{};
      for (final raw in lines) {
        final line = raw.trim();
        if (line.isEmpty) continue;
        if (line.startsWith('#EXTINF:')) {
          // The first comma outside quoted attributes separates the full title.
          String? quote;
          var comma = -1;
          for (var i = 0; i < line.length; i++) {
            final ch = line[i];
            if (quote != null) {
              if (ch == quote) quote = null;
            } else if (ch == '"' || ch == "'") {
              quote = ch;
            } else if (ch == ',') {
              comma = i;
              break;
            }
          }
          final attrs = <String, String>{
            for (final m in RegExp(
              r'''([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')''',
            ).allMatches(comma < 0 ? line : line.substring(0, comma)))
              m.group(1)!.toLowerCase(): m.group(2) ?? m.group(3) ?? '',
          };
          title = comma >= 0
              ? line.substring(comma + 1).trim()
              : attrs['tvg-name'] ?? '频道';
          if (title.isEmpty) title = (attrs['tvg-name'] ?? '').trim().isNotEmpty ? attrs['tvg-name']!.trim() : '频道';
          m3uGroup = attrs['group-title'] ?? '直播频道';
          logo = attrs['tvg-logo'] ?? '';
          pendingHeaders = {};
          continue;
        }
        if (line.startsWith('#EXTVLCOPT:') && title.isNotEmpty) {
          final option = line.substring('#EXTVLCOPT:'.length);
          final equals = option.indexOf('=');
          if (equals > 0) {
            final key = {
              'http-user-agent': 'User-Agent',
              'http-referrer': 'Referer',
              'http-referer': 'Referer',
              'http-origin': 'Origin',
            }[option.substring(0, equals).toLowerCase()];
            if (key != null) pendingHeaders[key] = option.substring(equals + 1);
          }
          continue;
        }
        if (line.startsWith('#EXTGRP:') && title.isNotEmpty) {
          m3uGroup = line.substring('#EXTGRP:'.length);
          continue;
        }
        if (line.startsWith('#')) continue;
        if (title.isNotEmpty) {
          add(m3uGroup, title, line, pendingHeaders, logo: logo, marked: true);
          title = '';
          logo = '';
          pendingHeaders = {};
          continue;
        }
        if (line.toLowerCase().endsWith(',#genre#')) {
          group = line.substring(0, line.length - 8).trim();
          continue;
        }
        final comma = line.indexOf(',');
        if (comma <= 0) continue;
        for (final url in splitUrls(line.substring(comma + 1))) {
          add(group, line.substring(0, comma), url, {});
        }
      }
    }
    return [
      for (final g in groups.entries)
        LiveGroup(
          name: g.key,
          channels: [
            for (final c in g.value.entries)
              LiveChannel(
                name: c.key,
                group: g.key,
                urls: c.value.map((e) => e.url).toList(growable: false),
                streams: c.value,
                logo: logos[channelKey(g.key, c.key)] ?? '',
              ),
          ],
        ),
    ];
  }
}
