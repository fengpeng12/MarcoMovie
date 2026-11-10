import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';

class DelayedCatalogue extends CmsClient {
  final home = Completer<(List<CmsCategory>, CmsListing)>();
  final live = Completer<List<LiveGroup>>();
  @override
  Future<(List<CmsCategory>, CmsListing)> fetchHome(CmsSite site) => home.future;
  @override
  Future<List<LiveGroup>> fetchLiveGroups(LiveSource source) => live.future;
}

void main() {
  testWidgets('deleting the last subscription updates UI and rejects late catalogue/live responses', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    await storage.saveConfig('{"sites":[{"key":"one","name":"Pending source","type":1,"api":"https://catalog.example/api"}],'
        '"lives":[{"name":"Pending live","url":"https://catalog.example/live.txt"}]}');
    final client = DelayedCatalogue();
    await tester.pumpWidget(MaterialApp(home: AdaptiveShell(storage: storage, client: client)));
    await tester.pump();
    await tester.tap(find.text('设置').last);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.ensureVisible(find.text('订阅与数据维护'));
    await tester.tap(find.text('订阅与数据维护'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.ensureVisible(find.text('订阅源与分组管理中心'));
    await tester.tap(find.text('订阅源与分组管理中心'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final delete = find.byIcon(CupertinoIcons.trash);
    expect(delete, findsOneWidget);
    await tester.tap(delete);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(storage.getSubscriptions(), isEmpty);
    expect(find.text('暂未添加多订阅分组'), findsOneWidget);
    client.home.complete((const <CmsCategory>[], const CmsListing(videos: [CmsVideo(id: 'old', title: 'Deleted film')])));
    client.live.complete(const [LiveGroup(name: 'Deleted live group', channels: [
      LiveChannel(name: 'Deleted channel', group: 'Deleted live group', urls: ['https://stream.example/old.m3u8']),
    ])]);
    await tester.pump(const Duration(milliseconds: 100));
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('0 订阅'), findsOneWidget);
    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('直播').last);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Deleted channel'), findsNothing);
    expect(find.text('Deleted live group'), findsNothing);
    await tester.tap(find.text('主页').last);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Deleted film'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
