import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:marco_movie/core/cms_parser.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';

const _digestA = '0123456789abcdef0123456789abcdef';
const _digestB = 'ABCDEF0123456789ABCDEF0123456789';

Map<String, Object> _site(String key, {String? jar, bool hidden = false}) => {
  'key': key,
  'name': key,
  'type': 3,
  'api': 'csp_Guard',
  if (jar != null) 'jar': jar,
  if (hidden) 'hidden': true,
};

Future<StorageService> _restart() async {
  final prefs = await SharedPreferences.getInstance();
  final saved = {for (final key in prefs.getKeys()) key: prefs.get(key)!};
  SharedPreferences.setMockInitialValues(saved);
  return StorageService.init();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'relative defaults and overrides retain their own exact digest suffix',
    () {
      final config = CmsParser.parseConfig(
        jsonEncode({
          'spider': '../plugins/base.jar?version=2;md5;$_digestA',
          'sites': [
            _site('default'),
            _site('override', jar: './custom.jar;MD5;$_digestB'),
          ],
        }),
        origin: 'https://config.example/feeds/list.json',
      );
      expect(
        config.spider,
        'https://config.example/plugins/base.jar?version=2;md5;$_digestA',
      );
      expect(config.sites.first.jar, isEmpty);
      expect(config.sites.first.spider, config.spider);
      expect(config.sites.first.pluginReference, config.spider);
      expect(config.sites.last.spider, config.spider);
      expect(
        config.sites.last.pluginReference,
        'https://config.example/feeds/custom.jar;MD5;$_digestB',
      );
      final copied = config.sites.last.copyWith(key: 'alias', group: 'Other');
      expect(copied.jar, config.sites.last.jar);
      expect(copied.spider, config.spider);
      expect(copied.copyWith(jar: '').pluginReference, config.spider);
    },
  );

  test(
    'invalid explicit digest remains an override instead of using a default',
    () {
      const suffix =
          ';md5;not-a-valid-digest '; // Kept for strict loader rejection.
      final site = CmsParser.parseConfig(
        jsonEncode({
          'spider': './fallback.jar;md5;$_digestA',
          'sites': [_site('bad', jar: './override.jar$suffix')],
        }),
        origin: 'https://config.example/list.json',
      ).sites.single;
      expect(
        site.pluginReference,
        'https://config.example/override.jar$suffix',
      );
      expect(
        CmsParser.normalizeJarDeclaration(
          'https://config.example/list.json',
          ';md5;',
        ),
        ';md5;',
      );
    },
  );

  test('single-site and local package origins retain plugin references', () {
    final parsed = CmsParser.parseConfig(
      jsonEncode({
        ..._site('single'),
        'spider': '../plugins/base.jar;md5;$_digestA',
      }),
      origin: 'pkg://archive/config/main.json',
    );
    expect(parsed.spider, 'pkg://archive/plugins/base.jar;md5;$_digestA');
    expect(parsed.sites.single.pluginReference, parsed.spider);
    expect(
      CmsParser.normalizeJarDeclaration('', 'local.jar;md5;$_digestB'),
      'local.jar;md5;$_digestB',
    );
  });

  test(
    'two subscriptions retain distinct plugins through merge, reorder, restart and backup',
    () async {
      var storage = await StorageService.init();
      await storage.saveSubscriptions([
        SubscriptionEntry(
          id: 'one',
          name: 'One',
          url: 'https://one.example/config/list.json',
          rawContent: jsonEncode({
            'spider': '../one.jar;md5;$_digestA',
            'sites': [
              _site('same'),
              _site('override', jar: 'custom.jar;md5;$_digestB'),
            ],
          }),
        ),
        SubscriptionEntry(
          id: 'two',
          name: 'Two',
          url: 'https://two.example/list.json',
          rawContent: jsonEncode({
            'spider': 'two.jar;md5;$_digestB',
            'sites': [_site('same')],
          }),
        ),
      ]);
      final original = storage.loadSavedConfig()!.sites;
      expect(original.map((s) => s.pluginReference), [
        'https://one.example/one.jar;md5;$_digestA',
        'https://one.example/config/custom.jar;md5;$_digestB',
        'https://two.example/two.jar;md5;$_digestB',
      ]);
      final reordered = original.reversed.toList();
      await storage.savePickerEdits(reordered, []);
      storage = await _restart();
      expect(
        storage.loadSavedConfig()!.sites.map((s) => s.pluginReference),
        reordered.map((s) => s.pluginReference),
      );
      final backup = storage.exportBackupJson();
      SharedPreferences.setMockInitialValues({});
      storage = await StorageService.init();
      await storage.importBackupJson(backup);
      final restored = storage.loadSavedConfig()!.sites;
      expect(restored.map((s) => s.key), reordered.map((s) => s.key));
      expect(restored.map((s) => s.jar), reordered.map((s) => s.jar));
      expect(restored.map((s) => s.spider), reordered.map((s) => s.spider));
      expect(
        restored.map((s) => s.pluginReference),
        reordered.map((s) => s.pluginReference),
      );
    },
  );

  test(
    'privacy-filtered root-list fallback backup keeps each public plugin',
    () async {
      var storage = await StorageService.init();
      await storage.saveSubscriptions([
        SubscriptionEntry(
          id: 'list',
          name: 'List',
          url: 'https://list.example/feeds/list.json',
          rawContent: jsonEncode([
            _site('visible', jar: '../public.jar;md5;$_digestA'),
            _site('secret', jar: '../private.jar;md5;$_digestB', hidden: true),
          ]),
        ),
      ]);
      final backup = storage.exportBackupJson();
      expect(backup, isNot(contains('private.jar')));
      SharedPreferences.setMockInitialValues({});
      storage = await StorageService.init();
      await storage.importBackupJson(backup);
      expect(
        storage.loadSavedConfig()!.sites.single.pluginReference,
        'https://list.example/public.jar;md5;$_digestA',
      );
    },
  );
}
