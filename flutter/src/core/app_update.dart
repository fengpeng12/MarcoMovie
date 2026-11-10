import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

class AppUpdate {
  final String version;
  final String notes;
  final Uri? windowsUrl;
  final String? checksum;
  final int? size;
  const AppUpdate(this.version, this.notes, this.windowsUrl, this.checksum, this.size);

  static Uri? trustedAsset(dynamic value) {
    final uri = Uri.tryParse(value?.toString() ?? '');
    if (uri == null || uri.scheme != 'https' || uri.userInfo.isNotEmpty || uri.hasFragment ||
        (uri.hasPort && uri.port != 443)) return null;
    if (uri.host == 'github.com' && uri.path.startsWith('/Pilipala9919/MarcoMovie/releases/download/') ||
        uri.host == 'marcotv.wlj9919.top' && uri.path.startsWith('/movie/')) return uri;
    return null;
  }

  static AppUpdate parse(Map<String, dynamic> json, {bool github = false, String platform = 'windows'}) {
    if (!github && json['platform'] != null && json['platform'] != platform) {
      throw const FormatException('更新包平台不匹配');
    }
    final raw = (github ? json['tag_name'] : json['versionName'])?.toString() ?? '';
    final normalized = raw.startsWith('$platform-') ? raw.substring(platform.length + 1) : raw;
    final match = RegExp(r'^[vV]?(\d+\.\d+\.\d+)(?:-preview)?$').firstMatch(normalized.trim());
    if (match == null) throw const FormatException('更新版本信息无效');
    final version = match.group(1)!;
    Map? asset;
    if (github) {
      final assets = json['assets'];
      if (assets is List) {
        for (final item in assets.whereType<Map>()) {
          if (item['name'] == 'MarcoMovie-$version-windows-setup.exe') asset = item;
        }
      }
    } else if (json['windows'] is Map) {
      asset = json['windows'] as Map;
    }
    final data = asset ?? const <String, dynamic>{};
    final digest = (github ? data['digest'] : data['sha256'])?.toString().replaceFirst('sha256:', '');
    final size = data['size'];
    final uri = trustedAsset(github ? data['browser_download_url'] : data['url']);
    final verified = platform == 'windows' && uri != null && uri.path.endsWith('/MarcoMovie-$version-windows-setup.exe') &&
        digest != null && RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(digest) && size is int && size > 0;
    return AppUpdate(version, (json[github ? 'body' : 'notes'] ?? '').toString(),
        verified ? uri : null, verified ? digest.toLowerCase() : null, verified ? size : null);
  }

  static String get currentPlatform => Platform.isWindows ? 'windows' : Platform.isIOS ? 'ios' : Platform.isMacOS ? 'macos' : 'android';

  static String _suffix(String platform) => switch (platform) {
    'windows' => 'windows-setup.exe',
    'ios' => 'ios-unsigned.ipa',
    'macos' => 'macos.zip',
    'android' => 'mobile.apk',
    _ => throw const FormatException('不支持的更新平台'),
  };

  static AppUpdate _githubRelease(dynamic body, String platform) {
    final candidates = <AppUpdate>[];
    for (final item in (body is List ? body : [body]).whereType<Map>()) {
      if (item['draft'] == true || item['prerelease'] == true) continue;
      try {
        final release = parse(Map<String, dynamic>.from(item), github: true, platform: platform);
        final name = 'MarcoMovie-${release.version}-${_suffix(platform)}';
        final assets = item['assets'];
        if (assets is! List || !assets.whereType<Map>().any((asset) =>
            asset['name'] == name && trustedAsset(asset['browser_download_url']) != null)) continue;
        if (platform == 'windows' && release.windowsUrl == null) continue;
        candidates.add(release);
      } on FormatException { /* Another platform's release or malformed entry. */ }
    }
    if (candidates.isEmpty) throw const FormatException('没有当前平台的正式更新');
    candidates.sort((a, b) {
      final av = a.version.split('.').map(int.parse).toList();
      final bv = b.version.split('.').map(int.parse).toList();
      for (var i = 0; i < av.length; i++) {
        if (av[i] != bv[i]) return bv[i].compareTo(av[i]);
      }
      return 0;
    });
    return candidates.first;
  }

  static Future<AppUpdate> check({http.Client? client, String? platform}) async {
    platform ??= currentPlatform;
    _suffix(platform);
    final transport = client ?? http.Client();
    try {
      for (final url in [
        'https://marcotv.wlj9919.top/movie/updates/$platform.json',
        'https://api.github.com/repos/Pilipala9919/MarcoMovie/releases?per_page=100',
      ]) {
        try {
          final response = await transport.get(Uri.parse(url), headers: {
            'User-Agent': 'MarcoMovie-Updater', 'Cache-Control': 'no-cache',
          }).timeout(const Duration(seconds: 12));
          if (response.statusCode != 200) continue;
          final body = jsonDecode(response.body);
          if (url.contains('api.github.com')) return _githubRelease(body, platform);
          if (body is! Map<String, dynamic> || body['prerelease'] == true) continue;
          final release = parse(body, platform: platform);
          if (platform == 'windows' && release.windowsUrl == null) continue;
          return release;
        } catch (_) { /* Try the second release endpoint. */ }
      }
      throw const HttpException('暂时无法检查更新，请稍后重试');
    } finally {
      if (client == null) transport.close();
    }
  }

  Future<void> verifyFile(File file) async {
    if (windowsUrl == null || size == null || checksum == null || await file.length() != size) {
      throw const FormatException('更新包大小不符或缺少校验信息');
    }
    final digest = await sha256.bind(file.openRead()).first;
    if (digest.toString() != checksum) throw const FormatException('更新包校验失败，请重新下载');
  }
}
