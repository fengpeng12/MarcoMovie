import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

class HomeLoadingClient extends CmsClient {
  final home = Completer<(List<CmsCategory>, CmsListing)>();
  final pageTwo = Completer<CmsListing>();
  final live = Completer<List<LiveGroup>>();
  final tokens = <Completer<void>>[];
  bool probe = false;
  int secondPageCalls = 0;
  @override
  Future<T> runSourceOperation<T>(
    Future<T> Function() operation, {
    required Completer<void> cancellation,
  }) {
    tokens.add(cancellation);
    return super.runSourceOperation(operation, cancellation: cancellation);
  }

  @override
  Future<(List<CmsCategory>, CmsListing)> fetchHome(CmsSite site) =>
      home.future;
  @override
  Future<List<LiveGroup>> fetchLiveGroups(LiveSource source) => live.future;
  @override
  Future<CmsListing> fetchCategory(
    CmsSite site,
    String categoryId,
    int page, {
    List<String> childIds = const [],
    CmsFilter? filter,
  }) async {
    if (probe && filter?.hasSubFilter == true) {
      if (page == 2) {
        secondPageCalls++;
        return pageTwo.future;
      }
      return const CmsListing(pageCount: 2);
    }
    return const CmsListing(
      videos: [CmsVideo(id: 'new', title: '当前分类影片')],
      sourceFiltered: true,
    );
  }
}

Future<void> flush(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
}

Future<void> mount(WidgetTester tester, HomeLoadingClient client) async {
  tester.view.physicalSize = const Size(390, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final storage = await StorageService.init();
  await storage.saveConfig(
    '''{"sites":[{"key":"owned","name":"Owned","type":1,"api":"https://owned.invalid/api"}],"lives":[{"name":"Owned live","url":"https://owned.invalid/live.m3u"}]}''',
  );
  await tester.pumpWidget(
    MaterialApp(
      home: AdaptiveShell(storage: storage, client: client),
    ),
  );
  await flush(tester);
}

Future<void> unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await flush(tester);
}

void main() {
  testWidgets('a late initial home cannot replace a selected category', (
    tester,
  ) async {
    final client = HomeLoadingClient();
    await mount(tester, client);
    final initial = client.tokens.first;
    await tester.tap(find.text('电影').first);
    await flush(tester);
    expect(initial.isCompleted, true);
    expect(find.text('当前分类影片'), findsWidgets);
    client.home.complete((
      const [CmsCategory(id: 'old', name: '旧分类')],
      const CmsListing(
        videos: [CmsVideo(id: 'old', title: '过期首页影片')],
      ),
    ));
    await flush(tester);
    expect(find.text('过期首页影片'), findsNothing);
    expect(find.text('当前分类影片'), findsWidgets);
    await unmount(tester);
  });

  testWidgets('changing a filter revokes its in-flight page-two probe', (
    tester,
  ) async {
    final client = HomeLoadingClient()..probe = true;
    client.home.complete((
      const [CmsCategory(id: 'film', name: '电影')],
      const CmsListing(),
    ));
    await mount(tester, client);
    await tester.tap(find.text('电影').first);
    await flush(tester);
    await tester.tap(find.byKey(const ValueKey('home-filter-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.ensureVisible(find.text('动作').first);
    await tester.tap(find.text('动作').first);
    await flush(tester);
    expect(client.secondPageCalls, 1);
    final oldProbe = client.tokens.last;
    await tester.tap(find.text('重置筛选'));
    await flush(tester);
    expect(oldProbe.isCompleted, true);
    client.pageTwo.complete(
      const CmsListing(
        videos: [CmsVideo(id: 'stale', title: '过期筛选影片')],
        sourceFiltered: true,
      ),
    );
    await flush(tester);
    expect(find.text('过期筛选影片'), findsNothing);
    expect(find.text('当前分类影片'), findsWidgets);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('disposing the home cancels both catalogue and live loads', (
    tester,
  ) async {
    final client = HomeLoadingClient();
    await mount(tester, client);
    expect(client.tokens.length, 2);
    await unmount(tester);
    expect(client.tokens.every((token) => token.isCompleted), true);
    client.home.complete((const <CmsCategory>[], const CmsListing()));
    client.live.complete(const []);
    await flush(tester);
    expect(tester.takeException(), isNull);
  });
}
