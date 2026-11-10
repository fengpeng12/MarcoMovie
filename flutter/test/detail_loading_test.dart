import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/detail_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DetailLoadingClient extends CmsClient {
  final detail = Completer<(CmsSite, CmsVideo)>();
  int searches = 0;
  @override
  Future<(CmsSite, CmsVideo)> playableDetail(
    CmsSite source,
    CmsVideo item,
    Iterable<CmsSite> candidates,
  ) => detail.future;
  @override
  Future<CmsListing> fetchSearch(
    CmsSite site,
    String keyword, {
    int page = 1,
  }) async {
    searches++;
    return const CmsListing();
  }
}

void main() {
  const site = CmsSite(
    key: 'owned',
    name: 'Owned',
    type: 1,
    api: 'https://owned.invalid/api',
  );
  const video = CmsVideo(
    id: 'one',
    title: 'Fixture 第一季',
    lines: [
      CmsLine(
        name: 'Owned',
        episodes: [CmsEpisode(name: '第一集', url: 'https://owned.invalid/a.mp4')],
      ),
    ],
  );

  testWidgets('episode loading takes priority over related-season discovery', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    final client = DetailLoadingClient();
    await tester.pumpWidget(
      MaterialApp(
        home: DetailScreen(
          site: site,
          initialVideo: video,
          client: client,
          storage: storage,
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(client.searches, 0);
    await tester.runAsync(() async {
      client.detail.complete((site, video));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 299));
    expect(client.searches, 0);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(client.searches, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  });

  testWidgets(
    'leaving details suppresses delayed season searches and late detail results',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init();
      final client = DetailLoadingClient();
      await tester.pumpWidget(
        MaterialApp(
          home: DetailScreen(
            site: site,
            initialVideo: video,
            client: client,
            storage: storage,
          ),
        ),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        client.detail.complete((site, video));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump(const Duration(seconds: 1));
      expect(client.searches, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
