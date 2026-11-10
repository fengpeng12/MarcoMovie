import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'source defaults persist, prioritize matching, and survive backup without exposing private sources',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = await StorageService.init();
      await store.saveConfig(
        '{"sites":['
        '{"key":"a","name":"A","type":1,"api":"https://a.example/api"},'
        '{"key":"b","name":"B","type":1,"api":"https://b.example/api"},'
        '{"key":"private","name":"Private","type":1,"api":"https://private.example/api","isPrivate":true}]}',
      );
      await store.setPreferredSiteKey('b');
      await store.setSelectedSiteKey('a');
      expect(store.preferredSiteKey, 'b');
      expect(
        store
            .prioritizeSites(store.loadSavedConfig()!.publicSupportedSites)
            .first
            .key,
        'b',
      );
      await expectLater(
        store.setPreferredSiteKey('private'),
        throwsFormatException,
      );
      final restarted = await StorageService.init();
      expect(restarted.preferredSiteKey, 'b');
      final backup = restarted.exportBackupJson();
      SharedPreferences.setMockInitialValues({});
      final restored = await StorageService.init();
      await restored.importBackupJson(backup);
      expect(restored.preferredSiteKey, 'b');
      await restored.setPreferredSiteKey('');
      expect(restored.preferredSiteKey, '');
    },
  );

  test('preferred playback line falls back when missing or empty', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await StorageService.init();
    final lines = [
      const CmsLine(
        name: '普通',
        episodes: [CmsEpisode(name: '一', url: 'https://media.example/a.mp4')],
      ),
      const CmsLine(
        name: '偏好',
        episodes: [CmsEpisode(name: '一', url: 'https://media.example/b.mp4')],
      ),
    ];
    await store.setPreferredLineName('偏好');
    expect(store.pickRecommendedLineIndex(lines), 1);
    expect(store.pickRecommendedLineIndex(lines.take(1).toList()), 0);
    expect(
      store.pickRecommendedLineIndex([
        lines.first,
        const CmsLine(name: '偏好', episodes: []),
      ]),
      0,
    );
  });
}
