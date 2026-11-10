import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/app_update.dart';

void main() {
  test('mirror error falls back to the actual GitHub asset and normalizes preview tag', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      if (request.url.host != 'api.github.com') return http.Response('', 500);
      return http.Response(jsonEncode({'tag_name': 'v0.4.37-preview', 'assets': [{
        'name': 'MarcoMovie-0.4.37-windows-setup.exe', 'size': 20,
        'digest': 'sha256:${'a' * 64}',
        'browser_download_url': 'https://github.com/Pilipala9919/MarcoMovie/releases/download/v0.4.37-preview/MarcoMovie-0.4.37-windows-setup.exe',
      }]}), 200);
    });
    final release = await AppUpdate.check(client: client, platform: 'windows');
    expect(calls, 2);
    expect(release.version, '0.4.37');
    expect(release.windowsUrl!.path, isNot(contains('preview-preview')));
  });
  test('failed checks never return current version as a successful result', () async {
    await expectLater(AppUpdate.check(client: MockClient((_) async => http.Response('', 503))),
        throwsA(isA<HttpException>()));
  });
  test('missing metadata and foreign host cannot enable an installer', () {
    final release = AppUpdate.parse({'versionName': '0.4.37', 'windows': {
      'url': 'https://unknown.example/MarcoMovie-0.4.37-windows-setup.exe',
      'sha256': 'a' * 64, 'size': 20,
    }});
    expect(release.windowsUrl, isNull);
    expect(AppUpdate.parse({'versionName': '0.4.37'}).windowsUrl, isNull);
  });
  test('same-length corruption and truncated installers fail verification', () async {
    final dir = await Directory.systemTemp.createTemp('marco-update-check-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/installer.exe');
    final good = utf8.encode('verified installer fixture');
    final release = AppUpdate('0.4.37', '', Uri.parse('https://github.com/Pilipala9919/MarcoMovie/releases/download/v0.4.37-preview/MarcoMovie-0.4.37-windows-setup.exe'), sha256.convert(good).toString(), good.length);
    await file.writeAsBytes(good);
    await release.verifyFile(file);
    await file.writeAsBytes(List.filled(good.length, 0));
    await expectLater(release.verifyFile(file), throwsFormatException);
    await file.writeAsBytes([1]);
    await expectLater(release.verifyFile(file), throwsFormatException);
  });

  test('platform releases do not upgrade other devices or choose a prerelease', () async {
    Map<String, dynamic> release(String platform, String version, String suffix,
        {bool prerelease = false}) => {
      'tag_name': '$platform-v$version', 'prerelease': prerelease,
      'assets': [{
        'name': 'MarcoMovie-$version-$suffix', 'size': 20,
        'digest': 'sha256:${'a' * 64}',
        'browser_download_url': 'https://github.com/Pilipala9919/MarcoMovie/releases/download/$platform-v$version/MarcoMovie-$version-$suffix',
      }],
    };
    final client = MockClient((request) async {
      if (request.url.host != 'api.github.com') return http.Response('', 404);
      return http.Response(jsonEncode([
        release('windows', '0.8.0', 'windows-setup.exe'),
        release('ios', '0.5.2', 'ios-unsigned.ipa', prerelease: true),
        release('ios', '0.5.1', 'ios-unsigned.ipa'),
        release('ios', '0.4.99', 'ios-unsigned.ipa'),
      ]), 200);
    });
    final ios = await AppUpdate.check(client: client, platform: 'ios');
    expect(ios.version, '0.5.1');
    expect(ios.windowsUrl, isNull);
    final windows = await AppUpdate.check(client: client, platform: 'windows');
    expect(windows.version, '0.8.0');
    expect(windows.windowsUrl, isNotNull);
  });

  test('independent mirror feed wins without changing the legacy Android feed', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/movie/updates/ios.json');
      return http.Response(jsonEncode({
        'platform': 'ios', 'versionName': '0.5.1', 'notes': 'iPhone update',
      }), 200);
    });
    final release = await AppUpdate.check(client: client, platform: 'ios');
    expect(release.version, '0.5.1');
    expect(release.windowsUrl, isNull);
    expect(() => AppUpdate.parse({'platform': 'ios', 'versionName': '0.5.1'}),
        throwsFormatException);
  });
}
