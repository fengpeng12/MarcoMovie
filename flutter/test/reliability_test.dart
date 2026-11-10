import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/cms_parser.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';

const configText = '{"sites":[{"key":"a","name":"A","type":1,"api":"https://a.example/api"},'
    '{"key":"b","name":"B","type":1,"api":"https://b.example/api"},'
    '{"key":"c","name":"C","type":1,"api":"https://c.example/api"}]}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ZIP relative live playlist survives saving the returned config', () async {
    final archive = Archive()
      ..addFile(ArchiveFile.string('nested/config.json', '{"lives":[{"name":"Local","url":"../lists/live.txt"}]}'))
      ..addFile(ArchiveFile.string('lists/live.txt', 'Demo,http://127.0.0.1:8765/stream.m3u8'));
    final raw = CmsClient.readSubscriptionFile(ZipEncoder().encode(archive), 'sources.zip');
    final config = CmsParser.parseConfig(raw);
    final groups = await CmsClient().fetchLiveGroups(config.lives.single);
    expect(groups.single.channels.single.urls.single, 'http://127.0.0.1:8765/stream.m3u8');
  });

  test('playlist-only ZIP provides inline live and VOD entries', () async {
    final archive = Archive()..addFile(ArchiveFile.string('list.txt', 'Demo,http://127.0.0.1:8765/stream.m3u8'));
    final raw = CmsClient.readSubscriptionFile(ZipEncoder().encode(archive), 'playlist.zip');
    final config = CmsParser.parseConfig(raw, origin: 'https://playlist.example/playlist.zip');
    expect(config.sites.single.isM3uVodApi, true);
    final groups = await CmsClient().fetchLiveGroups(config.lives.single);
    expect(groups.single.channels.single.name, 'Demo');
  });

  test('ZIP with missing referenced playlist fails instead of dropping live entries', () {
    final archive = Archive()..addFile(ArchiveFile.string('config.json', '{"lives":[{"name":"Missing","url":"live.txt"}]}'));
    expect(() => CmsClient.readSubscriptionFile(ZipEncoder().encode(archive), 'bad.zip'), throwsFormatException);
  });

  test('unsupported plugins do not prevent healthy CMS search', () async {
    final config = CmsParser.parseConfig('{"sites":['
        '{"key":"plugin","name":"Plugin","type":3,"api":"csp_Unknown"},'
        '{"key":"cms","name":"CMS","type":1,"api":"https://cms.example/api"}]}');
    final transport = MockClient((request) async => http.Response(
        jsonEncode({'list': [{'vod_id': '1', 'vod_name': 'Example'}]}), 200));
    final result = await CmsClient(client: transport)
        .searchAcrossSites(config.sites, 'Example').toList();
    expect(config.sites.first.canBrowse, isFalse);
    expect(result.single.$1.key, 'cms');
    expect(result.single.$2.single.title, 'Example');
  });

  test('catalogue matching preserves source ownership and rejects wrong year and private sources', () async {
    final config = CmsParser.parseConfig('{"sites":['
        '{"key":"catalog","name":"Catalog","type":3,"api":"csp_DouDou"},'
        '{"key":"wrong","name":"Wrong year","type":1,"api":"https://wrong.example/api"},'
        '{"key":"match","name":"Match","type":1,"api":"https://match.example/api","header":{"Referer":"https://match.example"}},'
        '{"key":"private","name":"Private","type":1,"api":"https://private.example/api","isPrivate":true}]}');
    final contacted = <String>[];
    final transport = MockClient((request) async {
      final host = request.url.host;
      contacted.add(host);
      return http.Response(jsonEncode({'list': [{
        'vod_id': host, 'vod_name': 'Example',
        'vod_year': host.startsWith('wrong') ? '2020' : '2026',
        if (!host.startsWith('catalog')) ...{
          'vod_play_from': 'Main', 'vod_play_url': r'Film$https://media.example/film.mp4',
        },
      }]}), 200);
    });
    final result = await CmsClient(client: transport).playableDetail(
        config.sites.first, const CmsVideo(id: 'catalog', title: 'Example', year: '2026'), config.sites);
    expect(result.$1.key, 'match');
    expect(result.$1.headers['Referer'], 'https://match.example');
    expect(result.$2.lines.single.episodes.single.url, 'https://media.example/film.mp4');
    expect(contacted, isNot(contains('private.example')));
  });

  test('local ZIP chooses explicit entry and rejects unresolved local assets', () {
    List<int> zip(String name, String raw) {
      final archive = Archive()..addFile(ArchiveFile.string(name, raw));
      return ZipEncoder().encode(archive);
    }
    final raw = CmsClient.readSubscriptionFile(zip('config.json', configText), 'sources.zip');
    expect(CmsParser.parseConfig(raw).sites.length, 3);
    expect(() => CmsClient.readSubscriptionFile(zip('config.json',
        '{"sites":[{"key":"x","name":"X","type":3,"api":"./main.js"}]}'), 'sources.zip'), throwsFormatException);
  });

  test('standalone DRPY rule retains its descriptor for the pinned local engine', () async {
    for (final script in ['var rule = { title: "Demo", host: "https://demo.example" };']) {
      final result = await CmsClient().resolveConfigInput(rawTextInput: script);
      expect(result.rawConfig, script);
      expect(result.config.sites.single.canBrowse, isTrue);
      expect(result.config.sites.single.isDrpySource, isTrue);
    }
  });

  test('disabling every subscription does not revive stale legacy config', () async {
    SharedPreferences.setMockInitialValues({StorageService.keyRawConfig: configText});
    final storage = await StorageService.init();
    await storage.saveSubscriptions([const SubscriptionEntry(id: 'off', name: 'Disabled', rawContent: configText, enabled: false)]);
    expect(storage.loadSavedConfig()!.sites, isEmpty);
  });

  test('site order and individual removal survive reload', () async {
    SharedPreferences.setMockInitialValues({StorageService.keyRawConfig: configText});
    final storage = await StorageService.init();
    final sites = storage.loadSavedConfig()!.sites;
    await storage.savePickerEdits([sites[2], sites[0]], [sites[1]]);
    final reopened = await StorageService.init();
    expect(reopened.loadSavedConfig()!.sites.map((s) => s.key), ['c', 'a']);
  });

  test('multiple subscriptions round trip and private subscription stays local', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    await storage.saveSubscriptions([
      const SubscriptionEntry(id: 'one', name: 'One', rawContent: configText),
      const SubscriptionEntry(id: 'two', name: 'Two', rawContent: configText, enabled: false),
      const SubscriptionEntry(id: 'secret', name: 'PRIVATE-MARKER', rawContent: configText, isPrivate: true),
    ]);
    final backup = storage.exportBackupJson();
    expect(backup.contains('PRIVATE-MARKER'), isFalse);
    SharedPreferences.setMockInitialValues({});
    final restored = await StorageService.init();
    await restored.importBackupJson(backup);
    expect(restored.getSubscriptions().map((s) => s.id), ['one', 'two']);
    expect(restored.getSubscriptions().last.enabled, isFalse);
  });

  test('malformed record never overwrites existing subscriptions or history', () async {
    SharedPreferences.setMockInitialValues({StorageService.keyRawConfig: configText,
      StorageService.keyWatchHistory: '[{"site":"a","id":"old"}]'});
    final storage = await StorageService.init();
    final backup = jsonDecode(storage.exportBackupJson()) as Map<String, dynamic>;
    (backup['settings'] as Map)['watch_history'] = [{'id': 'missing-site'}];
    await expectLater(storage.importBackupJson(jsonEncode(backup)), throwsFormatException);
    expect(storage.rawConfig, configText);
    expect(storage.getWatchHistory().single.id, 'old');
  });

  test('legacy backup preserves ordering, removal and appearance', () async {
    SharedPreferences.setMockInitialValues({StorageService.keyRawConfig: configText,
      StorageService.keyGlassBlurLevel: 'solid', StorageService.keyAmbientGlow: false});
    final storage = await StorageService.init();
    final sites = storage.loadSavedConfig()!.sites;
    await storage.savePickerEdits([sites[2], sites[0]], [sites[1]]);
    final backup = storage.exportBackupJson();
    SharedPreferences.setMockInitialValues({});
    final restored = await StorageService.init();
    await restored.importBackupJson(backup);
    expect(restored.loadSavedConfig()!.sites.map((s) => s.key), ['c', 'a']);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(StorageService.keyGlassBlurLevel), 'solid');
    expect(prefs.getBool(StorageService.keyAmbientGlow), false);
  });

  test('public duplicate source keys survive removal of private subscriptions from backup', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    await storage.saveSubscriptions([
      const SubscriptionEntry(id: 'secret', name: 'Secret', rawContent: configText, isPrivate: true),
      const SubscriptionEntry(id: 'public', name: 'Public', rawContent: configText),
    ]);
    final sites = storage.loadSavedConfig()!.publicSupportedSites;
    await storage.savePickerEdits([sites[2], sites[0]], [sites[1]]);
    final backup = storage.exportBackupJson();
    SharedPreferences.setMockInitialValues({});
    final restored = await StorageService.init();
    await restored.importBackupJson(backup);
    expect(restored.loadSavedConfig()!.sites.map((s) => s.key), ['c_public', 'a_public']);
  });

  test('mixed subscription backup excludes private entries', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    await storage.saveConfig('{"sites":[{"key":"a","name":"A","type":1,"api":"https://a.example/api"},'
      '{"key":"secret","name":"PRIVATE-MARKER","type":1,"api":"https://secret.example/api","isPrivate":true}]}');
    final backup = storage.exportBackupJson();
    expect(backup.contains('PRIVATE-MARKER'), false);
    expect(backup.contains('secret.example'), false);
  });

  test('invalid alias and appearance cannot partially overwrite a restore', () async {
    for (final patch in [
      {'site_key_aliases': {jsonEncode(['private', 'a', 'https://a.example/api']): 'forged'}},
      {StorageService.keyAmbientGlow: 'invalid'},
    ]) {
      SharedPreferences.setMockInitialValues({StorageService.keyRawConfig: configText});
      final storage = await StorageService.init();
      final backup = jsonDecode(storage.exportBackupJson()) as Map<String, dynamic>;
      (backup['settings'] as Map).addAll(patch);
      await expectLater(storage.importBackupJson(jsonEncode(backup)), throwsFormatException);
      expect(storage.rawConfig, configText);
      expect(storage.getSubscriptions(), isEmpty);
    }
  });

  test('a public subscription containing only private entries exports an empty public backup', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    await storage.saveConfig('{"sites":[{"key":"secret","name":"PRIVATE-MARKER","type":1,"api":"https://secret.example/api","isPrivate":true}]}');
    final backup = storage.exportBackupJson();
    expect(backup.contains('PRIVATE-MARKER'), false);
    SharedPreferences.setMockInitialValues({});
    final restored = await StorageService.init();
    await restored.importBackupJson(backup);
    expect(restored.getSubscriptions(), isEmpty);
    expect(restored.loadSavedConfig(), isNull);
  });

}
