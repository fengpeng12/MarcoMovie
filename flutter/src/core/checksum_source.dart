import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

class ChecksumSource {
  static bool matches(Uri? url) =>
      url != null &&
      ['http', 'https'].contains(url.scheme) &&
      url.path.toLowerCase().endsWith('.js.md5');

  static Future<({String source, Uri script})> read(Uri link) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    final timer = Timer(
      const Duration(seconds: 25),
      () => client.close(force: true),
    );
    final clean = link.replace(userInfo: '').removeFragment();
    final auth = link.userInfo.isEmpty
        ? null
        : 'Basic ${base64.encode(utf8.encode(Uri.decodeComponent(link.userInfo)))}';
    Future<Uint8List> fetch(Uri url, int limit) async {
      final req = await client.getUrl(url);
      req.followRedirects = false;
      req.headers.set('User-Agent', 'okhttp/3.15');
      if (auth != null) req.headers.set('Authorization', auth);
      final response = await req.close();
      if (response.statusCode != 200)
        throw HttpException('脚本订阅读取失败（HTTP ${response.statusCode}）');
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        if (bytes.length + chunk.length > limit)
          throw const FormatException('脚本订阅超过大小限制');
        bytes.add(chunk);
      }
      return bytes.takeBytes();
    }

    try {
      final digest = utf8.decode(await fetch(clean, 1024)).trim().toLowerCase();
      if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(digest))
        throw const FormatException('订阅没有返回有效的 MD5 摘要');
      final script = clean.replace(
        path: clean.path.substring(0, clean.path.length - 4),
      );
      final bytes = await fetch(script, 16 * 1024 * 1024);
      if (md5.convert(bytes).toString() != digest)
        throw const FormatException('脚本校验不一致，请稍后重新导入');
      final source = utf8.decode(bytes);
      final service = source.contains('catServerFactory') && source.contains('catDartServerPort');
      if (!service && bytes.length > 6 * 1024 * 1024)
        throw const FormatException('独立来源脚本超过 6 MB');
      return (source: source, script: script);
    } finally {
      timer.cancel();
      client.close(force: true);
    }
  }
}
