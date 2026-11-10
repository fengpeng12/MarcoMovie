import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SourceFilterClient extends CmsClient {
  final List<(int, String)> requests = [];

  @override
  Future<(List<CmsCategory>, CmsListing)> fetchHome(CmsSite site) async =>
      (const [CmsCategory(id: 'Movie', name: '电影')], const CmsListing());

  @override
  Future<CmsListing> fetchCategory(
    CmsSite site,
    String categoryId,
    int page, {
    List<String> childIds = const [],
    CmsFilter? filter,
  }) async {
    requests.add((page, filter?.genreLabel ?? ''));
    if (filter?.genreLabel == '喜剧') {
      return const CmsListing(page: 1, pageCount: 20, sourceFiltered: true);
    }
    if (filter?.genreLabel != '动作') return const CmsListing();
    return const CmsListing(
      page: 1,
      pageCount: 20,
      sourceFiltered: true,
      videos: [CmsVideo(id: 'one', title: '源端筛选得到的影片')],
    );
  }
}

void main() {
  testWidgets(
    'home retains source-filtered cards without metadata or page probing',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init();
      await storage.saveConfig(
        '{"sites":[{"key":"fixture","name":"测试源","type":1,"api":"https://fixture.invalid/api"}]}',
      );
      final client = SourceFilterClient();
      await tester.pumpWidget(
        MaterialApp(
          home: AdaptiveShell(storage: storage, client: client),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('电影').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('home-filter-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('动作').first);
      await tester.pumpAndSettle();
      expect(client.requests, contains((1, '动作')));
      expect(client.requests.where((request) => request.$1 == 2), isEmpty);
      expect(find.text('源端筛选得到的影片'), findsWidgets);
      expect(find.textContaining('当前筛选条件下暂无影片'), findsNothing);
      expect(tester.takeException(), isNull);
      client.requests.clear();
      expect(find.text('喜剧').first.hitTestable(), findsOneWidget);
      await tester.tap(find.text('喜剧').first);
      await tester.pumpAndSettle();
      expect(client.requests, [(1, '喜剧')]);
      expect(find.text('源端筛选得到的影片'), findsNothing);
      expect(find.textContaining('当前筛选条件下暂无影片'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
