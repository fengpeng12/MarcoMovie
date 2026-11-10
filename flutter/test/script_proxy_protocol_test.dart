import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/script_proxy_protocol.dart';
import 'package:marco_movie/core/script_proxy_server.dart';

void main() {
  test('three item text uses UTF8 without interpreting its contents', () {
    const body = '#EXTM3U\n片段/one.ts\n';
    final result = ScriptProxyProtocol.decode([
      200,
      'application/vnd.apple.mpegurl',
      body,
    ]);
    expect(result.statusCode, 200);
    expect(result.contentType, 'application/vnd.apple.mpegurl');
    expect(result.body, utf8.encode(body));
    expect(result.headers, isEmpty);
    expect(
      utf8.decode(
        ScriptProxyProtocol.decode([200, 'text/plain', 'AP+AQQ==']).body,
      ),
      'AP+AQQ==',
    );
    expect(
      utf8.decode(
        ScriptProxyProtocol.decode([
          200,
          'text/plain',
          '{"private":"body"}',
        ]).body,
      ),
      '{"private":"body"}',
    );
  });

  test(
    'accepts exactly one JSON serialization and optional response headers',
    () {
      final result = ScriptProxyProtocol.decode(
        jsonEncode([
          206,
          'video/mp2t',
          [0, 255, 128, 65],
          {'Content-Range': 'bytes 4-7/100', 'X-Upstream': 'fixture'},
          0,
        ]),
      );
      expect(result.statusCode, 206);
      expect(result.body, [0, 255, 128, 65]);
      expect(result.headers['Content-Range'], 'bytes 4-7/100');
      expect(
        () => result.headers['Injected'] = 'value',
        throwsUnsupportedError,
      );
      expect(
        () => ScriptProxyProtocol.decode(
          jsonEncode(jsonEncode([200, 'text/plain', 'x'])),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'raw integer bytes remain bytes even when legacy Base64 flag is set',
    () {
      final input = Uint8List.fromList([0, 127, 128, 255]);
      final result = ScriptProxyProtocol.decode([
        200,
        'application/octet-stream',
        input,
        null,
        1,
      ]);
      input[0] = 5;
      expect(result.body, [0, 127, 128, 255]);
      for (final body in [
        [-1],
        [256],
        [1.0],
        [true],
        ['1'],
        {'0': 0},
        null,
      ]) {
        expect(
          () => ScriptProxyProtocol.decode([
            200,
            'application/octet-stream',
            body,
          ]),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'Base64 is explicit, canonical, optionally line wrapped or a data URI',
    () {
      for (final text in [
        'AP+AQQ==',
        'AP+A\r\nQQ==\t',
        'data:application/octet-stream;base64,AP+AQQ==',
        'data:;base64,AP+AQQ==',
      ]) {
        expect(
          ScriptProxyProtocol.decode([
            200,
            'application/octet-stream',
            text,
            null,
            1,
          ]).body,
          [0, 255, 128, 65],
        );
      }
      expect(
        ScriptProxyProtocol.decode([200, 'text/plain', '', null, 1]).body,
        isEmpty,
      );
      for (final invalid in [
        'AP+AQQ',
        'AP-AQQ==',
        'AA=A',
        'A===',
        'AB==',
        'data:text/plain,AP+AQQ==',
        'data:text/plain;BASE64,AP+AQQ==',
        'data:text/plain;foo=\n;base64,AP+AQQ==',
        'prefix base64,AP+AQQ==',
      ]) {
        expect(
          () => ScriptProxyProtocol.decode([
            200,
            'application/octet-stream',
            invalid,
            null,
            1,
          ]),
          throwsFormatException,
          reason:
              'Malformed Base64 must not become a successful empty response',
        );
      }
    },
  );

  test('status, MIME, shape and encoding flags have strict boundaries', () {
    for (final status in [200, 204, 206, 304, 404, 416, 599]) {
      expect(
        ScriptProxyProtocol.decode([
          status,
          'text/plain; charset=utf-8',
          '',
        ]).statusCode,
        status,
      );
    }
    for (final value in [
      null,
      {},
      [],
      [200, 'text/plain'],
      [200, 'text/plain', '', null, 0, 'extra'],
      ['200', 'text/plain', ''],
      [200.0, 'text/plain', ''],
      [199, 'text/plain', ''],
      [600, 'text/plain', ''],
      [200, '', ''],
      [200, 'invalid', ''],
      [200, 'text/plain\r\nBad: value', ''],
      [200, 'text/中文', ''],
      [200, 'text/plain', '', null, true],
      [200, 'text/plain', '', null, 2],
      [200, 'text/plain', '', null, null],
    ]) {
      expect(() => ScriptProxyProtocol.decode(value), throwsFormatException);
    }
  });

  test(
    'headers reject injection, duplicates, non-strings and excessive size',
    () {
      for (final headers in [
        [],
        '{"x":"y"}',
        {'X': 1},
        {1: 'value'},
        {'Bad Name': 'value'},
        {'X': 'first', 'x': 'second'},
        {'X': 'ok\r\nInjected: value'},
        {'X': '\u000b'},
        {'X': '中文'},
        {for (var i = 0; i < 65; i++) 'X-$i': 'value'},
        {'X': 'a' * (16 * 1024)},
      ]) {
        expect(
          () => ScriptProxyProtocol.decode([200, 'text/plain', '', headers]),
          throwsFormatException,
        );
      }
      expect(
        ScriptProxyProtocol.decode([200, 'text/plain', '', null]).headers,
        isEmpty,
      );
    },
  );

  test(
    'body limit counts decoded bytes and canonical Base64 at the limit works',
    () {
      const limit = ScriptProxyServer.maxResponseBytes;
      final full = Uint8List(limit);
      full[limit - 1] = 255;
      final encoded = base64Encode(full);
      final result = ScriptProxyProtocol.decode([
        200,
        'application/octet-stream',
        encoded,
        null,
        1,
      ]);
      expect(result.body.length, limit);
      expect(result.body.last, 255);
      expect(
        () => ScriptProxyProtocol.decode([
          200,
          'application/octet-stream',
          Uint8List(limit + 1),
        ]),
        throwsFormatException,
      );
      expect(
        () => ScriptProxyProtocol.decode([
          200,
          'text/plain',
          '中' * (limit ~/ 3 + 1),
        ]),
        throwsFormatException,
      );
      expect(
        () => ScriptProxyProtocol.decode([
          200,
          'application/octet-stream',
          '${encoded}AAAA',
          null,
          1,
        ]),
        throwsFormatException,
      );
    },
  );

  test(
    'invalid JSON diagnostics do not expose source media or token values',
    () {
      try {
        ScriptProxyProtocol.decode('[200,"text/plain","private-fixture-token"');
        fail('must reject invalid JSON');
      } on FormatException catch (error) {
        expect(error.toString(), isNot(contains('private-fixture-token')));
      }
    },
  );
}
