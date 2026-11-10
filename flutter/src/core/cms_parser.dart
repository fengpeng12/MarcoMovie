import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'js_source_syntax.dart';
import 'models.dart';
import 'live_catalog_parser.dart';
/// Pure Dart parser for Marco Movie / TVBox JSON & XML CMS, multi-depot configs,
/// obfuscated/encrypted config payloads (**Base64, Base64, $#...#$ AES-128-CBC),
/// Punycode IDN URLs, M3U/TXT live playlists, and cross-platform backups.
class CmsParser {
  static const int maxHistoryEntries = 60;
  static const int maxFavoriteEntries = 120;
  static const int episodePageSize = 50;
  /// Extracts an HTTP(S) URL from user input (which may contain surrounding Chinese notes,
  /// smart quotes, or omit the scheme) and normalizes non-ASCII IDN domain labels to Punycode.
  static String extractAndNormalizeUrl(String rawInput) {
    var s = rawInput
        .trim()
        .replaceAll('“', '"')
        .replaceAll('”', '"')
        .replaceAll('‘', "'")
        .replaceAll('’', "'")
        .replaceAll('：', ':')
        .replaceAll('／', '/');
    if (s.isEmpty) return '';
    final explicitHttp = RegExp(
      r'''https?://[^\s"'<>`|]+''',
      caseSensitive: false,
    ).firstMatch(s);
    if (explicitHttp != null) {
      s = explicitHttp.group(0)!;
    } else if (!s.startsWith('{') &&
        !s.startsWith('[') &&
        !s.startsWith('http://') &&
        !s.startsWith('https://') &&
        s.contains('.') &&
        !s.contains('\n')) {
      final token = s.split(RegExp(r'\s+')).first;
      s = ['http', '://', token].join();
    }
    return normalizeUrl(s);
  }
  /// Normalizes an HTTP(S) URL including converting non-ASCII domain names (e.g. `肥猫.com`) to RFC 3492 Punycode.
  static String normalizeUrl(String rawUrl) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) return '';
    final schemeMatch =
        RegExp(r'^(https?)://([^/?#]+)(.*)$', caseSensitive: false)
            .firstMatch(trimmed);
    if (schemeMatch == null) return trimmed;
    final scheme = schemeMatch.group(1)!.toLowerCase();
    final authority = schemeMatch.group(2)!;
    final rest = schemeMatch.group(3) ?? '';
    String userInfo = '';
    String hostPort = authority;
    final atIdx = authority.lastIndexOf('@');
    if (atIdx >= 0) {
      userInfo = authority.substring(0, atIdx + 1);
      hostPort = authority.substring(atIdx + 1);
    }
    String host = hostPort;
    String port = '';
    if (!hostPort.startsWith('[')) {
      final colonIdx = hostPort.lastIndexOf(':');
      if (colonIdx > 0) {
        host = hostPort.substring(0, colonIdx);
        port = hostPort.substring(colonIdx);
      }
      host = _idnToAscii(host);
    }
    return '$scheme://$userInfo$host$port$rest';
  }
  static String _idnToAscii(String domain) {
    final normalized = domain
        .replaceAll('\u3002', '.')
        .replaceAll('\uFF0E', '.')
        .replaceAll('\uFF61', '.');
    final labels = normalized.split('.');
    final out = <String>[];
    for (final label in labels) {
      if (label.isEmpty) {
        out.add('');
        continue;
      }
      final isAscii = label.runes.every((r) => r < 0x80);
      if (isAscii) {
        out.add(label);
      } else {
        out.add('xn--${_punycodeEncode(label.toLowerCase())}');
      }
    }
    return out.join('.');
  }
  static String _punycodeEncode(String input) {
    const int base = 36;
    const int tMin = 1;
    const int tMax = 26;
    const int skew = 38;
    const int damp = 700;
    const int initialBias = 72;
    const int initialN = 0x80;
    int adapt(int delta, int numPoints, bool firstTime) {
      var d = firstTime ? (delta ~/ damp) : (delta >> 1);
      d += d ~/ numPoints;
      int k = 0;
      while (d > ((base - tMin) * tMax) ~/ 2) {
        d ~/= (base - tMin);
        k += base;
      }
      return k + (((base - tMin + 1) * d) ~/ (d + skew));
    }
    int encodeDigit(int d) => d + 22 + 75 * (d < 26 ? 1 : 0);
    final codePoints = input.runes.toList(growable: false);
    final output = StringBuffer();
    int basicCount = 0;
    for (final cp in codePoints) {
      if (cp < 0x80) {
        output.writeCharCode(cp);
        basicCount++;
      }
    }
    if (basicCount > 0) {
      output.write('-');
    }
    int n = initialN;
    int delta = 0;
    int bias = initialBias;
    int handled = basicCount;
    while (handled < codePoints.length) {
      int m = 0x7fffffff;
      for (final cp in codePoints) {
        if (cp >= n && cp < m) m = cp;
      }
      delta += (m - n) * (handled + 1);
      n = m;
      for (final cp in codePoints) {
        if (cp < n) {
          delta++;
        } else if (cp == n) {
          int q = delta;
          for (int k = base;; k += base) {
            final t = k <= bias
                ? tMin
                : (k >= bias + tMax ? tMax : k - bias);
            if (q < t) break;
            output.writeCharCode(encodeDigit(t + ((q - t) % (base - t))));
            q = (q - t) ~/ (base - t);
          }
          output.writeCharCode(encodeDigit(q));
          bias = adapt(delta, handled + 1, handled == basicCount);
          delta = 0;
          handled++;
        }
      }
      delta++;
      n++;
    }
    return output.toString();
  }
  /// Decodes raw bytes from an HTTP config response or local file, supporting:
  /// 1. Image/binary steganography (`JPEG`/`PNG` + `**` + Base64)
  /// 2. Text + `**` + Base64
  /// 3. Hex `$#...#$` (`2423...`) AES-128-CBC encrypted TVBox payload
  /// 4. Pure Base64 JSON
  /// 5. Standard UTF-8 JSON (with BOM, comments, or trailing commas)
  static List<int> _gunzipIfNeeded(List<int> bytes) {
    if (bytes.length >= 2 && (bytes[0] & 0xFF) == 0x1F && (bytes[1] & 0xFF) == 0x8B) {
      try { return const GZipDecoder().decodeBytes(bytes); } catch (_) {}
    }
    return bytes;
  }

  static String decodeConfigDocument(List<int> rawBytes) {
    final bytes = _gunzipIfNeeded(rawBytes);
    // Check for `**` marker in raw bytes (used by JPEG/PNG + ** + Base64 configs)
    int starMarker = -1;
    for (int i = bytes.length - 2; i >= 0; i--) {
      if (bytes[i] == 0x2A && bytes[i + 1] == 0x2A) {
        final tailLen = bytes.length - (i + 2);
        if (tailLen >= 16) {
          starMarker = i + 2;
          break;
        }
      }
    }
    if (starMarker >= 0) {
      final tailAscii = latin1.decode(bytes.sublist(starMarker), allowInvalid: true);
      final decoded = _tryDecodeBase64Json(tailAscii);
      if (decoded != null) return decoded;
    }
    final text = decodeTextDocument(bytes);
    return unpackConfigText(text);
  }

  /// Windows-exported text subscriptions often carry a UTF-16 BOM.
  static String decodeTextDocument(List<int> rawBytes) {
    final bytes = _gunzipIfNeeded(rawBytes);
    if (bytes.length >= 2 &&
        (bytes[0] == 0xff && bytes[1] == 0xfe ||
         bytes[0] == 0xfe && bytes[1] == 0xff)) {
      if (bytes.length.isOdd) throw const FormatException('UTF-16 文本长度无效');
      final little = bytes[0] == 0xff;
      return String.fromCharCodes([
        for (var i = 2; i < bytes.length; i += 2)
          little ? bytes[i] | bytes[i + 1] << 8 : bytes[i] << 8 | bytes[i + 1],
      ]);
    }
    return utf8.decode(bytes, allowMalformed: true).replaceFirst(RegExp(r'^\uFEFF'), '');
  }
  /// Unpacks obfuscated or encrypted config strings into clean JSON text.
  static String unpackConfigText(String rawText) {
    var s = rawText.trim();
    if (s.startsWith('\uFEFF')) {
      s = s.substring(1).trim();
    }
    if (s.isEmpty) return '';
    // `exports...` happens to decode to a leading '{' as Base64. A known
    // script must remain source text rather than becoming corrupt pseudo-JSON.
    if (looksLikeScript(s)) return s;
    final cleanedJson = stripJsonComments(s);
    if (cleanedJson.startsWith('{') || cleanedJson.startsWith('[')) return s;
    // 1. Check for `**` + Base64 inside text
    final starIdx = s.lastIndexOf('**');
    if (starIdx >= 0 && starIdx + 2 < s.length) {
      final candidate = s.substring(starIdx + 2).trim();
      final decoded = _tryDecodeBase64Json(candidate);
      if (decoded != null) return decoded;
    }
    // 2. Check for hex-encoded `$#...#$` (`2423...`) AES-128-CBC TVBox payload
    if (_looksLikeHex(s) && s.toLowerCase().startsWith('2423')) {
      final decrypted = _tryDecryptTvBoxHexAes(s);
      if (decrypted != null) return unpackConfigText(decrypted);
    }
    // 3. Check for literal `$#...#$` prefix
    if (s.startsWith(r'$#') && s.contains(r'#$')) {
      final hexEncoded = _bytesToHex(utf8.encode(s));
      final decrypted = _tryDecryptTvBoxHexAes(hexEncoded);
      if (decrypted != null) return unpackConfigText(decrypted);
    }
    // 4. Check for `data:...;base64,` or pure Base64
    var b64Candidate = s;
    final dataUriIdx = b64Candidate.indexOf('base64,');
    if (dataUriIdx >= 0) {
      b64Candidate = b64Candidate.substring(dataUriIdx + 7).trim();
    }
    if (!b64Candidate.startsWith('{') &&
        !b64Candidate.startsWith('[') &&
        !b64Candidate.startsWith('<')) {
      final decoded = _tryDecodeBase64Json(b64Candidate);
      if (decoded != null) return decoded;
    }
    return s;
  }
  static String? _tryDecodeBase64Json(String input) {
    final cleaned = input.replaceAll(RegExp(r'\s+'), '');
    if (cleaned.length < 8) return null;
    // Strip any non-base64 trailing characters
    final m = RegExp(r'^[A-Za-z0-9+/_-]+={0,2}').firstMatch(cleaned);
    if (m == null) return null;
    var b64 = m.group(0)!.replaceAll('-', '+').replaceAll('_', '/');
    while (b64.length % 4 != 0) {
      b64 += '=';
    }
    try {
      final decodedBytes = _gunzipIfNeeded(base64Decode(b64));
      final text = utf8.decode(decodedBytes, allowMalformed: true).trim();
      final stripped = text.startsWith('\uFEFF') ? text.substring(1).trim() : text;
      if (stripped.startsWith('{') ||
          stripped.startsWith('[') ||
          stripped.contains('"sites"') ||
          stripped.contains('"urls"') ||
          stripped.contains('"storeHouse"') ||
          stripped.contains('"depots"') ||
          stripped.contains('"lives"') ||
          stripped.startsWith('#EXTM3U') ||
          stripped.contains('#EXTINF:') ||
          stripped.contains(',#genre#') ||
          stripJsonComments(stripped).startsWith('{') ||
          stripJsonComments(stripped).startsWith('[')) {
        return stripped;
      }
    } catch (_) {}
    return null;
  }
  static bool _looksLikeHex(String s) {
    if (s.length < 32 || s.length.isOdd) return false;
    return RegExp(r'^[0-9a-fA-F]+$').hasMatch(s);
  }
  static String _bytesToHex(List<int> bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
  static Uint8List _hexToBytes(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (int i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
  /// Decrypts TVBox `2423...` (`$#<key>#$<cipher><13-byte-iv-hex>`) AES-128-CBC PKCS7 payload.
  static String? _tryDecryptTvBoxHexAes(String hexInput) {
    try {
      final lower = hexInput.trim().toLowerCase();
      final keyEndIdx = lower.indexOf('2324'); // `#$`
      if (!lower.startsWith('2423') || keyEndIdx < 4 || lower.length <= keyEndIdx + 4 + 26) {
        return null;
      }
      final keyHex = lower.substring(4, keyEndIdx);
      final ivHex = lower.substring(lower.length - 26);
      final cipherHex = lower.substring(keyEndIdx + 4, lower.length - 26);
      final keyStr = utf8.decode(_hexToBytes(keyHex), allowMalformed: true).trim();
      final ivStr = utf8.decode(_hexToBytes(ivHex), allowMalformed: true).trim();
      final keyBytes = _padRightBytes(utf8.encode(keyStr), 16, 0x30);
      final ivBytes = _padRightBytes(utf8.encode(ivStr), 16, 0x30);
      final cipherBytes = _hexToBytes(cipherHex);
      final plainBytes = _aes128CbcDecrypt(cipherBytes, keyBytes, ivBytes);
      if (plainBytes == null) return null;
      final text = utf8.decode(plainBytes, allowMalformed: true).trim();
      if (text.startsWith('#EXTM3U') ||
          text.contains('#EXTINF:') ||
          text.contains(',#genre#')) {
        return text;
      }
      final openBrace = text.indexOf('{');
      return openBrace >= 0 ? text.substring(openBrace) : text;
    } catch (_) {
      return null;
    }
  }
  static Uint8List _padRightBytes(List<int> src, int length, int padByte) {
    final out = Uint8List(length);
    for (int i = 0; i < length; i++) {
      out[i] = i < src.length ? (src[i] & 0xFF) : padByte;
    }
    return out;
  }
  /// AES-128 key schedule (176 bytes), shared with the HLS offline downloader.
  static Uint8List aesExpandKey(Uint8List key) => _aesKeyExpansion(key);
  /// AES inverse S-box, shared with the HLS offline downloader.
  static List<int> get aesInvSBox => _invSBox;
  static Uint8List? _aes128CbcDecrypt(
    Uint8List cipher,
    Uint8List key,
    Uint8List iv,
  ) {
    if (cipher.isEmpty || cipher.length % 16 != 0 || key.length != 16 || iv.length != 16) {
      return null;
    }
    final roundKeys = _aesKeyExpansion(key);
    final out = Uint8List(cipher.length);
    var prevBlock = iv;
    for (int offset = 0; offset < cipher.length; offset += 16) {
      final block = Uint8List.sublistView(cipher, offset, offset + 16);
      final decrypted = _aesDecryptBlock(block, roundKeys);
      for (int i = 0; i < 16; i++) {
        out[offset + i] = decrypted[i] ^ prevBlock[i];
      }
      prevBlock = block;
    }
    // Strip PKCS7 padding if valid
    final padLen = out.last;
    if (padLen >= 1 && padLen <= 16 && padLen <= out.length) {
      bool validPad = true;
      for (int i = out.length - padLen; i < out.length; i++) {
        if (out[i] != padLen) {
          validPad = false;
          break;
        }
      }
      if (validPad) {
        return Uint8List.sublistView(out, 0, out.length - padLen);
      }
    }
    return out;
  }
  static const List<int> _sBox = [
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
  ];
  static const List<int> _invSBox = [
    0x52, 0x09, 0x6a, 0xd5, 0x30, 0x36, 0xa5, 0x38, 0xbf, 0x40, 0xa3, 0x9e, 0x81, 0xf3, 0xd7, 0xfb,
    0x7c, 0xe3, 0x39, 0x82, 0x9b, 0x2f, 0xff, 0x87, 0x34, 0x8e, 0x43, 0x44, 0xc4, 0xde, 0xe9, 0xcb,
    0x54, 0x7b, 0x94, 0x32, 0xa6, 0xc2, 0x23, 0x3d, 0xee, 0x4c, 0x95, 0x0b, 0x42, 0xfa, 0xc3, 0x4e,
    0x08, 0x2e, 0xa1, 0x66, 0x28, 0xd9, 0x24, 0xb2, 0x76, 0x5b, 0xa2, 0x49, 0x6d, 0x8b, 0xd1, 0x25,
    0x72, 0xf8, 0xf6, 0x64, 0x86, 0x68, 0x98, 0x16, 0xd4, 0xa4, 0x5c, 0xcc, 0x5d, 0x65, 0xb6, 0x92,
    0x6c, 0x70, 0x48, 0x50, 0xfd, 0xed, 0xb9, 0xda, 0x5e, 0x15, 0x46, 0x57, 0xa7, 0x8d, 0x9d, 0x84,
    0x90, 0xd8, 0xab, 0x00, 0x8c, 0xbc, 0xd3, 0x0a, 0xf7, 0xe4, 0x58, 0x05, 0xb8, 0xb3, 0x45, 0x06,
    0xd0, 0x2c, 0x1e, 0x8f, 0xca, 0x3f, 0x0f, 0x02, 0xc1, 0xaf, 0xbd, 0x03, 0x01, 0x13, 0x8a, 0x6b,
    0x3a, 0x91, 0x11, 0x41, 0x4f, 0x67, 0xdc, 0xea, 0x97, 0xf2, 0xcf, 0xce, 0xf0, 0xb4, 0xe6, 0x73,
    0x96, 0xac, 0x74, 0x22, 0xe7, 0xad, 0x35, 0x85, 0xe2, 0xf9, 0x37, 0xe8, 0x1c, 0x75, 0xdf, 0x6e,
    0x47, 0xf1, 0x1a, 0x71, 0x1d, 0x29, 0xc5, 0x89, 0x6f, 0xb7, 0x62, 0x0e, 0xaa, 0x18, 0xbe, 0x1b,
    0xfc, 0x56, 0x3e, 0x4b, 0xc6, 0xd2, 0x79, 0x20, 0x9a, 0xdb, 0xc0, 0xfe, 0x78, 0xcd, 0x5a, 0xf4,
    0x1f, 0xdd, 0xa8, 0x33, 0x88, 0x07, 0xc7, 0x31, 0xb1, 0x12, 0x10, 0x59, 0x27, 0x80, 0xec, 0x5f,
    0x60, 0x51, 0x7f, 0xa9, 0x19, 0xb5, 0x4a, 0x0d, 0x2d, 0xe5, 0x7a, 0x9f, 0x93, 0xc9, 0x9c, 0xef,
    0xa0, 0xe0, 0x3b, 0x4d, 0xae, 0x2a, 0xf5, 0xb0, 0xc8, 0xeb, 0xbb, 0x3c, 0x83, 0x53, 0x99, 0x61,
    0x17, 0x2b, 0x04, 0x7e, 0xba, 0x77, 0xd6, 0x26, 0xe1, 0x69, 0x14, 0x63, 0x55, 0x21, 0x0c, 0x7d,
  ];
  static const List<int> _rCon = [
    0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36,
  ];
  static Uint8List _aesKeyExpansion(Uint8List key) {
    final w = Uint8List(176);
    w.setRange(0, 16, key);
    final temp = Uint8List(4);
    int bytesGenerated = 16;
    int rconIter = 1;
    while (bytesGenerated < 176) {
      for (int i = 0; i < 4; i++) {
        temp[i] = w[bytesGenerated - 4 + i];
      }
      if (bytesGenerated % 16 == 0) {
        final k = temp[0];
        temp[0] = _sBox[temp[1]] ^ _rCon[rconIter++];
        temp[1] = _sBox[temp[2]];
        temp[2] = _sBox[temp[3]];
        temp[3] = _sBox[k];
      }
      for (int i = 0; i < 4; i++) {
        w[bytesGenerated] = w[bytesGenerated - 16] ^ temp[i];
        bytesGenerated++;
      }
    }
    return w;
  }
  static int _gfMul(int a, int b) {
    int p = 0;
    int aa = a;
    int bb = b;
    for (int i = 0; i < 8; i++) {
      if ((bb & 1) != 0) p ^= aa;
      final hiBit = aa & 0x80;
      aa = (aa << 1) & 0xFF;
      if (hiBit != 0) aa ^= 0x1b;
      bb >>= 1;
    }
    return p;
  }
  static Uint8List _aesDecryptBlock(Uint8List input, Uint8List w) {
    final state = Uint8List.fromList(input);
    void addRoundKey(int round) {
      final base = round * 16;
      for (int i = 0; i < 16; i++) {
        state[i] ^= w[base + i];
      }
    }
    void invShiftRows() {
      // Row 1: shift right 1
      var t = state[13];
      state[13] = state[9];
      state[9] = state[5];
      state[5] = state[1];
      state[1] = t;
      // Row 2: shift right 2
      t = state[2];
      state[2] = state[10];
      state[10] = t;
      t = state[6];
      state[6] = state[14];
      state[14] = t;
      // Row 3: shift right 3 (left 1)
      t = state[3];
      state[3] = state[7];
      state[7] = state[11];
      state[11] = state[15];
      state[15] = t;
    }
    void invSubBytes() {
      for (int i = 0; i < 16; i++) {
        state[i] = _invSBox[state[i]];
      }
    }
    void invMixColumns() {
      for (int c = 0; c < 4; c++) {
        final i = c * 4;
        final s0 = state[i];
        final s1 = state[i + 1];
        final s2 = state[i + 2];
        final s3 = state[i + 3];
        state[i] = _gfMul(s0, 0x0e) ^
            _gfMul(s1, 0x0b) ^
            _gfMul(s2, 0x0d) ^
            _gfMul(s3, 0x09);
        state[i + 1] = _gfMul(s0, 0x09) ^
            _gfMul(s1, 0x0e) ^
            _gfMul(s2, 0x0b) ^
            _gfMul(s3, 0x0d);
        state[i + 2] = _gfMul(s0, 0x0d) ^
            _gfMul(s1, 0x09) ^
            _gfMul(s2, 0x0e) ^
            _gfMul(s3, 0x0b);
        state[i + 3] = _gfMul(s0, 0x0b) ^
            _gfMul(s1, 0x0d) ^
            _gfMul(s2, 0x09) ^
            _gfMul(s3, 0x0e);
      }
    }
    addRoundKey(10);
    for (int round = 9; round >= 1; round--) {
      invShiftRows();
      invSubBytes();
      addRoundKey(round);
      invMixColumns();
    }
    invShiftRows();
    invSubBytes();
    addRoundKey(0);
    return state;
  }
  /// Strips UTF-8 BOM, `//` and `/* */` comments, and trailing commas before `}` or `]`.
  static String stripJsonComments(String input) {
    final trimmedInput =
        input.startsWith('\uFEFF') ? input.substring(1) : input;
    final out = StringBuffer();
    bool inString = false;
    bool escaped = false;
    for (int i = 0; i < trimmedInput.length; i++) {
      final c = trimmedInput[i];
      if (inString) {
        out.write(c);
        if (escaped) {
          escaped = false;
        } else if (c == r'\') {
          escaped = true;
        } else if (c == '"') {
          inString = false;
        }
        continue;
      }
      if (c == '"') {
        inString = true;
        out.write(c);
        continue;
      }
      if (c == '/' && i + 1 < trimmedInput.length) {
        final next = trimmedInput[i + 1];
        if (next == '/') {
          i += 2;
          while (i < trimmedInput.length && trimmedInput[i] != '\n') {
            i++;
          }
          if (i < trimmedInput.length) out.write('\n');
          continue;
        }
        if (next == '*') {
          i += 2;
          while (i + 1 < trimmedInput.length &&
              !(trimmedInput[i] == '*' && trimmedInput[i + 1] == '/')) {
            i++;
          }
          i++;
          continue;
        }
      }
      out.write(c);
    }
    return _stripTrailingCommas(out.toString().trim());
  }
  static String _stripTrailingCommas(String input) {
    final out = StringBuffer();
    bool inString = false;
    bool escaped = false;
    for (int i = 0; i < input.length; i++) {
      final c = input[i];
      if (inString) {
        out.write(c);
        if (escaped) {
          escaped = false;
        } else if (c == r'\') {
          escaped = true;
        } else if (c == '"') {
          inString = false;
        }
        continue;
      }
      if (c == '"') {
        inString = true;
        out.write(c);
        continue;
      }
      if (c == ',') {
        int j = i + 1;
        while (j < input.length) {
          final nc = input[j];
          if (nc == ' ' || nc == '\t' || nc == '\r' || nc == '\n') {
            j++;
          } else {
            break;
          }
        }
        if (j < input.length && (input[j] == '}' || input[j] == ']')) {
          continue;
        }
      }
      out.write(c);
    }
    return out.toString();
  }
  static String resolveUrl(String base, String relativeOrAbsolute) {
    final trimmed = relativeOrAbsolute.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return normalizeUrl(trimmed);
    }
    if (trimmed.startsWith('csp_')) return trimmed;
    if (base.trim().isEmpty) return trimmed;
    try {
      final resolved = Uri.parse(normalizeUrl(base.trim())).resolve(trimmed).toString();
      return normalizeUrl(resolved);
    } catch (_) {
      return trimmed;
    }
  }
  /// Resolve only the JAR address. The digest suffix is an integrity constraint,
  /// not URL syntax; preserve it even when malformed so a loader can reject it.
  static String normalizeJarDeclaration(String origin, String declaration) {
    final marker = RegExp(';md5;', caseSensitive: false).firstMatch(declaration);
    if (marker == null) return resolveUrl(origin, declaration);
    return resolveUrl(origin, declaration.substring(0, marker.start)) +
        declaration.substring(marker.start);
  }
  static int _asInt(dynamic raw, int fallback) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is bool) return raw ? 1 : 0;
    if (raw is String) {
      final s = raw.trim().toLowerCase();
      if (s == 'true') return 1;
      if (s == 'false') return 0;
      return int.tryParse(s) ?? fallback;
    }
    return fallback;
  }
  static bool _asBool(dynamic raw, bool fallback) {
    if (raw == null) return fallback;
    if (raw is bool) return raw;
    if (raw is num) return raw.toInt() != 0;
    if (raw is String) {
      final s = raw.trim().toLowerCase();
      if (s == '0' || s == 'false' || s == 'no') return false;
      if (s == '1' || s == 'true' || s == 'yes') return true;
    }
    return fallback;
  }
  static String _stringifyExt(dynamic raw) {
    if (raw == null) return '';
    if (raw is String) return raw.trim();
    if (raw is Map || raw is List) {
      try {
        return jsonEncode(raw);
      } catch (_) {
        return raw.toString();
      }
    }
    return raw.toString().trim();
  }
  static Map<String, String> _stringHeaders(dynamic raw) {
    dynamic candidate = raw;
    if (candidate is String && candidate.trim().startsWith('{')) {
      try {
        candidate = jsonDecode(stripJsonComments(candidate));
      } catch (_) {}
    }
    if (candidate is! Map) return const {};
    final result = <String, String>{};
    candidate.forEach((k, v) {
      if (k != null && v != null) {
        final keyStr = k.toString().trim();
        final valStr = v.toString().trim();
        if (keyStr.isNotEmpty &&
            !valStr.contains('\r') &&
            !valStr.contains('\n')) {
          result[keyStr] = valStr;
        }
      }
    });
    return result;
  }
  static Map<String, String> _extractSiteHeaders(Map item) {
    final result = <String, String>{};
    dynamic extObj = item['ext'];
    if (extObj is String && extObj.trim().startsWith('{')) {
      try { extObj = jsonDecode(stripJsonComments(extObj)); } catch (_) {}
    }
    if (extObj is Map) {
      result.addAll(_stringHeaders(extObj['headers'] ?? extObj['header']));
      final extUa = (extObj['ua'] ?? extObj['User-Agent'] ?? '').toString().trim();
      if (extUa.isNotEmpty && !extUa.contains('\r') && !extUa.contains('\n')) {
        result['User-Agent'] = extUa;
      }
    }
    result.addAll(_stringHeaders(item['headers'] ?? item['header']));
    final ua = (item['ua'] ?? '').toString().trim();
    if (ua.isNotEmpty && !ua.contains('\r') && !ua.contains('\n')) {
      result['User-Agent'] = ua;
    }
    return result;
  }
  static String _shortHash(String input) {
    int h = 0x811c9dc5;
    for (final code in input.codeUnits) {
      h ^= code;
      h = (h * 0x01000193) & 0x7fffffff;
    }
    return h.toRadixString(36);
  }

  static String _inferSiteNameFromUrl(String url, {String fallback = '订阅资源'}) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return fallback;
    try {
      final uri = Uri.parse(normalizeUrl(trimmed));
      final host = uri.host.toLowerCase();
      if (host.isEmpty) return fallback;
      final parts = host.split('.').where((p) => p.isNotEmpty).toList();
      if (parts.length >= 2) {
        final main = parts[parts.length - 2];
        if (main != 'com' && main != 'cn' && main != 'net' && main != 'org') {
          return main.toUpperCase();
        }
      }
      return host;
    } catch (_) {
      return fallback;
    }
  }

  static String _cleanVodEndpointUrl(String rawUrl) {
    final normalized = normalizeUrl(rawUrl);
    if (normalized.isEmpty) return '';
    try {
      final uri = Uri.parse(normalized);
      if (uri.queryParameters.isEmpty) return normalized;
      final cleanedParams = <String, String>{};
      uri.queryParameters.forEach((k, v) {
        final lk = k.toLowerCase();
        if (lk != 'ac' &&
            lk != 'pg' &&
            lk != 't' &&
            lk != 'wd' &&
            lk != 'ids' &&
            lk != 'h') {
          cleanedParams[k] = v;
        }
      });
      if (cleanedParams.isEmpty) {
        final qIdx = normalized.indexOf('?');
        return qIdx >= 0 ? normalized.substring(0, qIdx) : normalized;
      }
      return uri.replace(queryParameters: cleanedParams).toString();
    } catch (_) {
      return normalized;
    }
  }

  static bool _looksLikeVodEndpointUrl(String url) {
    final lower = url.trim().toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      return false;
    }
    return lower.contains('/provide/vod') ||
        lower.contains('api.php') ||
        lower.contains('/inc/api') ||
        lower.contains('ac=list') ||
        lower.contains('ac=detail') ||
        lower.contains('ac=videolist') ||
        lower.endsWith('/xml') ||
        lower.endsWith('/xml/') ||
        lower.endsWith('/vod') ||
        lower.endsWith('/vod/');
  }

  /// Detects subscription format badge (`多仓`, `JSON`, `VOD`, `M3U`, `TXT`).
  static String detectSubscriptionFormat(String rawText, {String origin = ''}) {
    final unpacked = unpackConfigText(rawText).trim();
    final lowerOrigin = origin.trim().toLowerCase();
    final cleaned = stripJsonComments(unpacked);
    if (cleaned.startsWith('{') || cleaned.startsWith('[')) {
      try {
        final decoded = jsonDecode(cleaned);
        if (decoded is Map<String, dynamic>) {
          if ((decoded['urls'] is List ||
                  decoded['storeHouse'] is List ||
                  decoded['depots'] is List) &&
              decoded['sites'] == null) {
            return '多仓';
          }
          if (decoded['list'] is List || decoded['class'] is List) {
            return 'VOD';
          }
          return 'JSON';
        }
        if (decoded is List) {
          return 'JSON';
        }
      } catch (_) {}
      return 'JSON';
    }
    if (unpacked.startsWith('#EXTM3U') ||
        unpacked.contains('#EXTINF') ||
        lowerOrigin.endsWith('.m3u') ||
        lowerOrigin.endsWith('.m3u8')) {
      return 'M3U';
    }
    if (unpacked.startsWith('<') &&
        (unpacked.toLowerCase().contains('<rss') ||
            unpacked.toLowerCase().contains('<list') ||
            unpacked.toLowerCase().contains('<video'))) {
      return 'VOD';
    }
    if (unpacked.contains(',#genre#')) {
      return 'TXT';
    }
    if (_looksLikeVodEndpointUrl(origin)) return 'VOD';
    try {
      final groups = parseLivePlaylist(unpacked);
      if (groups.isNotEmpty) {
        return unpacked.contains('#EXT') ? 'M3U' : 'TXT';
      }
    } catch (_) {}
    return 'JSON';
  }

  /// Splits user multi-line subscription input into individual entries.
  /// Supports:
  /// - `https://config.example/a.json`
  /// - `名称,https://live.example/b.m3u`
  /// - `分组|名称|https://vod.example/api.php/provide/vod/`
  static List<({String group, String name, String url})>
      splitBatchSubscriptionUrls(String rawInput, {String defaultGroup = '默认分组'}) {
    final trimmed = rawInput.trim();
    if (trimmed.isEmpty) return const [];
    final cleaned = stripJsonComments(trimmed);
    // If it's a JSON/XML/M3U document rather than a list of URLs, return empty so caller treats as raw content.
    if (cleaned.startsWith('{') ||
        cleaned.startsWith('[') ||
        trimmed.startsWith('{') ||
        trimmed.startsWith('[') ||
        trimmed.startsWith('<') ||
        trimmed.startsWith('#EXTM3U') ||
        trimmed.contains('#EXTINF') ||
        trimmed.contains(',#genre#')) {
      return const [];
    }
    final lines = const LineSplitter().convert(trimmed);
    final entries = <({String group, String name, String url})>[];
    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('//') || line.startsWith('#')) {
        continue;
      }
      String group = defaultGroup.trim().isEmpty ? '默认分组' : defaultGroup.trim();
      String name = '';
      String urlCandidate = line;
      if (line.contains('|')) {
        final parts = line.split('|').map((s) => s.trim()).toList();
        if (parts.length >= 3 && parts.last.contains('.')) {
          if (parts[0].isNotEmpty) group = parts[0];
          name = parts[1];
          urlCandidate = parts.sublist(2).join('|');
        } else if (parts.length == 2 && parts[1].contains('.')) {
          name = parts[0];
          urlCandidate = parts[1];
        }
      } else if (line.contains(',') || line.contains('，')) {
        final normalizedLine = line.replaceAll('，', ',');
        final commaIdx = normalizedLine.indexOf(',');
        final left = normalizedLine.substring(0, commaIdx).trim();
        final right = normalizedLine.substring(commaIdx + 1).trim();
        if (!left.startsWith('http') && right.contains('.')) {
          name = left;
          urlCandidate = right;
        }
      }
      final extracted = extractAndNormalizeUrl(urlCandidate);
      if (extracted.startsWith('http://') || extracted.startsWith('https://')) {
        entries.add((
          group: group,
          name: name,
          url: extracted,
        ));
      }
    }
    return entries;
  }

  static bool looksLikePythonScript(String raw) => JsSourceSyntax(raw).hasPythonSpider;

  /// Script documents may be retained as subscriptions without claiming a runtime.
  static bool looksLikeScript(String raw) {
    final trimmed = raw.trimLeft();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) return false;
    if (looksLikePythonScript(raw)) return true;
    final syntax = JsSourceSyntax(raw);
    return syntax.hasSpiderExports || syntax.hasDrpyRule;
  }

  static bool isExecutableJs(String raw) => JsSourceSyntax(raw).hasSpiderExports;

  static bool looksLikeDrpyRule(String raw) => JsSourceSyntax(raw).hasDrpyRule;

  /// Parses TVBox JSON, Multi-Depot JSON, Direct MacCMS VOD JSON/XML, M3U/M3U8, or TXT subscriptions.
  static CmsConfig parseConfig(
    String rawJson, {
    String origin = '',
    String defaultGroup = '默认分组',
    bool isPrivate = false,
    String subscriptionId = '',
    String defaultName = '',
  }) {
    final groupLabel =
        defaultGroup.trim().isEmpty ? '默认分组' : defaultGroup.trim();
    final unpacked = unpackConfigText(rawJson);
    final trimmedUnpacked = unpacked.trim();
    if (trimmedUnpacked.isEmpty) {
      throw const FormatException('配置内容为空');
    }

    if (looksLikeScript(trimmedUnpacked)) {
      final python = looksLikePythonScript(trimmedUnpacked);
      return CmsConfig(sites: [CmsSite(
        key: 'script_${subscriptionId.isEmpty ? 'imported' : subscriptionId}',
        name: defaultName.isEmpty ? (python ? 'Python 订阅' : 'JavaScript 订阅') : defaultName,
        type: 3, api: python ? 'csp_LocalScript.py' :
            (isExecutableJs(trimmedUnpacked)
                ? 'csp_LocalScript.js' : 'csp_LocalRule.js'),
        ext: jsonEncode({'script': trimmedUnpacked, 'origin': origin}),
        group: groupLabel, isPrivate: isPrivate, subscriptionId: subscriptionId,
      )]);
    }

    // 1. Check for XML MacCMS VOD response (`<?xml` / `<rss` / `<list`)
    if (trimmedUnpacked.startsWith('<') &&
        (trimmedUnpacked.toLowerCase().contains('<rss') ||
            trimmedUnpacked.toLowerCase().contains('<list') ||
            trimmedUnpacked.toLowerCase().contains('<video'))) {
      final apiUrl = origin.trim().isNotEmpty
          ? _cleanVodEndpointUrl(origin)
          : '';
      final siteName = defaultName.trim().isNotEmpty
          ? defaultName.trim()
          : _inferSiteNameFromUrl(apiUrl, fallback: 'XML 影视源');
      final siteKey = 'xml_${_shortHash(apiUrl.isNotEmpty ? apiUrl : trimmedUnpacked)}';
      return CmsConfig(
        sites: [
          CmsSite(
            key: siteKey,
            name: siteName,
            type: 0,
            api: apiUrl.isNotEmpty ? apiUrl : 'm3u_vod://xml_inline',
            ext: apiUrl.isEmpty ? trimmedUnpacked : '',
            group: groupLabel,
            isPrivate: isPrivate,
            subscriptionId: subscriptionId,
          ),
        ],
      );
    }

    final cleaned = stripJsonComments(unpacked);
    if (cleaned.isEmpty) {
      throw const FormatException('配置内容为空');
    }
    final isJsonStructure = cleaned.startsWith('{') || cleaned.startsWith('[');

    // 2. Check for non-JSON M3U / M3U8 (`#EXTM3U`, `#EXTINF`) or TXT (`#genre#`) before JSON
    final looksLikeM3uOrTxt = !isJsonStructure &&
        (trimmedUnpacked.startsWith('#EXTM3U') ||
            trimmedUnpacked.contains('#EXTINF') ||
            trimmedUnpacked.contains(',#genre#'));
    if (looksLikeM3uOrTxt) {
      final m3uCfg = _tryParseM3uOrTxtConfig(
        trimmedUnpacked,
        origin: origin,
        groupLabel: groupLabel,
        isPrivate: isPrivate,
        subscriptionId: subscriptionId,
        defaultName: defaultName,
      );
      if (m3uCfg != null) return m3uCfg;
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(cleaned);
    } catch (e) {
      // Fallback: check if plain text is M3U/TXT live channels or plain VOD URL lines
      final fallbackCfg = _tryParseM3uOrTxtConfig(
            trimmedUnpacked,
            origin: origin,
            groupLabel: groupLabel,
            isPrivate: isPrivate,
            subscriptionId: subscriptionId,
            defaultName: defaultName,
          ) ??
          _tryParsePlainVodLinesConfig(
            trimmedUnpacked,
            groupLabel: groupLabel,
            isPrivate: isPrivate,
            subscriptionId: subscriptionId,
          );
      if (fallbackCfg != null) return fallbackCfg;
      throw FormatException('不是有效的 JSON / VOD / M3U 配置格式：$e');
    }

    if (decoded is List) {
      decoded = <String, dynamic>{'sites': decoded};
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('配置根节点必须是 JSON 对象');
    }

    // 3. Direct MacCMS v10 JSON response (`{"code":1,"class":[...],"list":[...]}`)
    if (decoded['sites'] == null &&
        decoded['lives'] == null &&
        decoded['urls'] == null &&
        decoded['storeHouse'] == null &&
        decoded['depots'] == null &&
        (decoded['list'] is List || decoded['class'] is List)) {
      final apiUrl = origin.trim().isNotEmpty
          ? _cleanVodEndpointUrl(origin)
          : '';
      final siteName = defaultName.trim().isNotEmpty
          ? defaultName.trim()
          : _inferSiteNameFromUrl(apiUrl, fallback: 'VOD 影视源');
      final siteKey =
          'vod_${_shortHash(apiUrl.isNotEmpty ? apiUrl : cleaned)}';
      return CmsConfig(
        sites: [
          CmsSite(
            key: siteKey,
            name: siteName,
            type: 1,
            api: apiUrl.isNotEmpty ? apiUrl : 'm3u_vod://json_inline',
            ext: apiUrl.isEmpty ? cleaned : '',
            group: groupLabel,
            isPrivate: isPrivate,
            subscriptionId: subscriptionId,
          ),
        ],
      );
    }

    // 4. Single site JSON object (`{"key":..., "name":..., "api":...}`)
    if (decoded['sites'] == null &&
        decoded['api'] != null &&
        (decoded['name'] != null || decoded['key'] != null)) {
      decoded = <String, dynamic>{
        'spider': decoded['spider'] ?? decoded['jar'] ?? '',
        'sites': [decoded],
      };
    }

    final depots = <CmsDepot>[];
    final seenDepotUrls = <String>{};
    for (final field in ['urls', 'storeHouse', 'depots']) {
      final rawDepots = decoded[field];
      if (rawDepots is List) {
        for (int i = 0; i < rawDepots.length; i++) {
          final item = rawDepots[i];
          if (item is! Map) continue;
          final rawUrl =
              (item['url'] ?? item['sourceUrl'] ?? item['api'] ?? '').toString().trim();
          // Labels such as 更新时间 are metadata, not relative network addresses.
          if (rawUrl.isEmpty || (!RegExp(r'^https?://', caseSensitive: false).hasMatch(rawUrl)
              && !rawUrl.startsWith('//') && !rawUrl.startsWith('/')
              && !rawUrl.startsWith('./') && !rawUrl.startsWith('../')
              && !RegExp(r'^[^\s]+\.[a-zA-Z0-9]{1,8}(?:[?#].*)?$').hasMatch(rawUrl))) continue;
          final resolved = resolveUrl(origin, rawUrl.startsWith('http')
              ? normalizeUrl(rawUrl) : rawUrl);
          if (!resolved.startsWith('http://') && !resolved.startsWith('https://')) {
            continue;
          }
          if (!seenDepotUrls.add(resolved)) continue;
          final name =
              (item['name'] ?? item['sourceName'] ?? '仓库 ${depots.length + 1}')
                  .toString()
                  .trim();
          depots.add(
            CmsDepot(
              name: name.isEmpty ? '仓库 ${depots.length + 1}' : name,
              url: resolved,
              subscriptionId: subscriptionId,
            ),
          );
        }
      }
    }
    final sites = <CmsSite>[];
    final seenKeys = <String>{};
    final spider = normalizeJarDeclaration(
        origin, (decoded['spider'] ?? decoded['jar'] ?? '').toString());
    final parses = <CmsParse>[];
    String defaultJsonParseUrl = '';
    if (decoded['parses'] is List) {
      for (final p in decoded['parses'] as List) {
        if (p is! Map) continue;
        final pUrl = (p['url'] ?? '').toString().trim();
        final pType = _asInt(p['type'], 0);
        if (pUrl.startsWith('http://') || pUrl.startsWith('https://')) {
          parses.add(
            CmsParse(
              name: (p['name'] ?? '解析').toString().trim(),
              url: pUrl,
              type: pType,
              headers: _extractSiteHeaders(p),
            ),
          );
          if (defaultJsonParseUrl.isEmpty && (pType == 1 || pType == 2 || pType == 3)) {
            defaultJsonParseUrl = pUrl;
          }
        }
      }
    }
    final rawSites = decoded['sites'];
    if (rawSites is List) {
      for (int i = 0; i < rawSites.length; i++) {
        final item = rawSites[i];
        if (item is! Map) continue;
        var key = (item['key'] ?? item['name'] ?? 'site-$i').toString().trim();
        final name = (item['name'] ?? key).toString().trim();
        final type = _asInt(item['type'], -1);
        final api = resolveUrl(origin, (item['api'] ?? '').toString());
        if (key.isEmpty || api.isEmpty) continue;
        if (!seenKeys.add(key)) {
          key = '$key-$i';
          seenKeys.add(key);
        }
        var extStr = _stringifyExt(item['ext']);
        if (api.toLowerCase() == 'csp_drpy' && item['ext'] is String &&
            !looksLikeScript(extStr) && !extStr.trimLeft().startsWith('{')) {
          extStr = resolveUrl(origin, extStr);
        } else if ((extStr.startsWith('./') || extStr.startsWith('../')) && origin.trim().isNotEmpty) {
          extStr = resolveUrl(origin, extStr);
        }
        final itemGroup = (item['group'] ?? '').toString().trim();
        final itemPrivate = _asBool(item['isPrivate'] ?? item['hidden'], isPrivate);
        sites.add(
          CmsSite(
            key: key,
            name: name.isEmpty ? key : name,
            type: type,
            api: api,
            playUrl: (item['playUrl'] ?? '').toString().trim().isNotEmpty
                ? (item['playUrl'] ?? '').toString().trim()
                : defaultJsonParseUrl,
            searchable: _asBool(item['searchable'], true),
            ext: extStr,
            rawExtension: item['ext'] is String ? item['ext'] as String : null,
            jar: normalizeJarDeclaration(origin, (item['jar'] ?? '').toString()),
            spider: spider,
            headers: _extractSiteHeaders(item),
            group: itemGroup.isEmpty ? groupLabel : itemGroup,
            isPrivate: itemPrivate,
            subscriptionId: subscriptionId,
          ),
        );
      }
    }
    final lives = <LiveSource>[];
    final rawLives = decoded['lives'];
    final entries = rawLives is List ? rawLives : rawLives == null ? const [] : [rawLives];
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      final item = entry is String ? <String, dynamic>{'url': entry} : entry;
      if (item is! Map) continue;
      final name = (item['name'] ?? '直播源 ${index + 1}').toString().trim();
      final itemGroup = (item['group'] ?? '').toString().trim();
      final group = itemGroup.isEmpty ? groupLabel : itemGroup;
      final hidden = _asBool(item['isPrivate'] ?? item['hidden'], isPrivate);
      final headers = LiveCatalogParser.headers(item);
      final rawUrl = (item['url'] ?? '').toString().trim();
      final api = (item['api'] ?? '').toString().trim();
      CmsSite? plugin;
      if (api.isNotEmpty) {
        final ext = item['ext'];
        final resolvedExt = ext is String && (ext.startsWith('./') || ext.startsWith('../'))
            ? resolveUrl(origin, ext) : ext;
        plugin = CmsSite(
          key: 'live-plugin:${_shortHash(jsonEncode([origin, index, item]))}',
          name: name, type: 3, api: resolveUrl(origin, api),
          ext: _stringifyExt(resolvedExt), rawExtension: resolvedExt is String ? resolvedExt : null,
          jar: normalizeJarDeclaration(origin, (item['jar'] ?? '').toString()),
          spider: spider, headers: headers, group: group, isPrivate: hidden,
          subscriptionId: subscriptionId,
        );
      }
      String inline = '';
      final children = item['groups'] ?? item['channels'];
      if (children is List && (children.isNotEmpty || plugin == null)) {
        dynamic separate(dynamic child, Map<String, String> inherited, int depth) {
          if (depth > 24) throw const FormatException('直播目录嵌套过深');
          if (child is! Map) return child;
          final scopedHeaders = LiveCatalogParser.merge([inherited, LiveCatalogParser.headers(child)]);
          for (final field in ['groups', 'channels']) {
            if (child[field] is List) {
              final remaining = [for (final nested in child[field] as List)
                separate(nested, scopedHeaders, depth + 1)].where((v) => v != null).toList();
              return remaining.isEmpty ? null : {...child, field: remaining};
            }
          }
          final urls = child['urls'] ?? child['url'];
          final values = urls is List ? urls : [urls];
          final streams = <dynamic>[];
          var extracted = false;
          for (final value in values) {
            final raw = value is Map ? value['url'] : value;
            final target = raw is String ? LiveCatalogParser.directoryUrl(raw) : null;
            if (target == null) { if (value != null) streams.add(value); continue; }
            extracted = true;
            lives.add(LiveSource(name: '${value is Map ? value['name'] ?? child['name'] ?? name : child['name'] ?? name}',
              url: target, origin: origin,
              headers: LiveCatalogParser.merge([scopedHeaders, if (value is Map) LiveCatalogParser.headers(value)]),
              group: group, isPrivate: hidden, subscriptionId: subscriptionId));
          }
          if (!extracted) return child;
          return streams.isEmpty ? null : {...child, 'urls': streams};
        }
        final ordinary = [for (final child in children) separate(child, headers, 0)]
            .where((v) => v != null).toList();
        if (ordinary.isNotEmpty) {
          inline = jsonEncode({'name': name, item['groups'] != null ? 'groups' : 'channels': ordinary});
        }
      }
      // liveContent receives its original opaque argument, including an empty one.
      final url = plugin != null ? rawUrl : LiveCatalogParser.directoryUrl(rawUrl) ?? resolveUrl(origin, rawUrl);
      final data = Uri.tryParse(url)?.data;
      if (plugin != null || inline.isNotEmpty || url.startsWith('http://') || url.startsWith('https://') ||
          data != null && data.mimeType == 'text/plain' && data.isBase64) {
        lives.add(LiveSource(name: name, url: url, headers: headers, origin: origin,
          inlineContent: inline, plugin: plugin, group: group, isPrivate: hidden,
          subscriptionId: subscriptionId));
      }
    }
    if (sites.isEmpty && lives.isEmpty && depots.isEmpty) {
      final liveCatalogCfg = _tryParseM3uOrTxtConfig(
        cleaned,
        origin: origin,
        groupLabel: groupLabel,
        isPrivate: isPrivate,
        subscriptionId: subscriptionId,
        defaultName: defaultName,
      );
      if (liveCatalogCfg != null) return liveCatalogCfg;
      throw const FormatException('配置中未找到可用的 sites（片源）、lives（直播）或 urls（多仓列表）');
    }
    return CmsConfig(
      sites: sites,
      lives: lives,
      depots: depots,
      parses: parses,
      spider: spider,
    );
  }

  static CmsConfig? _tryParseM3uOrTxtConfig(
    String content, {
    required String origin,
    required String groupLabel,
    required bool isPrivate,
    required String subscriptionId,
    required String defaultName,
  }) {
    final List<LiveGroup> groups;
    try {
      groups = parseLivePlaylist(content, origin: origin);
    } catch (_) {
      return null;
    }
    if (groups.isEmpty) return null;
    final baseName = defaultName.trim().isNotEmpty
        ? defaultName.trim()
        : _inferSiteNameFromUrl(origin, fallback: 'M3U 订阅源');
    final liveUrl = origin.trim().isNotEmpty
        ? normalizeUrl(origin.trim())
        : 'data:text/plain;base64,${base64Encode(utf8.encode(content))}';
    final siteKey = 'm3u_${_shortHash(origin.isNotEmpty ? origin : content)}';
    return CmsConfig(
      sites: [
        CmsSite(
          key: siteKey,
          name: baseName,
          type: 1,
          api: 'm3u_vod://${origin.trim().isNotEmpty ? normalizeUrl(origin.trim()) : siteKey}',
          ext: content,
          group: groupLabel,
          isPrivate: isPrivate,
          subscriptionId: subscriptionId,
        ),
      ],
      lives: [
        LiveSource(
          name: baseName,
          url: liveUrl,
          group: groupLabel,
          isPrivate: isPrivate,
          subscriptionId: subscriptionId,
        ),
      ],
    );
  }

  static CmsConfig? _tryParsePlainVodLinesConfig(
    String content, {
    required String groupLabel,
    required bool isPrivate,
    required String subscriptionId,
  }) {
    final entries = splitBatchSubscriptionUrls(content, defaultGroup: groupLabel);
    if (entries.isEmpty) return null;
    final sites = <CmsSite>[];
    final lives = <LiveSource>[];
    for (int i = 0; i < entries.length; i++) {
      final e = entries[i];
      final lower = e.url.toLowerCase();
      final name = e.name.isNotEmpty
          ? e.name
          : _inferSiteNameFromUrl(e.url, fallback: '片源 ${i + 1}');
      if (lower.endsWith('.m3u') ||
          lower.endsWith('.m3u8') ||
          lower.endsWith('.txt')) {
        lives.add(
          LiveSource(
            name: name,
            url: e.url,
            group: e.group,
            isPrivate: isPrivate,
            subscriptionId: subscriptionId,
          ),
        );
      } else if (_looksLikeVodEndpointUrl(e.url)) {
        final isXml = lower.contains('/xml');
        sites.add(
          CmsSite(
            key: 'vod_${_shortHash(e.url)}_$i',
            name: name,
            type: isXml ? 0 : 1,
            api: _cleanVodEndpointUrl(e.url),
            group: e.group,
            isPrivate: isPrivate,
            subscriptionId: subscriptionId,
          ),
        );
      }
    }
    if (sites.isEmpty && lives.isEmpty) return null;
    return CmsConfig(sites: sites, lives: lives);
  }

  /// Builds `(categories, listing)` from an `m3u_vod://` site's M3U/TXT or inline VOD payload.
  static (List<CmsCategory>, CmsListing) parseM3uVodHome(String content, {String origin = ''}) {
    final trimmed = content.trim();
    if (trimmed.startsWith('{') || trimmed.startsWith('<')) {
      return (parseCategories(trimmed), parseListing(trimmed));
    }
    final groups = parseLivePlaylist(trimmed, origin: origin);
    final categories = <CmsCategory>[
      for (int i = 0; i < groups.length; i++)
        CmsCategory(id: groups[i].name, name: groups[i].name),
    ];
    final videos = <CmsVideo>[];
    for (final g in groups) {
      for (final ch in g.channels) {
        videos.add(
          CmsVideo(
            id: '${g.name}::${ch.name}',
            title: ch.name,
            remarks: g.name,
            tag: g.name,
            lines: [
              CmsLine(
                name: g.name,
                episodes: [
                  for (int i = 0; i < ch.urls.length; i++)
                    CmsEpisode(
                      name: ch.urls.length == 1 ? '正片' : '线路 ${i + 1}',
                      url: ch.urls[i],
                    ),
                ],
              ),
            ],
          ),
        );
      }
    }
    return (categories, CmsListing(page: 1, pageCount: 1, videos: videos));
  }

  /// Fixed primary tabs shown on the Home page.
  static const List<(String, String)> primaryHomeTabs = [
    ('recommend', '推荐'),
    ('movie', '电影'),
    ('series', '剧集'),
    ('anime', '动漫'),
    ('variety', '综艺'),
  ];

  /// Filter options for region (`国家地区`) and year (`年份`).
  static const List<String> filterAreas = [
    '全部',
    '大陆',
    '香港',
    '台湾',
    '美国',
    '韩国',
    '日本',
    '英国',
    '法国',
    '泰国',
    '印度',
    '其他',
  ];

  static const List<String> filterYears = [
    '全部',
    '2026',
    '2025',
    '2024',
    '2023',
    '2022',
    '2021',
    '2020',
    '2019',
    '2010年代',
    '更早',
  ];

  static const List<String> fallbackGenreTags = [
    '动作',
    '喜剧',
    '爱情',
    '科幻',
    '悬疑',
    '犯罪',
    '奇幻',
    '古装',
    '战争',
    '家庭',
    '武侠',
    '恐怖',
    '历史',
    '纪录',
  ];

  /// Classifies a MacCMS category name into one of `'movie'`, `'series'`, `'anime'`, `'variety'`, or `''`.
  static String classifyCategoryPrimaryTab(String name) {
    final s = name.trim();
    if (s.isEmpty) return '';
    if (s.contains('漫') ||
        s.contains('动画') ||
        s.contains('番剧') ||
        s.contains('二次元') ||
        s.contains('少儿')) {
      return 'anime';
    }
    if (s.contains('综') ||
        s.contains('真人秀') ||
        s.contains('脱口秀') ||
        s.contains('晚会') ||
        s.contains('娱乐')) {
      return 'variety';
    }
    if ((s.contains('剧') &&
            !s.contains('剧情') &&
            !s.contains('喜剧') &&
            !s.contains('悲剧') &&
            !s.contains('歌剧')) ||
        s.contains('连续') ||
        s.contains('电视') ||
        s.contains('美剧') ||
        s.contains('韩剧') ||
        s.contains('日剧') ||
        s.contains('港剧') ||
        s.contains('台剧') ||
        s.contains('泰剧') ||
        s.contains('短剧')) {
      return 'series';
    }
    if (s.contains('影') ||
        s.contains('片') ||
        s.contains('动作') ||
        s.contains('喜剧') ||
        s.contains('爱情') ||
        s.contains('科幻') ||
        s.contains('悬疑') ||
        s.contains('恐怖') ||
        s.contains('战争') ||
        s.contains('犯罪') ||
        s.contains('奇幻') ||
        s.contains('武侠')) {
      return 'movie';
    }
    return '';
  }

  /// Resolves `(categoryId, childIds)` for one of the 5 primary tabs (`recommend`, `movie`, `series`, `anime`, `variety`).
  static ({String categoryId, List<String> childIds}) resolvePrimaryTabCategory(
    List<CmsCategory> categories,
    String primaryTab,
  ) {
    if (primaryTab.isEmpty || primaryTab == 'recommend' || categories.isEmpty) {
      return (categoryId: '', childIds: const []);
    }
    final matching = <CmsCategory>[];
    for (final c in categories) {
      if (classifyCategoryPrimaryTab(c.name) == primaryTab) {
        matching.add(c);
      }
    }
    if (matching.isEmpty) {
      return (categoryId: '', childIds: const []);
    }
    // Prefer a top-level parent category if one exists
    final topLevel = matching.where((c) => c.isTopLevel).toList();
    for (final parent in topLevel) {
      final children = childCategoryIds(categories, parent.id);
      if (children.isNotEmpty) {
        return (categoryId: parent.id, childIds: children);
      }
    }
    // Exact name match (`电影` / `电影片`, `电视剧` / `连续剧` / `剧集`, `动漫` / `动漫片`, `综艺` / `综艺片`)
    CmsCategory? exactParent;
    for (final c in matching) {
      final n = c.name.trim();
      if ((primaryTab == 'movie' && (n == '电影' || n == '电影片')) ||
          (primaryTab == 'series' &&
              (n == '剧集' || n == '连续剧' || n == '电视剧' || n == '国产剧')) ||
          (primaryTab == 'anime' && (n == '动漫' || n == '动漫片' || n == '动画')) ||
          (primaryTab == 'variety' && (n == '综艺' || n == '综艺片'))) {
        exactParent = c;
        break;
      }
    }
    if (exactParent != null) {
      final otherIds = [
        for (final c in matching)
          if (c.id != exactParent.id) c.id,
      ];
      return (categoryId: exactParent.id, childIds: otherIds);
    }
    return (
      categoryId: matching.first.id,
      childIds: matching.map((c) => c.id).toList(growable: false),
    );
  }

  /// Returns the sub-categories to display inside the collapsible Filter Drawer (`筛选栏`).
  static List<CmsCategory> subCategoriesForPrimaryTab(
    List<CmsCategory> categories,
    String primaryTab,
  ) {
    if (categories.isEmpty) return const [];
    if (primaryTab.isEmpty || primaryTab == 'recommend') {
      // On "推荐", collapse all non-primary or specific categories into the Filter Bar
      return categories;
    }
    final matched = categories
        .where((c) => classifyCategoryPrimaryTab(c.name) == primaryTab)
        .toList();
    // Also include direct children of any matched parent category
    final parentIds = matched.map((c) => c.id).toSet();
    for (final c in categories) {
      if (parentIds.contains(c.parentId) &&
          !matched.any((m) => m.id == c.id)) {
        matched.add(c);
      }
    }
    return matched.isNotEmpty ? matched : categories;
  }

  /// Filters a list of [CmsVideo] by [filter] (`area`, `year`, `genreLabel`).
  static List<CmsVideo> filterVideos(List<CmsVideo> videos, CmsFilter filter) {
    if (!filter.hasSubFilter) return videos;
    final area = filter.area.trim();
    final year = filter.year.trim();
    final genre = filter.genreLabel.trim();

    return videos.where((v) {
      if (area.isNotEmpty && area != '全部') {
        final haystack =
            '${v.area} ${v.remarks} ${v.tag} ${v.description} ${v.title}'
                .toLowerCase();
        if (!_matchesArea(haystack, area)) return false;
      }
      if (year.isNotEmpty && year != '全部') {
        final haystack = '${v.year} ${v.remarks} ${v.title}';
        if (!_matchesYear(haystack, year)) return false;
      }
      if (genre.isNotEmpty && genre != '全部') {
        final cleanGenre = genre.replaceAll(RegExp(r'[片剧漫]$'), '');
        final haystack =
            '${v.tag} ${v.remarks} ${v.description} ${v.title} ${v.area}'
                .toLowerCase();
        if (cleanGenre.isNotEmpty &&
            !haystack.contains(cleanGenre.toLowerCase()) &&
            !haystack.contains(genre.toLowerCase())) {
          return false;
        }
      }
      return true;
    }).toList(growable: false);
  }

  static bool _matchesArea(String haystack, String area) {
    if (haystack.trim().isEmpty) return false;
    switch (area) {
      case '大陆':
        return haystack.contains('大陆') ||
            haystack.contains('内地') ||
            haystack.contains('中国') ||
            haystack.contains('国产') ||
            haystack.contains('国语') ||
            haystack.contains('普通话');
      case '香港':
        return haystack.contains('香港') ||
            haystack.contains('港剧') ||
            haystack.contains('港片') ||
            haystack.contains('粤语');
      case '台湾':
        return haystack.contains('台湾') || haystack.contains('台剧');
      case '美国':
        return haystack.contains('美国') ||
            haystack.contains('欧美') ||
            haystack.contains('好莱坞') ||
            haystack.contains('美剧');
      case '韩国':
        return haystack.contains('韩国') ||
            haystack.contains('韩剧') ||
            haystack.contains('韩语');
      case '日本':
        return haystack.contains('日本') ||
            haystack.contains('日剧') ||
            haystack.contains('日语') ||
            haystack.contains('日漫');
      case '英国':
        return haystack.contains('英国') || haystack.contains('英剧');
      case '法国':
        return haystack.contains('法国');
      case '泰国':
        return haystack.contains('泰国') || haystack.contains('泰剧');
      case '印度':
        return haystack.contains('印度');
      case '其他':
        for (final known in [
          '大陆',
          '内地',
          '中国',
          '香港',
          '台湾',
          '美国',
          '韩国',
          '日本',
          '英国',
          '法国',
          '泰国',
          '印度',
        ]) {
          if (haystack.contains(known)) return false;
        }
        return true;
      default:
        return haystack.contains(area.toLowerCase());
    }
  }

  static bool _matchesYear(String haystack, String yearFilter) {
    if (yearFilter == '2010年代') {
      final m = RegExp(r'\b(201\d)\b').firstMatch(haystack);
      return m != null;
    }
    if (yearFilter == '更早') {
      final m = RegExp(r'\b(19\d\d|200\d)\b').firstMatch(haystack);
      return m != null;
    }
    return haystack.contains(yearFilter);
  }
  static List<CmsCategory> parseCategories(String rawJson) {
    final trimmed = rawJson.trimLeft();
    if (trimmed.startsWith('<')) {
      return _parseXmlCategories(trimmed);
    }
    final decoded = jsonDecode(stripJsonComments(rawJson));
    if (decoded is! Map<String, dynamic>) return const [];
    final rawClass = decoded['class'] ??
        (decoded['data'] is List
            ? decoded['data']
            : (decoded['data'] is Map ? (decoded['data'] as Map)['list'] ?? (decoded['data'] as Map)['class'] : null));
    if (rawClass is! List) return const [];
    final categories = <CmsCategory>[];
    for (final item in rawClass) {
      if (item is! Map) continue;
      final id = (item['type_id'] ?? '').toString().trim();
      final name = (item['type_name'] ?? '').toString().trim();
      final pid = (item['type_pid'] ?? '').toString().trim();
      if (id.isNotEmpty && name.isNotEmpty) {
        categories.add(CmsCategory(id: id, name: name, parentId: pid));
      }
    }
    return categories;
  }

  /// IDs of the direct child categories of [parentId] (MacCMS `type_pid`).
  /// Many MacCMS v10 APIs return nothing for `t=<parent>` because titles are
  /// only attached to leaf categories, so callers merge the children instead.
  static List<String> childCategoryIds(
    List<CmsCategory> categories,
    String parentId,
  ) {
    if (parentId.isEmpty || parentId == '0') return const [];
    return [
      for (final c in categories)
        if (c.parentId == parentId && c.id != parentId) c.id,
    ];
  }
  static List<CmsCategory> _parseXmlCategories(String xml) {
    final categories = <CmsCategory>[];
    final tagPattern = RegExp(
      r'''<ty\b[^>]*\bid\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)</ty>''',
      caseSensitive: false,
    );
    for (final match in tagPattern.allMatches(xml)) {
      final id = (match.group(1) ?? '').trim();
      final name = _cleanXmlText(match.group(2) ?? '');
      if (id.isNotEmpty && name.isNotEmpty) {
        categories.add(CmsCategory(id: id, name: name));
      }
    }
    return categories;
  }
  static CmsListing parseListing(String rawJson) {
    final trimmed = rawJson.trimLeft();
    if (trimmed.startsWith('<')) {
      return _parseXmlListing(trimmed);
    }
    final decoded = jsonDecode(stripJsonComments(rawJson));
    if (decoded is! Map<String, dynamic>) return const CmsListing();
    final page = int.tryParse((decoded['page'] ?? '1').toString()) ?? 1;
    final pageCount =
        int.tryParse((decoded['pagecount'] ?? '1').toString()) ?? 1;
    final dataField = decoded['data'];
    final rawList = decoded['list'] ??
        (dataField is List
            ? dataField
            : (dataField is Map
                ? (dataField['list'] is List
                    ? dataField['list']
                    : (dataField['vod_id'] != null || dataField['vod_name'] != null ? [dataField] : null))
                : null));
    if (rawList is! List) {
      return CmsListing(page: page, pageCount: pageCount);
    }
    final videos = <CmsVideo>[];
    for (final item in rawList) {
      if (item is! Map) continue;
      final id = (item['vod_id'] ?? '').toString().trim();
      final title = (item['vod_name'] ?? '').toString().trim();
      var playFrom = (item['vod_play_from'] ?? '').toString();
      var playUrl = (item['vod_play_url'] ?? '').toString();
      if (playUrl.trim().isEmpty && item['vod_url_with_player'] is List) {
        final froms = <String>[];
        final urls = <String>[];
        for (final p in item['vod_url_with_player'] as List) {
          if (p is! Map) continue;
          final u = (p['url'] ?? '').toString().trim();
          if (u.isEmpty) continue;
          froms.add((p['name'] ?? p['code'] ?? '默认线路').toString().trim());
          urls.add(u);
        }
        playFrom = froms.join(r'$$$');
        playUrl = urls.join(r'$$$');
      }
      if (id.isEmpty && title.isEmpty) continue;
      videos.add(
        CmsVideo(
          id: id,
          title: title,
          poster: _cleanPosterUrl((item['vod_pic'] ?? '').toString().trim()),
          remarks: (item['vod_remarks'] ?? '').toString().trim(),
          year: (item['vod_year'] ?? '').toString().trim(),
          area: (item['vod_area'] ?? '').toString().trim(),
          actor: (item['vod_actor'] ?? '').toString().trim(),
          description: _cleanHtml((item['vod_content'] ?? '').toString()),
          tag: (item['vod_tag'] ?? '').toString().trim(),
          lines: _parseLines(
            playFrom,
            playUrl,
          ),
        ),
      );
    }
    return CmsListing(
      page: page < 1 ? 1 : page,
      pageCount: pageCount < 1 ? 1 : pageCount,
      videos: videos,
    );
  }
  static bool isBrokenPosterUrl(String url) {
    final lower = url.trim().toLowerCase();
    if (lower.isEmpty) return true;
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      return true;
    }
    if (lower.contains('mdzypic.com') || lower.contains('macci.cc')) {
      return true;
    }
    return false;
  }

  static String friendlyLineName(String rawFlag) {
    final trimmed = rawFlag.trim();
    if (trimmed.isEmpty) return '高清专线';
    final lower = trimmed.toLowerCase();
    const map = <String, String>{
      'modum3u8': '魔都超清',
      'modu': '魔都专线',
      'bfzym3u8': '暴风蓝光',
      'bfzy': '暴风专线',
      'dyttm3u8': '电影天堂',
      'dytt': '天堂蓝光',
      'ffm3u8': '非凡超清',
      'ffzy': '非凡专线',
      'lzm3u8': '量子超清',
      'lzi': '量子专线',
      'snm3u8': '索尼蓝光',
      'suoni': '索尼专线',
      'ryzym3u8': '如意超清',
      'rycj': '如意专线',
      'hhzym3u8': '豪华蓝光',
      'hhzy': '豪华专线',
      'jsm3u8': '极速蓝光',
      'jszy': '极速专线',
      'ikm3u8': '爱坤超清',
      'ikun': '爱坤专线',
      'subm3u8': '速播超清',
      'subo': '速播专线',
      'xlm3u8': '新浪蓝光',
      'xinlang': '新浪专线',
      'hnm3u8': '红牛超清',
      'hongniu': '红牛专线',
      '360zy': '360超清',
      'zuidam3u8': '最大蓝光',
      'zuidazy': '最大专线',
      'tyyszy': '天涯超清',
      'tyysm3u8': '天涯蓝光',
      'wjm3u8': '无尽超清',
      'kuaikan': '快看蓝光',
      'ukm3u8': 'U酷超清',
      'sdm3u8': '闪电蓝光',
      'jinyingm3u8': '金鹰超清',
      'bdxm3u8': '北斗蓝光',
      'qhm3u8': '奇虎超清',
      'hym3u8': '虎牙直连',
    };
    if (map.containsKey(lower)) {
      return map[lower]!;
    }
    if (RegExp(r'^[a-z0-9_]+m3u8$').hasMatch(lower)) {
      final prefix = lower.substring(0, lower.length - 4);
      if (map.containsKey(prefix)) return map[prefix]!;
      return '超清直连';
    }
    return trimmed;
  }

  /// Keep source-provided names intact. Size, resolution and container require metadata.
  static String formatNetdiskEpisodeName(String rawName, int index, int totalCount) {
    final name = rawName.trim();
    return name.isNotEmpty ? name : (totalCount > 1 ? '第 ${index + 1} 集' : '正片');
  }

  static String upgradePosterUrlToHd(String rawUrl) {
    var u = rawUrl.trim();
    if (u.isEmpty) return '';
    if (u.startsWith('//')) u = 'https:$u';
    if (u.contains('doubanio.com')) {
      u = u
          .replaceFirst('img9.doubanio.com', 'img3.doubanio.com')
          .replaceFirst('/s_ratio_poster/', '/l_ratio_poster/')
          .replaceFirst('/m_ratio_poster/', '/l_ratio_poster/')
          .replaceFirst('/view/photo/spic/', '/view/photo/lpic/')
          .replaceFirst('/view/photo/mpic/', '/view/photo/lpic/')
          .replaceFirst('/view/subject/s/', '/view/subject/l/')
          .replaceFirst('/view/subject/m/', '/view/subject/l/');
      if (u.endsWith('.webp')) {
        u = '${u.substring(0, u.length - 5)}.jpg';
      }
    } else if (u.contains('hdslb.com') || u.contains('biliimg.com')) {
      final atResize = RegExp(r'@\d+w_\d+h.*$').firstMatch(u);
      if (atResize != null) {
        u = u.substring(0, atResize.start);
      }
    }
    return u;
  }

  static String _cleanPosterUrl(String raw) {
    var cleaned = raw.trim();
    final atIdx = cleaned.indexOf(RegExp(r'@(?:Referer|User-Agent)=', caseSensitive: false));
    if (atIdx > 0) {
      cleaned = cleaned.substring(0, atIdx).trim();
    }
    if (cleaned.startsWith('//')) {
      cleaned = 'https:$cleaned';
    }
    if (isBrokenPosterUrl(cleaned)) {
      return '';
    }
    return upgradePosterUrlToHd(cleaned);
  }
  static CmsListing _parseXmlListing(String xml) {
    int page = 1;
    int pageCount = 1;
    final listOpen =
        RegExp(r'<list\b([^>]*)>', caseSensitive: false).firstMatch(xml);
    if (listOpen != null) {
      final attrs = listOpen.group(1) ?? '';
      final pgMatch =
          RegExp(r'''\bpage\s*=\s*["']?(\d+)''', caseSensitive: false)
              .firstMatch(attrs);
      final pcMatch = RegExp(
        r'''\bpagecount\s*=\s*["']?(\d+)''',
        caseSensitive: false,
      ).firstMatch(attrs);
      if (pgMatch != null) page = int.tryParse(pgMatch.group(1) ?? '1') ?? 1;
      if (pcMatch != null) {
        pageCount = int.tryParse(pcMatch.group(1) ?? '1') ?? 1;
      }
    }
    final videos = <CmsVideo>[];
    final videoPattern = RegExp(
      r'<video\b[^>]*>([\s\S]*?)</video>',
      caseSensitive: false,
    );
    final ddPattern = RegExp(
      r'''<dd\b([^>]*)>([\s\S]*?)</dd>''',
      caseSensitive: false,
    );
    final flagPattern = RegExp(
      r'''\bflag\s*=\s*["']([^"']*)["']''',
      caseSensitive: false,
    );
    for (final vMatch in videoPattern.allMatches(xml)) {
      final block = vMatch.group(1) ?? '';
      final id = _extractXmlTag(block, 'id');
      final title = _extractXmlTag(block, 'name');
      if (id.isEmpty && title.isEmpty) continue;
      final fromParts = <String>[];
      final urlParts = <String>[];
      for (final dd in ddPattern.allMatches(block)) {
        final ddAttrs = dd.group(1) ?? '';
        final flagMatch = flagPattern.firstMatch(ddAttrs);
        final flag = (flagMatch?.group(1) ?? '').trim();
        final body = _cleanXmlText(dd.group(2) ?? '');
        if (body.isNotEmpty) {
          fromParts.add(flag.isEmpty ? '线路 ${fromParts.length + 1}' : flag);
          urlParts.add(body);
        }
      }
      videos.add(
        CmsVideo(
          id: id,
          title: title,
          poster: _cleanPosterUrl(_extractXmlTag(block, 'pic')),
          remarks: _extractXmlTag(block, 'note'),
          year: _extractXmlTag(block, 'year'),
          area: _extractXmlTag(block, 'area'),
          actor: _extractXmlTag(block, 'actor'),
          description: _cleanHtml(_extractXmlTag(block, 'des')),
          lines: _parseLines(fromParts.join(r'$$$'), urlParts.join(r'$$$')),
        ),
      );
    }
    return CmsListing(
      page: page < 1 ? 1 : page,
      pageCount: pageCount < 1 ? 1 : pageCount,
      videos: videos,
    );
  }
  static String _extractXmlTag(String block, String tag) {
    final m = RegExp(
      '<$tag\\b[^>]*>([\\s\\S]*?)</$tag>',
      caseSensitive: false,
    ).firstMatch(block);
    return m == null ? '' : _cleanXmlText(m.group(1) ?? '');
  }
  static String _cleanXmlText(String raw) {
    var s = raw.trim();
    final cdata = RegExp(r'^<!\[CDATA\[([\s\S]*?)\]\]>$').firstMatch(s);
    if (cdata != null) {
      s = (cdata.group(1) ?? '').trim();
    }
    return s;
  }
  static String _cleanHtml(String html) {
    return html
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .trim();
  }
  static String _cleanStreamUrl(String raw) {
    var trimmed = raw.trim();
    final m3u8At = RegExp(r'(\.m3u8(?:\?[^@\s]*)?)@', caseSensitive: false).firstMatch(trimmed);
    if (m3u8At != null) {
      final cut = m3u8At.end - 1;
      trimmed = trimmed.substring(0, cut);
    }
    final mp4At = RegExp(r'(\.mp4(?:\?[^@\s]*)?)@', caseSensitive: false).firstMatch(trimmed);
    if (mp4At != null) {
      final cut = mp4At.end - 1;
      trimmed = trimmed.substring(0, cut);
    }
    return trimmed;
  }
  static List<CmsLine> _parseLines(String playFrom, String playUrl) {
    if (playUrl.trim().isEmpty) return const [];
    final fromParts = playFrom.split(r'$$$');
    final urlParts = playUrl.split(r'$$$');
    final lines = <CmsLine>[];
    for (int i = 0; i < urlParts.length; i++) {
      final rawGroup = urlParts[i].trim();
      if (rawGroup.isEmpty) continue;
      final lineName = i < fromParts.length && fromParts[i].trim().isNotEmpty
          ? friendlyLineName(fromParts[i].trim())
          : '线路 ${i + 1}';
      final episodes = <CmsEpisode>[];
      for (final segment in rawGroup.split('#')) {
        final s = segment.trim();
        if (s.isEmpty) continue;
        final dollar = s.indexOf(r'$');
        final epName = dollar >= 0 ? s.substring(0, dollar).trim() : '正片';
        final epUrl = _cleanStreamUrl(
          dollar >= 0 ? s.substring(dollar + 1).trim() : s,
        );
        if (epUrl.isNotEmpty) {
          episodes.add(
            CmsEpisode(
              name: epName.isEmpty ? '第 ${episodes.length + 1} 集' : epName,
              url: epUrl,
            ),
          );
        }
      }
      if (episodes.isNotEmpty) {
        lines.add(CmsLine(name: lineName, episodes: episodes));
      }
    }
    if (lines.length > 1) {
      final directLines = lines
          .where((l) => l.episodes.any((e) => e.isDirectPlayable))
          .toList(growable: false);
      if (directLines.isNotEmpty) {
        directLines.sort((a, b) {
          final aM3u8 = a.name.toLowerCase().contains('m3u8') ||
              a.episodes.first.url.toLowerCase().contains('.m3u8');
          final bM3u8 = b.name.toLowerCase().contains('m3u8') ||
              b.episodes.first.url.toLowerCase().contains('.m3u8');
          if (aM3u8 != bM3u8) return aM3u8 ? -1 : 1;
          return 0;
        });
        return directLines;
      }
    }
    return lines;
  }
  static List<LiveGroup> parseLivePlaylist(String content, {
    String origin = '', Map<String, String> headers = const {},
  }) => LiveCatalogParser.parse(content.length <= LiveCatalogParser.maxBytes ? unpackConfigText(content) : content, origin: origin,
      sourceHeaders: headers, resolve: resolveUrl);
  static int pageForEpisode(int index, int totalCount, bool descending) {
    if (totalCount <= 0) return 0;
    final clamped = index.clamp(0, totalCount - 1);
    final visualIndex = descending ? (totalCount - 1 - clamped) : clamped;
    return visualIndex ~/ episodePageSize;
  }
  static List<WatchHistoryEntry> upsertHistory(
    List<WatchHistoryEntry> existing,
    WatchHistoryEntry entry,
  ) {
    final result = <WatchHistoryEntry>[entry];
    for (final item in existing) {
      if (item.key != entry.key && result.length < maxHistoryEntries) {
        result.add(item);
      }
    }
    return result;
  }
  /// Encodes a cross-platform backup JSON string compatible with both Android (`format: MarcoMovie-1`)
  /// and Flutter (`schema: marco-movie-backup`).
  static String encodeBackupPayload({
    required String origin,
    required String rawConfig,
    required Map<String, dynamic> settings,
    int? exportedAt,
  }) {
    dynamic configValue;
    if (rawConfig.trim().isNotEmpty) {
      try {
        configValue = jsonDecode(stripJsonComments(unpackConfigText(rawConfig)));
      } catch (_) {
        configValue = rawConfig;
      }
    } else {
      configValue = null;
    }
    final payload = <String, dynamic>{
      'format': 'MarcoMovie-1',
      'schema': 'marco-movie-backup',
      'version': 1,
      'exportedAt': exportedAt ?? DateTime.now().millisecondsSinceEpoch,
      'origin': origin,
      'config': configValue,
      'settings': settings,
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }
  static bool isBackupPayload(String rawText) {
    try {
      final decoded = jsonDecode(stripJsonComments(rawText));
      if (decoded is! Map<String, dynamic>) return false;
      return decoded['format'] == 'MarcoMovie-1' ||
          decoded['schema'] == 'marco-movie-backup';
    } catch (_) {
      return false;
    }
  }
  /// Validates and decodes a backup JSON produced by either Android (`format: MarcoMovie-1`)
  /// or Flutter (`schema: marco-movie-backup`). Throws [FormatException] before any state mutation
  /// if the payload or embedded configuration is invalid.
  static ({
    String origin,
    String rawConfig,
    CmsConfig? parsedConfig,
    Map<String, dynamic> settings,
  }) decodeBackupPayload(String rawBackup) {
    final decoded = jsonDecode(stripJsonComments(rawBackup));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('不是有效的 Marco Movie 备份文件');
    }
    final isAndroidFormat = decoded['format'] == 'MarcoMovie-1';
    final isFlutterSchema = decoded['schema'] == 'marco-movie-backup';
    if (!isAndroidFormat && !isFlutterSchema) {
      throw const FormatException('不是有效的 Marco Movie 备份文件');
    }
    final origin = (decoded['origin'] ?? '').toString().trim();
    final rawCfgField = decoded['config'];
    String cfgText = '';
    if (rawCfgField == null) {
      cfgText = '';
    } else if (rawCfgField is Map) {
      cfgText = jsonEncode(rawCfgField);
    } else if (rawCfgField is String) {
      cfgText = rawCfgField.trim();
    } else {
      throw const FormatException('备份中的配置字段格式无效');
    }
    CmsConfig? parsedConfig;
    if (cfgText.isNotEmpty) {
      parsedConfig = parseConfig(cfgText, origin: origin);
    }
    final rawSettings = decoded['settings'];
    final settings = rawSettings is Map
        ? Map<String, dynamic>.from(rawSettings)
        : <String, dynamic>{};
    return (
      origin: origin,
      rawConfig: cfgText,
      parsedConfig: parsedConfig,
      settings: settings,
    );
  }

  /// Converts Arabic digits or Chinese numerals (`一`..`九十九`, `2026`, etc.) into an integer.
  static int parseChineseNumber(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return 1;
    final direct = int.tryParse(trimmed);
    if (direct != null && direct > 0) return direct;
    const digitMap = <String, int>{
      '零': 0,
      '〇': 0,
      '一': 1,
      '壹': 1,
      '二': 2,
      '两': 2,
      '贰': 2,
      '三': 3,
      '叁': 3,
      '四': 4,
      '肆': 4,
      '五': 5,
      '伍': 5,
      '六': 6,
      '陆': 6,
      '七': 7,
      '柒': 7,
      '八': 8,
      '捌': 8,
      '九': 9,
      '玖': 9,
    };
    if (trimmed == '十' || trimmed == '拾') return 10;
    if (trimmed.contains('十') || trimmed.contains('拾')) {
      final parts = trimmed.split(RegExp(r'[十拾]'));
      final tens = parts[0].isEmpty ? 1 : (digitMap[parts[0]] ?? 1);
      final ones =
          (parts.length > 1 && parts[1].isNotEmpty) ? (digitMap[parts[1]] ?? 0) : 0;
      final val = tens * 10 + ones;
      return val > 0 ? val : 1;
    }
    int acc = 0;
    for (int i = 0; i < trimmed.length; i++) {
      final d = digitMap[trimmed[i]];
      if (d != null) {
        acc = acc * 10 + d;
      }
    }
    return acc > 0 ? acc : 1;
  }

  /// Parses a video title into its franchise base title, season number, and display label.
  /// Examples:
  /// - `披荆斩棘第六季` -> `(baseTitle: '披荆斩棘', seasonNumber: 6, seasonLabel: '第 6 季', hasExplicitSeason: true)`
  /// - `全美超模大赛第二十一季` -> `(baseTitle: '全美超模大赛', seasonNumber: 21, seasonLabel: '第 21 季', hasExplicitSeason: true)`
  /// - `我家那闺女2026` -> `(baseTitle: '我家那闺女', seasonNumber: 2026, seasonLabel: '2026 季', hasExplicitSeason: true)`
  /// - `庆余年2` -> `(baseTitle: '庆余年', seasonNumber: 2, seasonLabel: '第 2 季', hasExplicitSeason: true)`
  /// - `谷雨` -> `(baseTitle: '谷雨', seasonNumber: 1, seasonLabel: '第 1 季', hasExplicitSeason: false)`
  static ({
    String baseTitle,
    int seasonNumber,
    String seasonLabel,
    bool hasExplicitSeason,
  }) parseSeriesSeasonInfo(String rawTitle) {
    var cleaned = rawTitle
        .replaceAll(
          RegExp(
            r'(\s*[\[【(（](?:4K|2160P|1080P|720P|HD|BD|国语|粤语|中字|双语|完结|全集|未删减)[^\]】)）]*[\]】)）])\s*$',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
    if (cleaned.isEmpty) cleaned = rawTitle.trim();

    // 1. Explicit `第 X 季/部/辑/篇` at end of title (optionally inside parentheses/brackets)
    final endCnMatch = RegExp(
      r'^(.+?)\s*(?:[（(\[【·:：\-—]\s*)?第\s*([一二三四五六七八九十百零〇两\d]+)\s*([季部辑篇])(?:\s*[)）\]】])?\s*$',
    ).firstMatch(cleaned);
    if (endCnMatch != null) {
      final base = endCnMatch.group(1)!.trim();
      final num = parseChineseNumber(endCnMatch.group(2)!);
      final unit = endCnMatch.group(3)!;
      if (base.isNotEmpty) {
        return (
          baseTitle: base,
          seasonNumber: num,
          seasonLabel: '第 $num $unit',
          hasExplicitSeason: true,
        );
      }
    }

    // 2. Explicit `第 X 季/部` in the middle followed by a subtitle (e.g. `凡人修仙传 第一季 风起天南`)
    final midCnMatch = RegExp(
      r'^([\u4e00-\u9fa5A-Za-z0-9·]+?)\s*第\s*([一二三四五六七八九十百零〇两\d]+)\s*([季部])(?:\s+|[:：·\-—]).*$',
    ).firstMatch(cleaned);
    if (midCnMatch != null) {
      final base = midCnMatch.group(1)!.trim();
      final num = parseChineseNumber(midCnMatch.group(2)!);
      final unit = midCnMatch.group(3)!;
      if (base.isNotEmpty) {
        return (
          baseTitle: base,
          seasonNumber: num,
          seasonLabel: '第 $num $unit',
          hasExplicitSeason: true,
        );
      }
    }

    // 3. `Season X` or `S01` / `S1`
    final enMatch = RegExp(
      r'^(.+?)\s*(?:[（(\[【·:：\-—]\s*)?(?:Season\s*0*(\d{1,2})|[Ss]0*(\d{1,2}))(?:\s*[)）\]】])?\s*$',
      caseSensitive: false,
    ).firstMatch(cleaned);
    if (enMatch != null) {
      final base = enMatch.group(1)!.trim();
      final numStr = enMatch.group(2) ?? enMatch.group(3) ?? '1';
      final num = int.tryParse(numStr) ?? 1;
      if (base.isNotEmpty && num > 0) {
        return (
          baseTitle: base,
          seasonNumber: num,
          seasonLabel: '第 $num 季',
          hasExplicitSeason: true,
        );
      }
    }

    // 4. Year-based season suffix (`2015`..`2035`), e.g. `我家那闺女2026`, `歌手2024`
    final yearMatch = RegExp(
      r'^([\u4e00-\u9fa5A-Za-z][\u4e00-\u9fa5A-Za-z0-9·\s]{1,22}?)\s*(?:[（(\[【·\-]\s*)?(20[123]\d)\s*[季期年]?(?:\s*[)）\]】])?\s*$',
    ).firstMatch(cleaned);
    if (yearMatch != null) {
      final base = yearMatch.group(1)!.trim();
      final yr = int.tryParse(yearMatch.group(2)!) ?? 1;
      if (base.isNotEmpty && !RegExp(r'^\d+$').hasMatch(base)) {
        return (
          baseTitle: base,
          seasonNumber: yr,
          seasonLabel: '$yr 季',
          hasExplicitSeason: true,
        );
      }
    }

    // 5. Trailing sequel number `1..9` after a Chinese title (e.g. `庆余年2`, `白夜追凶2`, `流浪地球2`)
    final seqMatch = RegExp(
      r'^([\u4e00-\u9fa5]{2,16})\s*([1-9])\s*$',
    ).firstMatch(cleaned);
    if (seqMatch != null) {
      final base = seqMatch.group(1)!.trim();
      final num = int.tryParse(seqMatch.group(2)!) ?? 1;
      if (base.isNotEmpty) {
        return (
          baseTitle: base,
          seasonNumber: num,
          seasonLabel: '第 $num 季',
          hasExplicitSeason: true,
        );
      }
    }

    return (
      baseTitle: cleaned,
      seasonNumber: 1,
      seasonLabel: '第 1 季',
      hasExplicitSeason: false,
    );
  }

  static String _normalizeFranchiseKey(String raw) {
    return raw
        .toLowerCase()
        .replaceAll(
          RegExp(r'[\s·:：\-—_（）()【】\[\]《》〈〉"“”' "'" r'’!！?？,，.。]'),
          '',
        )
        .trim();
  }

  static bool _hasExtraDerivativeTag(String rawTitle) {
    return RegExp(r'(花絮|特辑|彩蛋|纯享|加更|幕后|纪录片|演唱会|预告|解说|速看|陪看|合集篇)')
        .hasMatch(rawTitle);
  }

  /// Checks whether [candidateTitle] belongs to the same multi-season franchise as [currentTitle].
  static bool isSameFranchiseSeasonCandidate(
    String currentTitle,
    String candidateTitle,
  ) {
    final cur = parseSeriesSeasonInfo(currentTitle);
    final cand = parseSeriesSeasonInfo(candidateTitle);
    final curNorm = _normalizeFranchiseKey(cur.baseTitle);
    final candNorm = _normalizeFranchiseKey(cand.baseTitle);
    if (curNorm.isEmpty || curNorm != candNorm) return false;
    if (_hasExtraDerivativeTag(candidateTitle) !=
        _hasExtraDerivativeTag(currentTitle)) {
      return false;
    }
    return true;
  }

  /// Detects an explicit season number inside an episode name (`S01E02`, `第2季01`, etc.).
  static int? detectEpisodeSeasonNumber(String rawEpisodeName) {
    final seMatch = RegExp(
      r'(?:^|[^A-Za-z0-9])[Ss]0*(\d{1,2})\s*(?:[Ee]\s*\d+|[\]】)）\s.\-_])',
    ).firstMatch(rawEpisodeName);
    if (seMatch != null) {
      final n = int.tryParse(seMatch.group(1)!);
      if (n != null && n > 0 && n <= 99) return n;
    }
    final cnMatch = RegExp(
      r'第\s*([一二三四五六七八九十两\d]+)\s*[季部]',
    ).firstMatch(rawEpisodeName);
    if (cnMatch != null) {
      final n = parseChineseNumber(cnMatch.group(1)!);
      if (n > 0 && n <= 99) return n;
    }
    return null;
  }

  /// Extracts in-line season groups when a single [CmsLine] contains episodes across
  /// multiple seasons (e.g. `S01E01..S01E08`, `S02E01..S02E08`).
  /// Returns an empty list if the line does not span multiple seasons.
  static List<({
    int seasonNumber,
    String seasonLabel,
    List<int> episodeIndexes,
  })> extractInLineSeasons(List<CmsEpisode> episodes) {
    if (episodes.length < 2) return const [];
    final buckets = <int, List<int>>{};
    int? lastDetectedSeason;
    int explicitCount = 0;
    for (int i = 0; i < episodes.length; i++) {
      final detected = detectEpisodeSeasonNumber(episodes[i].name);
      if (detected != null) {
        explicitCount++;
        lastDetectedSeason = detected;
      }
      final bucketKey = detected ?? lastDetectedSeason;
      if (bucketKey != null) {
        buckets.putIfAbsent(bucketKey, () => <int>[]).add(i);
      }
    }
    if (buckets.length < 2 || explicitCount < 2) return const [];
    // If any leading episodes before the first explicit marker were missed, attach them to the first season
    final sortedKeys = buckets.keys.toList()..sort();
    final assigned = buckets.values.expand((e) => e).toSet();
    if (assigned.length < episodes.length) {
      final firstList = buckets[sortedKeys.first]!;
      for (int i = 0; i < episodes.length; i++) {
        if (!assigned.contains(i)) {
          firstList.insert(0, i);
        }
      }
      firstList.sort();
    }
    return [
      for (final k in sortedKeys)
        (
          seasonNumber: k,
          seasonLabel: k >= 1990 ? '$k 季' : '第 $k 季',
          episodeIndexes: List<int>.unmodifiable(buckets[k]!),
        ),
    ];
  }
}
