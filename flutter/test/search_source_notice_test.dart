import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:marco_movie/core/catpaw_host.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/search_source_notice.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';

class NoticeClient extends CmsClient {
  final Completer<CmsListing>? pending;
  final keywords = <String>[];
  NoticeClient({this.pending});
  @override
  Future<(List<CmsCategory>, CmsListing)> fetchHome(CmsSite site) async =>
      (<CmsCategory>[], const CmsListing());
  @override
  Future<CmsListing> fetchSearch(
    CmsSite site,
    String keyword, {
    int page = 1,
  }) async {
    keywords.add(keyword);
    if (pending != null) return pending!.future;
    if (keyword == '正常') return const CmsListing();
    if (site.key.startsWith('verification')) {
      throw const DrpySourceException(
        'drpy_verification_required',
        'Untrusted response text must not appear',
      );
    }
    if (site.key == 'broken')
      throw StateError('private credentials must not appear');
    return const CmsListing(
      videos: [CmsVideo(id: 'one', title: '正常结果')],
    );
  }
}

const sources = [
  CmsSite(
    key: 'verification',
    name: '验证片源',
    type: 1,
    api: 'https://verification.invalid/api',
  ),
  CmsSite(
    key: 'broken',
    name: '故障片源',
    type: 1,
    api: 'https://broken.invalid/api',
  ),
  CmsSite(
    key: 'healthy',
    name: '正常片源',
    type: 1,
    api: 'https://healthy.invalid/api',
  ),
];

void main() {
  test(
    'source failures are reported independently while healthy results survive',
    () async {
      final errors = <String, Object>{};
      final results = await NoticeClient()
          .searchAcrossSites(
            sources,
            '影片',
            onSourceError: (site, error) => errors[site.key] = error,
          )
          .toList();
      expect(results.single.$1.key, 'healthy');
      expect(errors.keys, containsAll(['verification', 'broken']));
      expect(searchSourceNotice(errors['verification']!), contains('验证码'));
      expect(
        searchSourceNotice(errors['broken']!),
        isNot(contains('credentials')),
      );
      expect(
        searchSourceNotice(TimeoutException('private address')),
        contains('超时'),
      );
    },
  );

  test(
    'completed searches can be repeated without old source failures',
    () async {
      final client = NoticeClient();
      final firstErrors = <Object>[];
      final first = client.searchAcrossSites(
        [sources.first],
        '影片',
        onSourceError: (_, error) => firstErrors.add(error),
      );
      await first.toList();
      expect(firstErrors.single, isA<DrpySourceException>());
      final nextErrors = <Object>[];
      final second = client.searchAcrossSites(
        [sources.first],
        '正常',
        onSourceError: (_, error) => nextErrors.add(error),
      );
      expect(await second.toList(), isEmpty);
      expect(nextErrors, isEmpty);
      expect(client.keywords, ['影片', '正常']);
    },
  );

  test('cancelled searches cannot emit stale failure notices', () async {
    final pending = Completer<CmsListing>();
    var notices = 0;
    final subscription = NoticeClient(pending: pending)
        .searchAcrossSites(
          [sources.first],
          '影片',
          onSourceError: (_, __) => notices++,
        )
        .listen((_) {});
    await subscription.cancel();
    pending.completeError(
      const DrpySourceException('drpy_verification_required', 'verification'),
    );
    await Future<void>.delayed(Duration.zero);
    expect(notices, 0);
  });

  testWidgets(
    'search distinguishes website verification from no matches and resets notices',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init();
      final client = NoticeClient();
      await storage.saveConfig(
        '{"sites":[{"key":"verification","name":"验证片源","type":1,"api":"https://verification.invalid/api"}]}',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: AdaptiveShell(storage: storage, client: client),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey('home-search-button')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(CupertinoTextField).last, '影片');
      await tester.pumpAndSettle();
      expect(find.text('搜索').last.hitTestable(), findsOneWidget);
      await tester.tap(find.text('搜索').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('验证片源：需要完成网站验证码'), findsOneWidget);
      expect(find.text('本次搜索未返回影片，请查看上方片源提示'), findsOneWidget);
      expect(find.textContaining('Untrusted response'), findsNothing);
      await tester.enterText(find.byType(CupertinoTextField).last, '正常');
      await tester.pumpAndSettle();
      expect(find.text('搜索').last.hitTestable(), findsOneWidget);
      await tester.tap(find.text('搜索').last);
      await tester.pumpAndSettle();
      expect(client.keywords, ['影片', '正常']);
      expect(find.byKey(const ValueKey('search-source-notices')), findsNothing);
      expect(find.text('没有找到匹配影片'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'landscape search keeps multiple long source notices scrollable',
    (tester) async {
      tester.view.physicalSize = const Size(844, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init();
      await storage.saveConfig(
        jsonEncode({
          'sites': [
            for (var i = 0; i < 8; i++)
              {
                'key': 'verification$i',
                'name': '需要验证的长名称片源 $i',
                'type': 1,
                'api': 'https://verification.invalid/api/$i',
              },
          ],
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: AdaptiveShell(storage: storage, client: NoticeClient()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey('home-search-button')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(CupertinoTextField).last, '影片');
      await tester.tap(find.text('搜索').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final notice = find.byKey(const ValueKey('search-source-notices'));
      expect(notice, findsOneWidget);
      expect(tester.takeException(), isNull);
      final noticeScroll = find
          .ancestor(of: notice, matching: find.byType(SingleChildScrollView))
          .first;
      await tester.drag(noticeScroll, const Offset(0, -180));
      await tester.pumpAndSettle();
      expect(find.text('本次搜索未返回影片，请查看上方片源提示'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
