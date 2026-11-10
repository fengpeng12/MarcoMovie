import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final size in [const Size(390, 844), const Size(1280, 800)]) {
    testWidgets(
      'home has one history shelf with the newest resumable item at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({});
        final storage = await StorageService.init();
        await storage.saveConfig(
          '{"sites":[{"key":"fixture","name":"测试源","type":1,"api":"https://source.example/api"}]}',
        );
        await storage.upsertWatchHistory(
          const WatchHistoryEntry(
            site: 'fixture',
            id: 'old',
            title: '较早记录',
            episode: '第一集',
            position: 60000,
            duration: 600000,
            updated: 1,
          ),
        );
        await storage.upsertWatchHistory(
          const WatchHistoryEntry(
            site: 'fixture',
            id: 'new',
            title: '最新记录',
            line: '测试线路',
            episode: '第二集',
            position: 120000,
            duration: 600000,
            updated: 2,
          ),
        );
        final detailRequests = <String>[];
        final client = CmsClient(
          client: MockClient((request) async {
            final id = request.url.queryParameters['ids'];
            if (id != null) {
              detailRequests.add(id);
              return http.Response(
                jsonEncode({
                  'list': [
                    {
                      'vod_id': id,
                      'vod_name': '最新记录',
                      'vod_play_from': '测试线路',
                      'vod_play_url': '第二集\$https://source.example/video.mp4',
                    },
                  ],
                }),
                200,
                headers: {'content-type': 'application/json; charset=utf-8'},
              );
            }
            return http.Response('{"class":[],"list":[]}', 200);
          }),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: AdaptiveShell(storage: storage, client: client),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.text('历史记录'), findsOneWidget);
        expect(find.text('继续观看'), findsNothing);
        expect(find.text('继续播放'), findsNothing);
        expect(find.text('最新记录'), findsOneWidget);
        expect(find.text('较早记录'), findsOneWidget);
        expect(
          tester.getRect(find.text('最新记录')).left,
          lessThan(tester.getRect(find.text('较早记录')).left),
        );
        expect(storage.getWatchHistory().first.id, 'new');
        expect(storage.getWatchHistory().first.resumePosition, 120000);
        await tester.tap(find.text('最新记录'));
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();
        expect(detailRequests, contains('new'));
        expect(storage.getWatchHistory().first.resumePosition, 120000);
        expect(find.textContaining('续播'), findsWidgets);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('history shelf honors the existing preference key', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'show_continue_watching': false});
    final storage = await StorageService.init();
    await storage.saveConfig(
      '{"sites":[{"key":"fixture","name":"测试源","type":1,"api":"https://source.example/api"}]}',
    );
    await storage.upsertWatchHistory(
      const WatchHistoryEntry(
        site: 'fixture',
        id: 'new',
        title: '最新记录',
        position: 120000,
      ),
    );
    final client = CmsClient(
      client: MockClient(
        (_) async => http.Response('{"class":[],"list":[]}', 200),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: AdaptiveShell(storage: storage, client: client),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(storage.showContinueWatching, false);
    expect(find.text('最新记录'), findsNothing);
    expect(find.text('历史记录'), findsNothing);
    expect(storage.getWatchHistory().single.resumePosition, 120000);
    await tester.pumpWidget(const SizedBox());
  });
}
