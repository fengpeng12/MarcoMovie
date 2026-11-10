import 'dart:async';
import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/catpaw_host.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/source_verification.dart';
import 'package:marco_movie/ui/source_verification_dialog.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'guard_source_test.dart' as ports;

const png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lWQAAAAASUVORK5CYII=';
const source = CmsSite(
  key: 'fy',
  name: '本地测试片源',
  type: 3,
  api: 'csp_FyGuard',
  jar: 'https://import.invalid/plugin.jar',
  subscriptionId: 'one',
  headers: {'Authorization': 'fixture-only'},
);
final aueteSource = source.copyWith(key: 'auete', api: 'csp_AueteGuard');
Map<String, dynamic> challenge(String id) => {
  'type': 'image',
  'id': id,
  'mime': 'image/png',
  'imageBase64': png,
};

class ActionHost extends ports.PortHost {
  final actions = <Map<String, dynamic>>[];
  final addresses = <String>[];
  Map<String, dynamic>? response;
  @override
  Future<String> callDrpy(
    String address,
    String method,
    List<Object?> args, {
    Completer<void>? cancellation,
  }) async {
    addresses.add(address);
    if (method == 'home') return '{"class":[{"type_id":"1","type_name":"电影"}]}';
    if (method == 'homeVod') {
      throw const DrpySourceException('drpy_verification_required', '需要验证');
    }
    expect(method, 'action');
    final action = Map<String, dynamic>.from(
      jsonDecode(args.single as String) as Map,
    );
    actions.add(action);
    return jsonEncode(
      response ??
          (action['operation'] == 'challenge'
              ? challenge('fixture-id')
              : {'verified': action['code'] == 'AB12'}),
    );
  }
}

class DialogClient extends CmsClient {
  int loads = 0;
  final submitted = <(String, String)>[];
  Completer<SourceImageChallenge>? pending;
  Completer<void>? lastAbort;
  bool failLoad = false;
  @override
  Future<SourceImageChallenge> loadSourceChallenge(
    CmsSite site, {
    Completer<void>? cancellation,
  }) async {
    lastAbort = cancellation;
    loads++;
    if (failLoad) throw StateError('untrusted upstream text');
    if (pending != null) return pending!.future;
    return SourceImageChallenge.fromResponse(challenge('image-$loads'));
  }

  @override
  Future<bool> submitSourceChallenge(
    CmsSite site,
    String id,
    String code, {
    Completer<void>? cancellation,
  }) async {
    submitted.add((id, code));
    return code == 'AB12';
  }
}

class ShellClient extends DialogClient {
  bool verified = false;
  bool protectHome = false;
  int homes = 0;
  final filters = <String>[];
  final searches = <String>[];
  final searchRequests = <(String, String, int)>[];
  static const required = DrpySourceException(
    'drpy_verification_required',
    '需要完成验证码',
  );
  @override
  Future<(List<CmsCategory>, CmsListing)> fetchHome(CmsSite site) async {
    homes++;
    if (protectHome && !verified) throw required;
    return (const [CmsCategory(id: '1', name: '电影')], const CmsListing());
  }

  @override
  Future<CmsListing> fetchCategory(
    CmsSite site,
    String categoryId,
    int page, {
    List<String> childIds = const [],
    CmsFilter? filter,
  }) async {
    filters.add(filter?.genreLabel ?? '');
    if (!verified && filter?.genreLabel == '动作') throw required;
    return const CmsListing(
      sourceFiltered: true,
      videos: [CmsVideo(id: 'one', title: '验证后的影片')],
    );
  }

  @override
  Future<CmsListing> fetchSearch(
    CmsSite site,
    String keyword, {
    int page = 1,
  }) async {
    searches.add(site.key);
    searchRequests.add((site.key, keyword, page));
    final guarded = CmsClient.canVerifySource(site);
    if (guarded && !verified) throw required;
    return CmsListing(
      videos: [CmsVideo(id: site.key, title: guarded ? '验证后的结果' : '原有结果')],
    );
  }

  @override
  Future<bool> submitSourceChallenge(
    CmsSite site,
    String id,
    String code, {
    Completer<void>? cancellation,
  }) async {
    verified = await super.submitSourceChallenge(
      site,
      id,
      code,
      cancellation: cancellation,
    );
    return verified;
  }
}

Future<void> shell(
  WidgetTester tester,
  ShellClient client, {
  bool search = false,
  CmsSite guardedSource = source,
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final storage = await StorageService.init();
  await storage.saveConfig(
    jsonEncode({
      'spider': 'https://import.invalid/plugin.jar',
      'sites': [
        {
          'key': guardedSource.key,
          'name': '本地测试片源',
          'type': 3,
          'api': guardedSource.api,
          'searchable': 1,
        },
        if (search)
          {
            'key': 'healthy',
            'name': '正常片源',
            'type': 1,
            'api': 'https://source.invalid/api',
            'searchable': 1,
          },
      ],
    }),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: AdaptiveShell(storage: storage, client: client),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> verify(WidgetTester tester) async {
  await tester.ensureVisible(find.text('完成验证'));
  await tester.tap(find.text('完成验证'));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.descendant(
      of: find.byType(SourceVerificationDialog),
      matching: find.byType(CupertinoTextField),
    ),
    'AB12',
  );
  await tester.tap(find.text('验证并重试'));
  await tester.pumpAndSettle();
}

Future<void> launch(
  WidgetTester tester,
  DialogClient client,
  VoidCallback verified, {
  double scale = 1,
  double keyboard = 0,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: true,
          textScaler: TextScaler.linear(scale),
          viewInsets: EdgeInsets.only(bottom: keyboard),
        ),
        child: child!,
      ),
      home: Scaffold(
        body: Center(
          child: SourceVerificationButton(
            client: client,
            site: source,
            onVerified: () async {
              verified();
            },
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('完成验证'));
  await tester.pumpAndSettle();
}

void main() {
  for (final selected in [source, aueteSource]) {
    test(
      '${selected.key} actions retain source identity and drop import-only credentials',
      () async {
        final host = ActionHost();
        var downloads = 0;
        final client = CmsClient(
          scriptHost: host,
          client: MockClient((_) async {
            downloads++;
            return http.Response('synthetic artifact', 200);
          }),
        );
        final image = await client.loadSourceChallenge(selected);
        expect(
          await client.submitSourceChallenge(selected, image.id, 'NOPE'),
          false,
        );
        expect(
          await client.submitSourceChallenge(selected, image.id, 'AB12'),
          true,
        );
        expect(downloads, 1);
        expect(host.addresses.toSet().length, 1);
        expect(host.adapters, [selected.key == 'fy' ? 'fy-v1' : 'auete-v1']);
        expect(host.manifest!['headers'], isEmpty);
        expect(host.actions.last['id'], image.id);
        final before = host.actions.length;
        await expectLater(
          client.submitSourceChallenge(selected, image.id, '12'),
          throwsFormatException,
        );
        await expectLater(
          client.loadSourceChallenge(
            selected,
            cancellation: Completer<void>()..complete(),
          ),
          throwsFormatException,
        );
        await expectLater(
          client.loadSourceChallenge(
            selected.copyWith(api: 'csp_UnknownGuard'),
          ),
          throwsFormatException,
        );
        expect(host.actions.length, before);
        host.response = {'verified': 1};
        await expectLater(
          client.submitSourceChallenge(selected, image.id, 'AB12'),
          throwsFormatException,
        );
      },
    );
  }

  test(
    'home verification is surfaced without issuing a hidden category retry',
    () async {
      final host = ActionHost();
      final client = CmsClient(
        scriptHost: host,
        client: MockClient((_) async => http.Response('fixture', 200)),
      );
      await expectLater(
        client.fetchHome(source),
        throwsA(isA<DrpySourceException>()),
      );
      expect(host.addresses.length, 2);
    },
  );

  test(
    'image response rejects remote content, mismatched type and excess size',
    () {
      expect(
        SourceImageChallenge.fromResponse(challenge('one')).bytes.length,
        greaterThan(8),
      );
      for (final value in [
        {
          ...challenge('one'),
          'imageBase64': base64Encode(
            utf8.encode('<html>remote content</html>'),
          ),
        },
        {...challenge('one'), 'mime': 'image/svg+xml'},
        {...challenge('one'), 'id': '../other'},
        {...challenge('one'), 'imageBase64': 'A' * 350004},
      ]) {
        expect(
          () => SourceImageChallenge.fromResponse(value),
          throwsFormatException,
        );
      }
    },
  );

  testWidgets('wrong input, refresh and success retry exactly once', (
    tester,
  ) async {
    final client = DialogClient();
    var retries = 0;
    await launch(tester, client, () => retries++);
    await tester.enterText(find.byType(CupertinoTextField), 'NOPE');
    await tester.tap(find.text('验证并重试'));
    await tester.pumpAndSettle();
    expect(find.text('验证码不正确，请重新输入或刷新图片'), findsOneWidget);
    expect(retries, 0);
    await tester.tap(find.text('刷新图片'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(CupertinoTextField), 'AB12');
    await tester.tap(find.text('验证并重试'));
    await tester.pumpAndSettle();
    expect(client.submitted, [('image-1', 'NOPE'), ('image-2', 'AB12')]);
    expect(retries, 1);
    expect(find.byType(SourceVerificationDialog), findsNothing);
  });

  testWidgets('cancel pending request ignores late results and never retries', (
    tester,
  ) async {
    final client = DialogClient()..pending = Completer<SourceImageChallenge>();
    var retries = 0;
    // Activity indicator remains animated while pending; do not pumpAndSettle.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SourceVerificationButton(
            client: client,
            site: source,
            onVerified: () async {
              retries++;
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('完成验证'));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(client.lastAbort!.isCompleted, true);
    client.pending!.complete(
      SourceImageChallenge.fromResponse(challenge('late')),
    );
    await tester.pumpAndSettle();
    expect(retries, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('removing the owner dismisses its dialog and cancels work', (
    tester,
  ) async {
    final client = DialogClient();
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: visible,
            builder: (_, show, __) => show
                ? SourceVerificationButton(
                    client: client,
                    site: source,
                    onVerified: () async {
                      fail('Removed source must not retry');
                    },
                  )
                : const SizedBox(),
          ),
        ),
      ),
    );
    await tester.tap(find.text('完成验证'));
    await tester.pumpAndSettle();
    visible.value = false;
    await tester.pumpAndSettle();
    expect(find.byType(SourceVerificationDialog), findsNothing);
    expect(client.lastAbort!.isCompleted, true);
    expect(tester.takeException(), isNull);
  });

  testWidgets('image load errors use trusted text and permit refresh', (
    tester,
  ) async {
    final client = DialogClient()..failLoad = true;
    await launch(tester, client, () {});
    expect(find.text('验证码暂时无法加载，请刷新后重试'), findsOneWidget);
    expect(find.textContaining('untrusted'), findsNothing);
    client.failLoad = false;
    await tester.tap(find.text('刷新图片'));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'homepage retries the blocked source after explicit verification',
    (tester) async {
      final client = ShellClient()..protectHome = true;
      await shell(tester, client);
      expect(client.homes, 1);
      expect(find.byType(SourceVerificationDialog), findsNothing);
      await verify(tester);
      expect(client.homes, 2);
      expect(find.text('完成验证'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'filter retry preserves the selected genre instead of reloading home',
    (tester) async {
      final client = ShellClient();
      await shell(tester, client);
      await tester.tap(find.text('电影').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('home-filter-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('动作').first);
      await tester.pumpAndSettle();
      expect(client.filters.last, '动作');
      await verify(tester);
      expect(client.filters.sublist(client.filters.length - 2), ['动作', '动作']);
      expect(client.homes, 1);
      expect(find.text('验证后的影片'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final selected in [source, aueteSource]) {
    testWidgets(
      '${selected.key} search retry retains healthy results and the blocked query',
      (tester) async {
        final client = ShellClient();
        await shell(tester, client, search: true, guardedSource: selected);
        await tester.tap(find.byKey(const ValueKey('home-search-button')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(CupertinoTextField).last, '影片 & 二');
        await tester.tap(find.text('搜索').last);
        await tester.pumpAndSettle();
        expect(find.text('原有结果'), findsOneWidget);
        await verify(tester);
        expect(find.text('原有结果'), findsOneWidget);
        expect(find.text('验证后的结果'), findsOneWidget);
        expect(client.searches.where((v) => v == 'healthy').length, 1);
        expect(client.searches.where((v) => v == selected.key).length, 2);
        expect(
          client.searchRequests.where((value) => value.$1 == selected.key),
          [(selected.key, '影片 & 二', 1), (selected.key, '影片 & 二', 1)],
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final size in [const Size(320, 640), const Size(740, 390)]) {
    testWidgets('dialog fits $size with large text and keyboard', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await launch(tester, DialogClient(), () {}, scale: 1.6, keyboard: 180);
      expect(tester.takeException(), isNull);
      final rect = tester.getRect(find.byType(CupertinoTextField));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(size.width));
      await tester.ensureVisible(find.text('取消'));
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    });
  }
}
