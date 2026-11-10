import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/catpaw_host.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'catpaw_test.dart' show bundle;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // CatPaw's native Node host uses real local HTTP.

  test('desktop source host reads actual saved accounts and clears stale cookies', () async {
    SharedPreferences.setMockInitialValues({
      StorageService.keyUcCookie: '__pus=synthetic-uc',
      StorageService.keyBaiduCookie: 'BDUSS=synthetic-baidu; STOKEN=synthetic-session',
      StorageService.keyQuarkCookie: 'qr_auth_invalid',
      'mm_netdisk_cred_uc_v1': '__pus=obsolete-account',
    });
    final storage = StorageService(await SharedPreferences.getInstance());
    final directory = await Directory.systemTemp.createTemp('marco-desktop-pan-test-');
    final node = (await Process.run('node', ['-p', 'process.execPath'])).stdout.toString().trim();
    final host = CatPawHost(directory: () async => directory, executable: node,
        bootstrap: '${Directory.current.path}/assets/catpaw/host.cjs');
    addTearDown(() async {
      await host.close();
      await directory.delete(recursive: true);
    });
    final config = jsonDecode(await host.install(bundle));
    final source = Uri.parse(config['sites'][0]['api'] as String);
    final configFile = File('${directory.path}/wexfnwconfig.json');
    final first = jsonDecode(await configFile.readAsString())['pan'];
    expect(first['uc']['cookie'], '__pus=synthetic-uc');
    expect(first['baidu']['cookie'], 'BDUSS=synthetic-baidu; STOKEN=synthetic-session');
    expect(first['quark']['cookie'], isEmpty);
    await storage.setNetdiskCred('uc', '');
    await storage.setNetdiskCred('baidu', 'bduss=one-use-qr-ticket');
    await host.resolve(source.replace(path: '/api/spider/fixture').toString());
    final cleared = jsonDecode(await configFile.readAsString())['pan'];
    expect(cleared['uc']['cookie'], isEmpty);
    expect(cleared['baidu']['cookie'], isEmpty);
  });
}
