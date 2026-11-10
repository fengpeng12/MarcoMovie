import 'dart:convert';
import 'package:html/parser.dart' as html;
import 'csp_bridge.dart' show CspHttpTextFetcher;
import 'models.dart';

/// Device-local adapter for the trailer catalog selected by the imported YGP spider.
class TrailerSource {
  static final _origin = Uri.https('www.6huo.com', '/');
  static const category = CmsCategory(id: 'allmovies', name: '新片预告');
  static bool matches(CmsSite s) =>
      const {'csp_ygp', 'csp_ygpguard'}.contains(s.api.toLowerCase());

  static Future<CmsListing> list(
    int page,
    String query,
    CspHttpTextFetcher fetch,
  ) async {
    final uri = query.isEmpty
        ? _origin.resolve(page == 1 ? 'allmovies' : 'allmovies/$page')
        : _origin.replace(
            queryParameters: {
              'view': 'search',
              'keyword': query,
              if (page > 1) 'page': '$page',
            },
          );
    final doc = html.parse(await fetch(uri.toString()));
    final videos = <CmsVideo>[];
    final seen = <String>{};
    for (final card in doc.querySelectorAll('.movlist a[href]')) {
      final id = card.attributes['href'] ?? '';
      if (!RegExp(r'^/movie/\d+$').hasMatch(id) || !seen.add(id)) continue;
      final image = card.querySelector('img');
      final title =
          (card.querySelector('.item-title')?.text ??
                  image?.attributes['alt'] ??
                  '')
              .trim();
      if (title.isEmpty) continue;
      final pic = image?.attributes['src'];
      videos.add(
        CmsVideo(
          id: id,
          title: title,
          poster: pic == null ? '' : _origin.resolve(pic).toString(),
          remarks: card.querySelector('.item-pubtime')?.text.trim() ?? '',
        ),
      );
    }
    final next = doc
        .querySelectorAll('a')
        .any((a) => a.text.trim() == '下一页' && a.attributes['href'] != null);
    return CmsListing(
      page: page,
      pageCount: next ? page + 1 : page,
      videos: videos,
    );
  }

  static Future<CmsVideo> detail(
    CmsVideo card,
    CspHttpTextFetcher fetch,
  ) async {
    if (!RegExp(r'^/movie/\d+$').hasMatch(card.id))
      throw const FormatException('预告片编号无效');
    final doc = html.parse(await fetch(_origin.resolve(card.id).toString()));
    final episodes = <CmsEpisode>[];
    for (final row in doc.querySelectorAll('tr')) {
      final ref =
          row.querySelector('a[href^="/download/"]')?.attributes['href'] ?? '';
      if (!RegExp(r'^/download/\d+$').hasMatch(ref)) continue;
      final title = row.querySelector('.tlist-bbs-tdtitle')?.text.trim();
      episodes.add(
        CmsEpisode(
          name: title == null || title.isEmpty ? '预告片' : title,
          url: _origin.resolve(ref).toString(),
        ),
      );
    }
    return CmsVideo(
      id: card.id,
      title: card.title,
      poster: card.poster,
      remarks: card.remarks,
      year: card.year,
      lines: [
        if (episodes.isNotEmpty) CmsLine(name: '预告片', episodes: episodes),
      ],
    );
  }

  static Future<CmsEpisode> resolve(
    CmsEpisode ep,
    CspHttpTextFetcher fetch,
  ) async {
    final uri = Uri.parse(ep.url);
    if (uri.origin != _origin.origin ||
        !RegExp(r'^/download/\d+$').hasMatch(uri.path)) {
      throw const FormatException('预告片线路无效');
    }
    final data = jsonDecode(
      await fetch(
        _origin
            .replace(
              queryParameters: {
                'view': 'api',
                'mode': 'download-data',
                'ttid': uri.pathSegments.last,
              },
            )
            .toString(),
        headers: {'Referer': ep.url},
      ),
    );
    if (data is List) {
      for (final item in data.whereType<Map>()) {
        final url = Uri.tryParse(item['movurl']?.toString() ?? '');
        if (url != null &&
            ['http', 'https'].contains(url.scheme) &&
            url.host.isNotEmpty) {
          return CmsEpisode(
            name: ep.name,
            url: url.toString(),
            headers: {'Referer': ep.url},
          );
        }
      }
    }
    throw const FormatException('站点未提供此预告的媒体地址，可选择其他预告');
  }
}
