import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/catpaw_host.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/drpy_source.dart';
import 'package:marco_movie/core/guard_source.dart';
import 'package:marco_movie/core/models.dart';

class PortHost extends CatPawHost {
  int bootstraps = 0;
  String? failure;
  Map<String, Object?>? playback;
  Map<String, dynamic>? manifest;
  final adapters = <String>[];
  final extensions = <String?>[];
  final installed = <String, Map<String, dynamic>>{};
  final invoked = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> bootstrapGuard(
    List<int> bytes, {
    String adapter = 'dm84-v1',
    String? extension,
    Completer<void>? cancellation,
  }) async {
    bootstraps++;
    adapters.add(adapter);
    extensions.add(extension);
    if (failure != null)
      throw GuardBootstrapException(failure!, 'Synthetic bootstrap failure');
    return {
      'version': 1,
      'origin': 'https://catalogue.invalid/',
      'rule':
          'var rule={title:${jsonEncode('$adapter fixture ${extension ?? ''}')},host:"https://catalogue.invalid"};',
    };
  }

  @override
  Future<String> installDrpy(Object value) async {
    manifest = Map<String, dynamic>.from(value as Map);
    final address =
        'catpaw://${sha256.convert(utf8.encode(jsonEncode(manifest)))}/api/drpy';
    installed[address] = manifest!;
    return address;
  }

  @override
  Future<String> callDrpy(
    String address,
    String method,
    List<Object?> args, {
    Completer<void>? cancellation,
  }) async {
    invoked.add(installed[address]!);
    return jsonEncode(
      method == 'play' && playback != null
          ? playback
          : {'method': method, 'list': []},
    );
  }
}

void main() {
  final bytes = Uint8List.fromList([0x50, 0x4b, 3, 4, 1, 2, 3]);
  final digest = md5.convert(bytes).toString();
  CmsSite site(String reference) => CmsSite(
    key: 'dm84',
    name: 'Imported rule',
    type: 3,
    api: 'csp_Dm84Guard',
    jar: reference,
    subscriptionId: 'one',
    headers: {
      'Authorization': 'import credential',
      'Cookie': 'import=fixture',
      'User-Agent': 'Fixture',
    },
  );

  test(
    'exact aliases select adapters and unknown Guard names never download',
    () async {
      final host = PortHost();
      var downloads = 0;
      final guard = GuardSource(
        host: host,
        drpy: DrpySource(host: host, read: (_, __) async => ''),
        read: (_, __) async {
          downloads++;
          return bytes;
        },
      );
      for (final api in [
        'csp_Dm84Guard',
        'csp_Dm84',
        'csp_AueteGuard',
        'csp_Auete',
        'csp_BttwooGuard',
        'csp_Bttwoo',
        'csp_T4Guard',
        'csp_T4',
        'csp_FyGuard',
        'csp_Fy',
      ]) {
        final source = site(
          'https://import.invalid/plugin.jar',
        ).copyWith(api: api);
        expect(GuardSource.supports(source), isTrue, reason: api);
        expect(source.canBrowse, isTrue, reason: api);
      }
      for (final api in [
        'csp_UnknownGuard',
        'csp_AueteOtherGuard',
        'csp_BttwooOtherGuard',
        'csp_Dm84Guard/extra',
        'csp_T4OtherGuard',
        'csp_FyOtherGuard',
        'csp_AppgzGuard',
      ]) {
        final source = site(
          'https://import.invalid/plugin.jar',
        ).copyWith(api: api);
        expect(GuardSource.supports(source), isFalse);
        await expectLater(
          guard.invoke(source, 'home', [false]),
          throwsFormatException,
        );
      }
      expect(
        GuardSource.supports(
          site('https://import.invalid/plugin.jar').copyWith(type: 1),
        ),
        isFalse,
      );
      expect(downloads, 0);
      expect(host.bootstraps, 0);
    },
  );

  test(
    'T4 extension is forwarded and separates cached configuration',
    () async {
      final host = PortHost();
      var downloads = 0;
      final guard = GuardSource(
        host: host,
        drpy: DrpySource(host: host, read: (_, __) async => ''),
        read: (_, __) async {
          downloads++;
          return bytes;
        },
      );
      final first = site(
        'https://import.invalid/plugin.jar',
      ).copyWith(api: 'csp_T4Guard', ext: 'Zmlyc3Q=');
      final second = first.copyWith(ext: 'c2Vjb25k');
      await guard.invoke(first, 'home', [false]);
      final firstRule = host.invoked.last['rule'];
      await guard.invoke(second, 'home', [false]);
      expect(host.invoked.last['rule'], isNot(firstRule));
      await guard.invoke(first.copyWith(api: 'csp_T4'), 'home', [false]);
      expect(host.invoked.last['rule'], firstRule);
      expect(host.extensions, ['Zmlyc3Q=', 'c2Vjb25k']);
      expect(downloads, 2);
      for (final invalid in ['', '汉' * 6000]) {
        await expectLater(
          guard.invoke(first.copyWith(ext: invalid), 'home', [false]),
          throwsFormatException,
        );
      }
      expect(downloads, 2);
    },
  );

  test(
    'one owner key and JAR keep adapter cache, manifest and state isolated',
    () async {
      final host = PortHost();
      var downloads = 0;
      final guard = GuardSource(
        host: host,
        drpy: DrpySource(host: host, read: (_, __) async => ''),
        read: (_, __) async {
          downloads++;
          return bytes;
        },
      );
      final dm84 = site('https://import.invalid/plugin.jar;md5;$digest');
      final auete = dm84.copyWith(api: 'csp_AueteGuard');
      final bttwoo = dm84.copyWith(api: 'csp_BttwooGuard');
      await guard.invoke(dm84, 'home', [false]);
      final dmManifest = host.invoked.last;
      await guard.invoke(auete, 'home', [false]);
      final aueteManifest = host.invoked.last;
      await guard.invoke(bttwoo, 'home', [false]);
      final bttwooManifest = host.invoked.last;
      expect(dmManifest['rule'], contains('dm84-v1'));
      expect(aueteManifest['rule'], contains('auete-v1'));
      expect(aueteManifest['sourceId'], isNot(dmManifest['sourceId']));
      expect(bttwooManifest['rule'], contains('bttwoo-v1'));
      expect({
        dmManifest['sourceId'],
        aueteManifest['sourceId'],
        bttwooManifest['sourceId'],
      }, hasLength(3));
      await guard.invoke(dm84, 'search', ['one', false, 1]);
      expect(host.invoked.last, dmManifest);
      await guard.invoke(auete.copyWith(api: 'csp_Auete'), 'search', [
        'two',
        false,
        1,
      ]);
      expect(host.invoked.last['sourceId'], aueteManifest['sourceId']);
      await guard.invoke(bttwoo.copyWith(api: 'csp_Bttwoo'), 'search', [
        'three',
        false,
        1,
      ]);
      expect(host.invoked.last['sourceId'], bttwooManifest['sourceId']);
      expect(host.adapters, ['dm84-v1', 'auete-v1', 'bttwoo-v1']);
      expect(downloads, 3);
      expect(dm84.key, 'dm84');
      expect(auete.key, 'dm84');
      expect(dm84.subscriptionId, 'one');
      expect(auete.subscriptionId, 'one');
      expect(dm84.api, 'csp_Dm84Guard');
      expect(auete.api, 'csp_AueteGuard');
      expect(dm84.jar, auete.jar);
      expect(bttwoo.key, dm84.key);
      expect(bttwoo.subscriptionId, dm84.subscriptionId);
      expect(bttwoo.jar, dm84.jar);
      expect(bttwoo.api, 'csp_BttwooGuard');
    },
  );

  test(
    'Auete siteUrl variants fail explicitly before download or cached execution',
    () async {
      final host = PortHost();
      var downloads = 0;
      final guard = GuardSource(
        host: host,
        drpy: DrpySource(host: host, read: (_, __) async => ''),
        read: (_, __) async {
          downloads++;
          return bytes;
        },
      );
      final source = site(
        'https://import.invalid/plugin.jar',
      ).copyWith(api: 'csp_AueteGuard');
      for (final override in [
        'https://custom.invalid/',
        'https://catalogue.invalid/',
      ]) {
        final configured = source.copyWith(
          ext: jsonEncode({'siteUrl': override}),
        );
        await expectLater(
          guard.invoke(configured, 'home', [false]),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('siteUrl'),
            ),
          ),
        );
      }
      expect(downloads, 0);
      expect(host.bootstraps, 0);
      await guard.invoke(source.copyWith(ext: '{"siteUrl":""}'), 'home', [
        false,
      ]);
      expect(downloads, 1);
      final calls = host.invoked.length;
      await expectLater(
        guard.invoke(
          source.copyWith(ext: '{"siteUrl":"https://custom.invalid/"}'),
          'home',
          [false],
        ),
        throwsFormatException,
      );
      expect(downloads, 1);
      expect(host.invoked.length, calls);
    },
  );

  test(
    'Bttwoo siteUrl variants fail before downloading or reusing cache',
    () async {
      final host = PortHost();
      var downloads = 0;
      final guard = GuardSource(
        host: host,
        drpy: DrpySource(host: host, read: (_, __) async => ''),
        read: (_, __) async {
          downloads++;
          return bytes;
        },
      );
      final source = site(
        'https://import.invalid/plugin.jar',
      ).copyWith(api: 'csp_BttwooGuard');
      final override = source.copyWith(
        ext: '{"siteUrl":"https://custom.invalid/"}',
      );
      await expectLater(
        guard.invoke(override, 'home', [false]),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Bttwoo 自定义 siteUrl'),
          ),
        ),
      );
      expect(downloads, 0);
      expect(host.bootstraps, 0);
      await guard.invoke(source.copyWith(ext: '{"siteUrl":""}'), 'home', [
        false,
      ]);
      final calls = host.invoked.length;
      await expectLater(
        guard.invoke(override, 'home', [false]),
        throwsFormatException,
      );
      expect(downloads, 1);
      expect(host.invoked.length, calls);
    },
  );

  test(
    'ownerless Auete imports retain their independent origin identity',
    () async {
      final host = PortHost();
      final guard = GuardSource(
        host: host,
        drpy: DrpySource(host: host, read: (_, __) async => ''),
        read: (_, __) async => bytes,
      );
      final first = site(
        'https://first.invalid/plugin.jar',
      ).copyWith(api: 'csp_AueteGuard', subscriptionId: '');
      final second = first.copyWith(jar: 'https://second.invalid/plugin.jar');
      await guard.invoke(first, 'home', [false]);
      final firstId = host.invoked.last['sourceId'];
      await guard.invoke(second, 'home', [false]);
      expect(host.invoked.last['sourceId'], isNot(firstId));
      expect(first.subscriptionId, isEmpty);
      expect(second.subscriptionId, isEmpty);
    },
  );

  test(
    'artifact integrity is verified before local bootstrap and download auth stays scoped',
    () async {
      final host = PortHost();
      var downloads = 0;
      final drpy = DrpySource(
        host: host,
        read: (_, __) async => throw StateError('rule is already local'),
      );
      final guard = GuardSource(
        host: host,
        drpy: drpy,
        read: (url, headers) async {
          downloads++;
          expect(url, 'https://import.invalid/plugin.jar');
          expect(headers['Authorization'], 'import credential');
          return bytes;
        },
      );
      final source = site('https://import.invalid/plugin.jar;md5;$digest');
      expect(GuardSource.supports(source), isTrue);
      expect(source.canBrowse, isTrue);
      expect(
        GuardSource.supports(source.copyWith(api: 'csp_UnknownGuard')),
        isFalse,
      );
      expect(GuardSource.supports(source.copyWith(jar: '')), isFalse);
      await guard.invoke(source, 'home', [false]);
      await guard.invoke(source, 'search', ['影片', false, 1]);
      expect(downloads, 1);
      expect(host.bootstraps, 1);
      expect(host.manifest!['origin'], 'https://catalogue.invalid/');
      expect(host.manifest!['headers'], {'User-Agent': 'Fixture'});
    },
  );

  test(
    'malformed and mismatched explicit MD5 never fall back to another plugin',
    () async {
      final host = PortHost();
      var downloads = 0;
      final guard = GuardSource(
        host: host,
        drpy: DrpySource(host: host, read: (_, __) async => ''),
        read: (_, __) async {
          downloads++;
          return bytes;
        },
      );
      await expectLater(
        guard.invoke(
          site('https://import.invalid/plugin.jar;md5;broken'),
          'home',
          [false],
        ),
        throwsFormatException,
      );
      expect(downloads, 0);
      for (final suffix in [
        '',
        ' ',
        '$digest ',
        ' $digest',
        '$digest;md5;$digest',
      ]) {
        await expectLater(
          guard.invoke(
            site('https://import.invalid/plugin.jar;MD5;$suffix'),
            'home',
            [false],
          ),
          throwsFormatException,
        );
      }
      expect(downloads, 0);
      await expectLater(
        guard.invoke(
          site('https://import.invalid/plugin.jar;md5;${'0' * 32}'),
          'home',
          [false],
        ),
        throwsFormatException,
      );
      expect(downloads, 1);
      expect(host.bootstraps, 0);
      final cancelled = Completer<void>()..complete();
      await expectLater(
        guard.invoke(site('https://import.invalid/plugin.jar'), 'home', [
          false,
        ], cancellation: cancelled),
        throwsFormatException,
      );
      expect(downloads, 1);
    },
  );

  test('unsupported plugin version remains an explicit failure', () async {
    final host = PortHost()..failure = 'guard_artifact_unsupported';
    final guard = GuardSource(
      host: host,
      drpy: DrpySource(host: host, read: (_, __) async => ''),
      read: (_, __) async => bytes,
    );
    await expectLater(
      guard.invoke(site('https://import.invalid/plugin.jar'), 'home', [false]),
      throwsA(
        isA<GuardBootstrapException>().having(
          (e) => e.code,
          'code',
          'guard_artifact_unsupported',
        ),
      ),
    );
    expect(host.manifest, isNull);
  });

  test(
    'plugin import credentials never become implicit playback headers',
    () async {
      final host = PortHost()
        ..playback = {
          'parse': 0,
          'url': 'https://import.invalid/video.mp4',
          'header': {
            'User-Agent': 'Adapter playback',
            'X-Playback': 'explicit',
          },
        };
      final client = CmsClient(
        scriptHost: host,
        client: MockClient((request) async => http.Response.bytes(bytes, 200)),
      );
      final source = site(
        'https://import.invalid/plugin.jar;md5;$digest',
      ).copyWith(ext: 'https://import.invalid/');
      final resolved = await client.resolveEpisodeForPlayback(
        source,
        const CmsEpisode(
          name: 'Episode',
          url: 'mmjs://play?id=episode&flag=main',
        ),
      );
      expect(resolved.headers, {
        'User-Agent': 'Adapter playback',
        'X-Playback': 'explicit',
      });
    },
  );
}
