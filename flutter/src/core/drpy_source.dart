import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'catpaw_host.dart';
import 'cms_parser.dart';
import 'models.dart';

/// Adapts declarative DRPY rules to the bundled, pinned local rule engine.
/// A remote Spider engine is never replaced just because its name says drpy.
class DrpySource {
  final CatPawHost host;
  final Future<String> Function(String, Map<String, String>) read;
  final _installed = <String, ({String address, DateTime expires})>{};
  final _pending = <String, Future<String>>{};

  DrpySource({required this.host, required this.read});

  String _key(CmsSite site) => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            site.subscriptionId,
            site.sourceKey,
            site.isEffectivelyPrivate,
            site.api,
            site.pluginReference,
            site.ext,
            site.headers,
          ]),
        ),
      )
      .toString();

  Future<String?> callCached(
    CmsSite site,
    String method,
    List<Object?> args, {
    Completer<void>? cancellation,
  }) async {
    _checkCancellation(cancellation);
    final value = _installed[_key(site)];
    if (value == null || DateTime.now().isAfter(value.expires)) return null;
    return host.callDrpy(
      value.address,
      method,
      args,
      cancellation: cancellation,
    );
  }

  Future<String> invoke(
    CmsSite site,
    String method,
    List<Object?> args, {
    String? rule,
    String? origin,
    Completer<void>? cancellation,
  }) async {
    _checkCancellation(cancellation);
    final key = _key(site);
    final cached = _installed[key];
    String address;
    if (cached != null && DateTime.now().isBefore(cached.expires)) {
      address = cached.address;
    } else {
      // A cancellable download belongs to its caller's abort context. Do not
      // share it with another search/detail request that must remain alive.
      final task =
          _pending[key] ??
          (cancellation == null
              ? _pending.putIfAbsent(
                  key,
                  () => _install(site, rule, origin, null),
                )
              : _install(site, rule, origin, cancellation));
      try {
        address = await _withCancellation(task, cancellation);
        _checkCancellation(cancellation);
        // Bound references as well as worker count; failures are never cached.
        if (_installed.length >= 64) _installed.remove(_installed.keys.first);
        _installed[key] = (
          address: address,
          expires: DateTime.now().add(const Duration(minutes: 5)),
        );
      } finally {
        if (identical(_pending[key], task)) _pending.remove(key);
      }
    }
    _checkCancellation(cancellation);
    return host.callDrpy(address, method, args, cancellation: cancellation);
  }

  Future<String> _install(
    CmsSite site,
    String? body,
    String? suppliedOrigin,
    Completer<void>? cancellation,
  ) async {
    _checkCancellation(cancellation);
    var origin = suppliedOrigin ?? '';
    var rule = body ?? '';
    final modules = <String, String>{};
    if (body == null) {
      Object? extension = site.ext;
      try {
        extension = jsonDecode(site.ext);
      } on FormatException {
        /* Text or URL. */
      }
      if (site.api == 'csp_LocalRule.js') {
        if (extension is! Map || extension['script'] is! String) {
          throw const FormatException('本地规则缺少脚本内容');
        }
        rule = extension['script'] as String;
        origin = (extension['origin'] ?? '').toString();
        if (extension['modules'] is Map) {
          modules.addAll(Map<String, String>.from(extension['modules'] as Map));
        }
      } else if (extension is Map) {
        // Explicit csp_Drpy may contain a JSON rule, without executable functions.
        rule = 'var rule = ${jsonEncode(extension)};';
      } else if (extension is String) {
        var uri = Uri.tryParse(extension.trim());
        if (uri != null &&
            !uri.hasScheme &&
            site.isHttpApi &&
            (extension.trim().startsWith('./') ||
                extension.trim().startsWith('../') ||
                extension.trim().startsWith('/') ||
                RegExp(r'\.(?:m?js|json|txt)(?:[?#]|$)', caseSensitive: false)
                    .hasMatch(extension.trim()))) {
          uri = Uri.tryParse(site.api)?.resolveUri(uri);
        }
        if (uri != null &&
            ['https', 'http'].contains(uri.scheme) &&
            uri.host.isNotEmpty) {
          origin = uri.toString();
          rule = await read(origin, site.headers);
          _checkCancellation(cancellation);
        } else {
          rule = extension;
        }
      }
    }
    if (!CmsParser.looksLikeDrpyRule(rule)) {
      throw const FormatException('此来源没有可用的 DRPY 规则；独立 Spider 脚本需要保留原运行方式');
    }
    if (body == null &&
        rule.contains('muban') &&
        !RegExp(r'\b(?:var|let|const)\s+muban\b').hasMatch(rule)) {
      rule =
          'var muban = typeof 模板 !== "undefined" && 模板.getMubans ? 模板.getMubans() : {};\n$rule';
    }
    if (origin.isEmpty) origin = 'pkg://local/rule.js';
    final uri = Uri.tryParse(origin);
    if (uri == null || !['http', 'https', 'pkg'].contains(uri.scheme)) {
      throw const FormatException('规则来源地址无效');
    }
    final headers = Map<String, String>.from(site.headers);
    if (uri.userInfo.isNotEmpty &&
        !headers.keys.any((name) => name.toLowerCase() == 'authorization')) {
      headers['Authorization'] =
          'Basic ${base64Encode(utf8.encode(Uri.decodeComponent(uri.userInfo)))}';
    }
    origin = uri.removeFragment().replace(userInfo: '').toString();
    final identity = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              site.subscriptionId,
              site.sourceKey,
              site.isEffectivelyPrivate,
              if (site.subscriptionId.isEmpty) ...[
                site.api,
                site.pluginReference,
                origin,
                if (uri.scheme == 'pkg')
                  sha256.convert(utf8.encode(rule)).toString(),
              ],
            ]),
          ),
        )
        .toString();
    _checkCancellation(cancellation);
    final address = await host.installDrpy({
      'kind': 'drpy',
      'version': 1,
      'runtime': CatPawHost.drpyRuntime,
      'sourceId': identity,
      'origin': origin,
      'rule': rule,
      'headers': headers,
      if (modules.isNotEmpty) 'modules': modules,
      'requestTimeoutMs': 12000,
    });
    _checkCancellation(cancellation);
    return address;
  }

  static void _checkCancellation(Completer<void>? cancellation) {
    if (cancellation?.isCompleted == true) throw const FormatException('搜索已取消');
  }

  static Future<T> _withCancellation<T>(
    Future<T> task,
    Completer<void>? cancellation,
  ) {
    if (cancellation?.isCompleted == true) {
      unawaited(task.then<void>((_) {}, onError: (Object _) {}));
    }
    _checkCancellation(cancellation);
    if (cancellation == null) return task;
    return Future.any([
      task,
      cancellation.future.then<T>((_) => throw const FormatException('搜索已取消')),
    ]);
  }
}
