import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/ui/source_choice_sliver.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/apple_theme.dart';

Future<void> openPrivacyUnlock(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final storage = await StorageService.init();
  await storage.setPrivacyPassword('1234');
  await storage.saveConfig(
    '{"sites":[{"key":"test","name":"测试源","type":1,"api":"https://source.example/api"}]}',
  );
  final client = CmsClient(
    client: MockClient(
      (_) async => http.Response('{"class":[],"list":[]}', 200),
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          padding:
              MediaQuery.sizeOf(context).width >
                  MediaQuery.sizeOf(context).height
              ? const EdgeInsets.fromLTRB(44, 0, 44, 21)
              : const EdgeInsets.fromLTRB(0, 44, 0, 34),
        ),
        child: child!,
      ),
      home: AdaptiveShell(storage: storage, client: client),
    ),
  );
  await tester.pump(const Duration(milliseconds: 500));
  for (var i = 0; i < 5; i++) {
    await tester.tap(find.byKey(const ValueKey('home-brand-logo')));
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  testWidgets(
    'rotating the PIN dialog keeps controls reachable and entered digits',
    (tester) async {
      await openPrivacyUnlock(tester);
      await tester.tap(find.text('1'));
      await tester.tap(find.text('2'));
      await tester.pump();
      tester.view.physicalSize = const Size(844, 390);
      await tester.pumpAndSettle();
      final viewport = tester.getRect(
        find.byKey(const ValueKey('privacy-pin-scroll')),
      );
      expect(viewport.left, greaterThanOrEqualTo(44));
      expect(viewport.right, lessThanOrEqualTo(800));
      expect(viewport.top, greaterThanOrEqualTo(16));
      expect(viewport.bottom, lessThanOrEqualTo(369));
      await tester.ensureVisible(find.text('0'));
      await tester.pumpAndSettle();
      expect(find.text('取消').hitTestable(), findsOneWidget);
      await tester.ensureVisible(find.text('3'));
      await tester.tap(find.text('3'));
      await tester.ensureVisible(find.text('4'));
      await tester.tap(find.text('4'));
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('privacy-pin-glass')), findsNothing);
      expect(
        find.byKey(const ValueKey('home-exit-privacy-pill')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('dismissal cancels a pending PIN unlock during its animation', (
    tester,
  ) async {
    await openPrivacyUnlock(tester);
    for (final digit in ['1', '2', '3', '4']) {
      await tester.tap(find.text(digit));
    }
    Navigator.of(
      tester.element(find.byKey(const ValueKey('privacy-pin-glass'))),
    ).pop();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('home-exit-privacy-pill')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('portrait settings notice is laid out above the actual Dock', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    await tester.pumpWidget(
      MaterialApp(
        home: AdaptiveShell(storage: storage, client: CmsClient()),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('设置').last);
    await tester.pump(const Duration(milliseconds: 500));
    final settingRows = find.byType(AppleGroupedTile);
    expect(settingRows, findsNWidgets(4));
    for (final row in settingRows.evaluate()) {
      expect(
        tester.getSize(find.byWidget(row.widget)).height,
        greaterThanOrEqualTo(88),
      );
    }
    final scaffold = tester.state<ScaffoldState>(find.byType(Scaffold).first);
    ScaffoldMessenger.of(scaffold.context).showSnackBar(
      const SnackBar(
        content: Text('设置已保存'),
        behavior: SnackBarBehavior.floating,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    final notice = tester.getRect(find.byType(SnackBar));
    final dock = tester.getRect(find.byType(AppleLiquidGlassDock));
    expect(notice.bottom, lessThanOrEqualTo(dock.top));
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
  });
  for (final size in [const Size(320, 740), const Size(740, 320)]) {
    testWidgets('source modal at $size with enlarged text remains usable', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init();
      await storage.saveConfig(
        '{"sites":[{"key":"long","name":"很长的线路名称高清影视完整显示","type":1,"api":"https://source.example/api"},{"key":"pending","name":"未移植测试线路","type":3,"api":"csp_TestPendingGuard","group":"扩展分组"}]}',
      );
      final client = CmsClient(
        client: MockClient(
          (_) async => http.Response('{"class":[],"list":[]}', 200),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(1.5)),
            child: child!,
          ),
          home: AdaptiveShell(storage: storage, client: client),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      final brand = tester.getRect(
        find.byKey(const ValueKey('home-brand-logo')),
      );
      final sourceLabel = tester.getRect(find.text('很长的线路名称高清影视完整显示').first);
      expect(sourceLabel.center.dy, closeTo(brand.center.dy, 3));
      await tester.tap(find.text('很长的线路名称高清影视完整显示').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(SourceChoiceSliver), findsOneWidget);
      final favorite = find.byKey(const ValueKey('source-preference-long'));
      expect(favorite, findsOneWidget);
      await tester.ensureVisible(favorite);
      await tester.pumpAndSettle();
      await tester.tap(favorite);
      await tester.pump();
      expect(storage.preferredSiteKey, 'long');
      expect(find.byTooltip('取消默认偏好源'), findsOneWidget);
      await tester.drag(
        find.byType(CustomScrollView).last,
        const Offset(0, 600),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText).first, '未移植');
      await tester.pumpAndSettle();
      expect(find.text('未移植测试线路'), findsOneWidget);
      expect(find.text('当前设备未适配 (1)'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('five logo taps open a Glasswork PIN dialog', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    await storage.saveConfig(
      '{"sites":[{"key":"test","name":"测试源","type":1,"api":"https://source.example/api"}]}',
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
    for (var i = 0; i < 5; i++) {
      await tester.tap(find.byKey(const ValueKey('home-brand-logo')));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 500));
    final pin = find.byKey(const ValueKey('privacy-pin-glass'));
    expect(pin, findsOneWidget);
    expect(tester.widget(pin), isA<AppleGlassSurface>());
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
