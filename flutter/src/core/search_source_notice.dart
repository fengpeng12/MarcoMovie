import 'dart:async';

import 'catpaw_host.dart';

/// User-facing search failures use trusted messages, never server response text,
/// subscription addresses, or download credentials.
String searchSourceNotice(Object error) {
  if (error is DrpySourceException &&
      error.code == 'drpy_verification_required') {
    return '需要完成网站验证码，暂时无法搜索';
  }
  if (error is TimeoutException) return '请求超时，请稍后重试';
  return '暂时无法读取，请稍后重试或更换片源';
}
