import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/cms_parser.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final docs = <String, Object>{
    '/root.json': {
      'storeHouse': [
        {'sourceName': '优选', 'sourceUrl': './a.txt'},
        {'sourceName': '聚合', 'sourceUrl': './b.txt'},
        {'sourceName': '更新日期', 'sourceUrl': '更新时间'},
      ],
    },
    '/a.txt': {
      'urls': [
        {'name': '坏地址', 'url': './missing.json'},
        {'name': '主仓', 'url': './leaf/one.json'},
      ],
    },
    '/b.txt': {
      'urls': [
        {'name': '副仓', 'url': './leaf/two.json'},
      ],
    },
    '/leaf/one.json': {
      'sites': [
        {'key': 'one', 'name': '一', 'type': 1, 'api': './api.php'},
      ],
    },
    '/leaf/two.json': {
      'sites': [
        {'key': 'two', 'name': '二', 'type': 1, 'api': './other.php'},
      ],
    },
    '/cycle.json': {
      'urls': [
        {'name': '自己', 'url': './cycle.json'},
      ],
    },
  };
  late CmsClient client;
  late List<String> requested;
  setUp(() {
    requested = [];
    client = CmsClient(
      client: MockClient((r) async {
        requested.add(r.url.path);
        return http.Response(
          jsonEncode(docs[r.url.path] ?? {'error': 'missing'}),
          docs.containsKey(r.url.path) ? 200 : 404,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    SharedPreferences.setMockInitialValues({});
  });

  test('nested storeHouse, failed sibling and leaf-relative paths', () async {
    final sub = (await client.resolveBatchSubscriptions(
      urlInput: 'https://warehouse.example/root.json',
    )).single;
    expect(sub.warehouseUrl, 'https://warehouse.example/root.json');
    expect(sub.url, 'https://warehouse.example/leaf/one.json');
    expect(sub.activeDepotName, '优选 / 主仓');
    expect(sub.depots.length, 4);
    expect(requested, isNot(contains('/更新时间')));
    expect(
      CmsParser.parseConfig(sub.rawContent, origin: sub.url).sites.single.api,
      'https://warehouse.example/leaf/api.php',
    );
  });

  test(
    'switch replaces only its subscription and keeps directory after restart and backup',
    () async {
      final store = await StorageService.init();
      final sub = (await client.resolveBatchSubscriptions(
        urlInput: 'https://warehouse.example/root.json',
      )).single;
      await store.upsertSubscriptions([
        sub,
        const SubscriptionEntry(
          id: 'other',
          name: '独立',
          rawContent:
              '{"sites":[{"key":"other","name":"独立","type":1,"api":"https://other.example/api"}]}',
        ),
      ]);
      final updated = await client.switchSubscriptionDepot(sub, sub.depots[1]);
      await store.upsertSubscriptions([updated]);
      expect(store.getSubscriptions().length, 2);
      expect(
        store.loadSavedConfig()!.sites.map((s) => s.key),
        containsAll(['two', 'other']),
      );
      expect(store.loadSavedConfig()!.sites.any((s) => s.key == 'one'), false);
      final fresh = await StorageService.init();
      expect(fresh.loadSavedConfig()!.depots.length, 5);
      final backup = fresh.exportBackupJson();
      SharedPreferences.setMockInitialValues({});
      final restored = await StorageService.init();
      await restored.importBackupJson(backup);
      expect(restored.getSubscriptions().first.warehouseUrl, sub.warehouseUrl);
      expect(restored.loadSavedConfig()!.depots.length, 5);
    },
  );

  test(
    'failed switch preserves previous source and private directory is not exported',
    () async {
      final store = await StorageService.init();
      final sub = (await client.resolveBatchSubscriptions(
        urlInput: 'https://warehouse.example/root.json',
        isPrivate: true,
      )).single;
      await store.upsertSubscriptions([sub]);
      await expectLater(
        client.switchSubscriptionDepot(
          sub,
          const CmsDepot(
            name: 'bad',
            url: 'https://warehouse.example/missing.json',
          ),
        ),
        throwsException,
      );
      expect(store.getSubscriptions().single.url, sub.url);
      expect(store.loadSavedConfig()!.depots, isEmpty);
      expect(store.exportBackupJson(), isNot(contains('warehouse.example')));
    },
  );

  test('cycles stop without repeatedly requesting the same catalog', () async {
    await expectLater(
      client.resolveConfigInput(
        urlInput: 'https://warehouse.example/cycle.json',
      ),
      throwsFormatException,
    );
    expect(requested.where((p) => p == '/cycle.json').length, 1);
  });
  test('legacy directory is owned by its subscription and disappears when disabled', () async {
    final store = await StorageService.init();
    await store.saveConfig('{"sites":[{"key":"one","name":"One","type":1,"api":"https://source.example/api"}]}',
      origin: 'https://warehouse.example/leaf/one.json',
      depots: [const CmsDepot(name: '旧仓库', url: 'https://warehouse.example/a.txt')]);
    final owner = store.getSubscriptions().single;
    expect(store.loadSavedConfig()!.depots.single.subscriptionId, owner.id);
    await store.toggleSubscriptionEnabled(owner.id, false);
    expect(store.loadSavedConfig()!.depots, isEmpty);
  });

}
