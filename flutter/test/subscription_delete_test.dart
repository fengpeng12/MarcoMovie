import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';

const raw = '{"sites":[{"key":"same","name":"Cinema","type":1,"api":"https://catalog.example/api"}]}';

class FailingStore extends InMemorySharedPreferencesStore {
  FailingStore() : super.empty();
  bool fail = false;
  String failureKey = StorageService.keySubscriptions;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (fail && key.endsWith(failureKey)) return false;
    return super.setValue(type, key, value);
  }
}

Future<StorageService> restart() async {
  final prefs = await SharedPreferences.getInstance();
  final saved = {for (final key in prefs.getKeys()) key: prefs.get(key)!};
  SharedPreferences.setMockInitialValues(saved);
  return StorageService.init();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('first pasted import has one owner and deletion survives restart and a new import', () async {
    var store = await StorageService.init();
    await store.saveConfig(raw);
    expect(store.getSubscriptions(), hasLength(1));
    await store.removeSubscription(store.getSubscriptions().single.id);
    store = await restart();
    expect(store.getSubscriptions(), isEmpty);
    expect(store.loadSavedConfig(), isNull);
    await store.saveConfig(raw.replaceAll('Cinema', 'New import'), origin: 'https://new.example/config');
    expect(store.getSubscriptions(), hasLength(1));
    expect(store.loadSavedConfig()!.sites.single.name, 'New import');
  });

  test('empty authoritative registry cannot revive legacy payload during load, backup or import', () async {
    SharedPreferences.setMockInitialValues({StorageService.keyRawConfig: raw,
      StorageService.keyOrigin: 'https://old.example/config', StorageService.keySubscriptions: '[]'});
    var store = await StorageService.init();
    expect(store.loadSavedConfig(), isNull);
    expect(store.exportBackupJson().contains('catalog.example'), false);
    await store.upsertSubscriptions([const SubscriptionEntry(id: 'new', name: 'New', rawContent: raw)]);
    store = await restart();
    expect(store.getSubscriptions().map((s) => s.id), ['new']);
  });

  for (final deleted in ['legacy_primary', 'sub_primary']) {
    test('deleting $deleted removes only the historical pasted-import twin', () async {
      var store = await StorageService.init();
      await store.saveSubscriptions([
        const SubscriptionEntry(id: 'legacy_primary', name: 'Legacy', rawContent: raw),
        const SubscriptionEntry(id: 'sub_primary', name: 'Paste', rawContent: raw),
        const SubscriptionEntry(id: 'independent', name: 'Deliberate copy', rawContent: raw, group: 'Other'),
      ]);
      await store.removeSubscription(deleted);
      store = await restart();
      expect(store.getSubscriptions().map((s) => s.id), ['independent']);
      expect(store.loadSavedConfig()!.sites, hasLength(1));
    });
  }

  test('deleted duplicate-key line stays deleted after removing another subscription and backup', () async {
    var store = await StorageService.init();
    await store.saveSubscriptions([
      const SubscriptionEntry(id: 'one', name: 'One', rawContent: raw),
      const SubscriptionEntry(id: 'two', name: 'Two', rawContent: raw),
    ]);
    final sites = store.loadSavedConfig()!.sites;
    expect(sites.last.key, 'same_two');
    await store.savePickerEdits([sites.first], [sites.last]);
    await store.removeSubscription('one');
    store = await restart();
    expect(store.loadSavedConfig()!.sites, isEmpty);
    final backup = store.exportBackupJson();
    SharedPreferences.setMockInitialValues({});
    store = await StorageService.init();
    await store.importBackupJson(backup);
    expect(store.loadSavedConfig()!.sites, isEmpty);
  });

  test('old alias-based removal remains effective after alias is no longer needed', () async {
    var store = await StorageService.init();
    await store.saveSubscriptions([const SubscriptionEntry(id: 'two', name: 'Two', rawContent: raw)]);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('picker_removed_sites', [jsonEncode(['two', 'same_two', 'https://catalog.example/api'])]);
    store = await restart();
    expect(store.loadSavedConfig()!.sites, isEmpty);
  });

  test('first private import does not create a public legacy copy', () async {
    var store = await StorageService.init();
    await store.saveConfig(raw, isPrivate: true);
    store = await restart();
    expect(store.getSubscriptions(), hasLength(1));
    expect(store.loadSavedConfig()!.publicSupportedSites, isEmpty);
    expect(store.exportBackupJson().contains('catalog.example'), false);
  });

  test('deleting another subscription preserves legacy warehouse directories with their owner', () async {
    var store = await StorageService.init();
    await store.saveSubscriptions([
      const SubscriptionEntry(id: 'warehouse', name: 'Warehouse', format: '多仓',
        url: 'https://warehouse.example/leaf', rawContent: raw),
      const SubscriptionEntry(id: 'other', name: 'Other', rawContent: raw),
    ]);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(StorageService.keyOrigin, 'https://warehouse.example/leaf');
    await prefs.setString(StorageService.keyDepots, jsonEncode([
      const CmsDepot(name: 'Another leaf', url: 'https://warehouse.example/next').toJson(),
    ]));
    await store.removeSubscription('other');
    store = await restart();
    expect(store.loadSavedConfig()!.depots.single.subscriptionId, 'warehouse');
    expect(store.loadSavedConfig()!.depots.single.url, 'https://warehouse.example/next');
    await store.removeSubscription('warehouse');
    store = await restart();
    expect(store.loadSavedConfig(), isNull);
    expect(store.getSavedDepots(), isEmpty);
  });

  test('rapid deletion and a queued rename cannot restore either deleted owner', () async {
    var store = await StorageService.init();
    await store.saveSubscriptions([
      const SubscriptionEntry(id: 'one', name: 'One', rawContent: raw),
      const SubscriptionEntry(id: 'two', name: 'Two', rawContent: raw),
    ]);
    await Future.wait([
      store.removeSubscription('one'),
      store.updateSubscriptionGroup('one', 'Renamed'),
      store.removeSubscription('two'),
    ]);
    store = await restart();
    expect(store.getSubscriptions(), isEmpty);
    expect(store.loadSavedConfig(), isNull);
  });

  test('failed registry write keeps the old state and allows retry', () async {
    final platform = FailingStore();
    SharedPreferencesStorePlatform.instance = platform;
    final store = await StorageService.init();
    await store.saveConfig(raw);
    final id = store.getSubscriptions().single.id;
    platform.fail = true;
    await expectLater(store.removeSubscription(id), throwsStateError);
    expect(store.getSubscriptions().single.id, id);
    expect(store.loadSavedConfig()!.sites, hasLength(1));
    platform.fail = false;
    await store.removeSubscription(id);
    expect(store.getSubscriptions(), isEmpty);
  });

  test('warehouse directories stay with each import and private directories never enter public backup', () async {
    var store = await StorageService.init();
    await store.saveConfig(raw, origin: 'https://one.example/config', depots: const [
      CmsDepot(name: 'One', url: 'https://one.example/leaf'),
    ]);
    final first = store.getSubscriptions().single.id;
    await store.saveConfig(raw, origin: 'https://two.example/config', depots: const [
      CmsDepot(name: 'Two', url: 'https://two.example/leaf'),
    ]);
    await store.saveConfig(raw, origin: 'https://private.example/config', isPrivate: true,
      depots: const [CmsDepot(name: 'Private', url: 'https://private.example/leaf')]);
    expect(store.loadSavedConfig()!.depots.map((d) => d.url).toSet(), {
      'https://one.example/leaf', 'https://two.example/leaf',
    });
    expect(store.exportBackupJson().contains('private.example'), false);
    await store.removeSubscription(first);
    store = await restart();
    expect(store.loadSavedConfig()!.depots.single.url, 'https://two.example/leaf');
  });

  test('failed individual line deletion is reported and leaves the line available for retry', () async {
    final platform = FailingStore();
    SharedPreferencesStorePlatform.instance = platform;
    final store = await StorageService.init();
    await store.saveConfig(raw);
    final site = store.loadSavedConfig()!.sites.single;
    platform.failureKey = 'picker_removed_sites';
    platform.fail = true;
    await expectLater(store.savePickerEdits([], [site]), throwsStateError);
    expect(store.loadSavedConfig()!.sites, hasLength(1));
    platform.fail = false;
    await store.savePickerEdits([], [site]);
    expect((await restart()).loadSavedConfig()!.sites, isEmpty);
  });
}
