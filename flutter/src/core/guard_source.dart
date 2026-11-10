import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'catpaw_host.dart';
import 'csp_bridge.dart';
import 'drpy_source.dart';
import 'models.dart';

/// Ports only explicitly reviewed plugin versions. Plugin bytes are treated as
/// data; the local bootstrap never executes the imported Android implementation.
class GuardSource {
  static const maxArtifactBytes = 16 * 1024 * 1024;
  final CatPawHost host;
  final DrpySource drpy;
  final Future<Uint8List> Function(String, Map<String, String>) read;
  final _cache = <String, ({String rule, String origin, DateTime expires})>{};

  GuardSource({required this.host, required this.drpy, required this.read});

  static bool supports(CmsSite site) =>
      CspBridge.guardAdapterFor(site) != null &&
      site.pluginReference.trim().isNotEmpty;

  Future<String> invoke(
    CmsSite site,
    String method,
    List<Object?> args, {
    Completer<void>? cancellation,
  }) async {
    void checkCancelled() {
      if (cancellation?.isCompleted == true)
        throw const FormatException('搜索已取消');
    }

    checkCancelled();
    final adapter = CspBridge.guardAdapterFor(site);
    if (adapter == null) throw const FormatException('此插件没有已审阅的移植适配器');
    if (adapter == 't4-v1' &&
        (site.ext.trim().isEmpty || utf8.encode(site.ext).length > 16 * 1024)) {
      throw const FormatException('T4 需要订阅中的完整扩展配置');
    }
    if (adapter == 'auete-v1' || adapter == 'bttwoo-v1') {
      Object? extension;
      try {
        extension = jsonDecode(site.ext);
      } catch (_) {
        /* Non-JSON ext has no mapped override. */
      }
      if (extension is Map &&
          extension['siteUrl'] != null &&
          extension['siteUrl'].toString().trim().isNotEmpty) {
        final name = adapter == 'auete-v1' ? 'Auete' : 'Bttwoo';
        throw FormatException('$name 自定义 siteUrl 变体暂未适配');
      }
    }
    final key = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              adapter,
              site.subscriptionId,
              site.sourceKey,
              site.isEffectivelyPrivate,
              site.pluginReference,
              site.headers,
              if (adapter == 't4-v1') site.ext,
            ]),
          ),
        )
        .toString();
    var item = _cache[key];
    final declaration = site.pluginReference;
    final marker = RegExp(
      ';md5;',
      caseSensitive: false,
    ).firstMatch(declaration);
    final address =
        (marker == null ? declaration : declaration.substring(0, marker.start))
            .trim();
    final expected = marker == null ? null : declaration.substring(marker.end);
    if (expected != null && !RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(expected)) {
      throw const FormatException('插件摘要格式无效，请检查订阅中的完整地址');
    }
    final artifact = Uri.tryParse(address);
    if (artifact == null ||
        !['http', 'https'].contains(artifact.scheme) ||
        artifact.host.isEmpty) {
      throw const FormatException('此插件需要订阅提供完整的 HTTP(S) 插件地址');
    }
    if (item == null || DateTime.now().isAfter(item.expires)) {
      final bytes = await read(address, site.headers);
      checkCancelled();
      if (bytes.isEmpty || bytes.length > maxArtifactBytes) {
        throw const FormatException('插件包为空或超过 16 MB');
      }
      if (expected != null &&
          md5.convert(bytes).toString() != expected.toLowerCase()) {
        throw const FormatException('插件摘要校验失败，请刷新原订阅后重试');
      }
      final generated = await host.bootstrapGuard(
        bytes,
        adapter: adapter,
        extension: adapter == 't4-v1' ? site.ext : null,
        cancellation: cancellation,
      );
      checkCancelled();
      item = (
        rule: generated['rule'] as String,
        origin: generated['origin'] as String,
        expires: DateTime.now().add(const Duration(minutes: 5)),
      );
      if (_cache.length >= 32) _cache.remove(_cache.keys.first);
      _cache[key] = item;
    }
    final target = Uri.parse(item.origin);
    final sameOrigin =
        artifact.scheme == target.scheme &&
        artifact.host == target.host &&
        artifact.port == target.port;
    final runtimeHeaders = Map<String, String>.fromEntries(
      site.headers.entries.where(
        (entry) =>
            sameOrigin ||
            !const [
              'authorization',
              'cookie',
              'cookie2',
              'proxy-authorization',
            ].contains(entry.key.toLowerCase()),
      ),
    );
    // Import/download credentials belong to the plugin origin, not to endpoints
    // extracted from its content. Explicit rule playback headers remain intact.
    return drpy.invoke(
      site.copyWith(
        // Namespace only the internal DRPY identity. Preserve the original
        // subscription/history identity and the existing DM84 state location.
        subscriptionId: adapter == 'dm84-v1'
            ? site.subscriptionId
            : jsonEncode([
                'guard-adapter',
                adapter,
                site.subscriptionId,
                if (site.subscriptionId.isEmpty) ...[
                  site.pluginReference,
                  item.origin,
                ],
              ]),
        headers: runtimeHeaders,
        ext: jsonEncode({
          'ruleHash': sha256.convert(utf8.encode(item.rule)).toString(),
          'originalExt': site.ext,
        }),
      ),
      method,
      args,
      rule: item.rule,
      origin: item.origin,
      cancellation: cancellation,
    );
  }
}
