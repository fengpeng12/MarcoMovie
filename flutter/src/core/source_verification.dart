import 'dart:convert';
import 'dart:typed_data';

/// Image bytes only. A source cannot replace the dialog with remote HTML/URLs.
class SourceImageChallenge {
  final String id;
  final String mime;
  final Uint8List bytes;
  const SourceImageChallenge(this.id, this.mime, this.bytes);

  factory SourceImageChallenge.fromResponse(Map<String, dynamic> value) {
    final id = value['id'],
        mime = value['mime'],
        encoded = value['imageBase64'];
    if (value['type'] != 'image' ||
        id is! String ||
        !RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(id) ||
        !const [
          'image/png',
          'image/jpeg',
          'image/webp',
          'image/gif',
        ].contains(mime) ||
        encoded is! String ||
        encoded.isEmpty ||
        encoded.length > 350000 ||
        !RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(encoded)) {
      throw const FormatException('验证码图片无效，请刷新后重试');
    }
    final bytes = base64Decode(encoded);
    bool starts(List<int> prefix) =>
        bytes.length >= prefix.length &&
        List.generate(
          prefix.length,
          (i) => bytes[i] == prefix[i],
        ).every((v) => v);
    final valid = switch (mime) {
      'image/png' => starts([137, 80, 78, 71, 13, 10, 26, 10]),
      'image/jpeg' => starts([255, 216, 255]),
      'image/gif' =>
        starts(ascii.encode('GIF87a')) || starts(ascii.encode('GIF89a')),
      'image/webp' =>
        starts(ascii.encode('RIFF')) &&
            bytes.length > 12 &&
            ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP',
      _ => false,
    };
    if (!valid || bytes.length > 262500) {
      throw const FormatException('验证码图片无效，请刷新后重试');
    }
    return SourceImageChallenge(id, mime as String, bytes);
  }
}
