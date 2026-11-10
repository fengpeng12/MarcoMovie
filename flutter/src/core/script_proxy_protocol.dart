import 'dart:convert';
import 'dart:typed_data';

import 'script_proxy_server.dart';

/// Buffered FongMi/TVBox Spider proxy result: [status, MIME, body, headers?, b64?].
/// Native stream handles are deliberately not interpreted as URLs or objects.
class ScriptProxyProtocol {
  static const _maxJsonCharacters = 25 * 1024 * 1024;
  static const _maxHeaderBytes = 16 * 1024;
  static final _headerName = RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$");
  static final _mime = RegExp(
    r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+/[!#$%&'*+.^_`|~0-9A-Za-z-]+(?: *;[^\r\n]*)?$",
  );

  static ScriptProxyResponse decode(Object? raw) {
    Object? value = raw;
    if (value is String) {
      if (value.length > _maxJsonCharacters) {
        throw const FormatException('代理响应过大');
      }
      try {
        value = jsonDecode(value);
      } on FormatException {
        // Parser diagnostics may contain the user's private media URL or token.
        throw const FormatException('代理响应不是有效的 JSON 数组');
      }
    }
    if (value is! List || value.length < 3 || value.length > 5) {
      throw const FormatException('代理响应必须包含状态、类型和正文');
    }
    final status = value[0];
    final mime = value[1];
    if (status is! int || status < 200 || status > 599) {
      throw const FormatException('代理响应状态无效');
    }
    if (mime is! String ||
        mime.length > 256 ||
        !_mime.hasMatch(mime) ||
        RegExp(r'[\x00-\x1f\x7f-\uffff]').hasMatch(mime)) {
      throw const FormatException('代理响应类型无效');
    }
    final flag = value.length == 5 ? value[4] : 0;
    if (flag is! int || (flag != 0 && flag != 1)) {
      throw const FormatException('代理响应编码标记无效');
    }
    final headers = _headers(value.length > 3 ? value[3] : null);
    final body = _body(value[2], flag == 1);
    return ScriptProxyResponse(
      statusCode: status,
      contentType: mime,
      body: body,
      headers: headers,
    );
  }

  static Map<String, String> _headers(Object? raw) {
    if (raw == null) return const {};
    if (raw is! Map || raw.length > 64) {
      throw const FormatException('代理响应头无效');
    }
    final result = <String, String>{};
    final names = <String>{};
    var bytes = 0;
    for (final entry in raw.entries) {
      final name = entry.key;
      final value = entry.value;
      if (name is! String ||
          value is! String ||
          !_headerName.hasMatch(name) ||
          RegExp(r'[\x00-\x08\x0a-\x1f\x7f\u0100-\uffff]').hasMatch(value) ||
          !names.add(name.toLowerCase())) {
        throw const FormatException('代理响应头无效');
      }
      bytes += utf8.encode(name).length + utf8.encode(value).length;
      if (bytes > _maxHeaderBytes) throw const FormatException('代理响应头过大');
      result[name] = value;
    }
    return Map.unmodifiable(result);
  }

  static Uint8List _body(Object? value, bool encoded) {
    const limit = ScriptProxyServer.maxResponseBytes;
    // The original Python host handles bytes before examining the Base64 flag.
    if (value is List) {
      if (value.length > limit) throw const FormatException('代理正文过大');
      final result = Uint8List(value.length);
      for (var i = 0; i < value.length; i++) {
        final byte = value[i];
        if (byte is! int || byte < 0 || byte > 255) {
          throw const FormatException('代理二进制正文无效');
        }
        result[i] = byte;
      }
      return result;
    }
    if (value is! String) {
      throw const FormatException('代理正文必须是文字或字节数组');
    }
    if (!encoded) {
      if (value.length > limit) throw const FormatException('代理正文过大');
      final result = utf8.encode(value);
      if (result.length > limit) throw const FormatException('代理正文过大');
      return result;
    }
    const maxEncoded = ((limit + 2) ~/ 3) * 4;
    if (value.length > maxEncoded + 1280) {
      throw const FormatException('代理正文过大');
    }
    var text = value;
    if (text.startsWith('data:')) {
      final separator = text.indexOf(',');
      if (separator < 0 ||
          separator > 256 ||
          !RegExp(
            r'^data:[\x20-\x7e]*;base64$',
          ).hasMatch(text.substring(0, separator))) {
        throw const FormatException('代理 Base64 正文无效');
      }
      text = text.substring(separator + 1);
    }
    // MIME Base64 may be line-wrapped; no other characters or missing padding
    // are accepted, and decoded unused bits must have the canonical encoding.
    text = text.replaceAll(RegExp(r'[ \t\r\n]'), '');
    if (text.length > maxEncoded ||
        text.length % 4 != 0 ||
        !RegExp(r'^[A-Za-z0-9+/]*={0,2}$').hasMatch(text)) {
      throw const FormatException('代理 Base64 正文无效');
    }
    final result = base64Decode(text);
    if (result.length > limit || base64Encode(result) != text) {
      throw const FormatException('代理 Base64 正文无效');
    }
    return result;
  }
}
