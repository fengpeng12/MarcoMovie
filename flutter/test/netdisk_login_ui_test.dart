import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:marco_movie/core/netdisk_service.dart';
import 'package:marco_movie/core/quark_account.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/local_qr_code.dart';
import 'package:marco_movie/ui/netdisk_sheet.dart';

class PendingLogin extends NetdiskService {
  final creations = <Completer<NetdiskQrSession>>[];
  final polls = <Completer<NetdiskPollResult>>[];
  @override
  Future<NetdiskQrSession> createQrSession(String driveKey) {
    final result = Completer<NetdiskQrSession>();
    creations.add(result);
    return result.future;
  }

  @override
  Future<NetdiskPollResult> pollQrStatus(NetdiskQrSession session) {
    final result = Completer<NetdiskPollResult>();
    polls.add(result);
    return result.future;
  }
}

NetdiskQrSession challenge(String token) => NetdiskQrSession(
  driveKey: 'quark',
  qrContentUrl: 'https://login.example/confirm?token=$token',
  qrImageUrl: '',
  token: token,
);
String credential() => QuarkAccountSession(
  cookie: '__pus=fixture-identity; __puus=fixture-cookie',
  driveSt: 'fixture-drive-ticket',
  accountId: sha256.convert(utf8.encode('fixture-identity')).toString(),
  validatedAt: DateTime.now(),
).toCredential();

Future<StorageService> open(WidgetTester tester, PendingLogin service) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(service.close);
  SharedPreferences.setMockInitialValues({});
  final storage = await StorageService.init();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showNetdiskAccountSheet(
              context,
              storage,
              initialDriveKey: 'quark',
              service: service,
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return storage;
}

void main() {
  testWidgets(
    'refresh replaces the real local QR and rejects an older creation',
    (tester) async {
      final service = PendingLogin();
      final storage = await open(tester, service);
      await tester.ensureVisible(find.text('刷新二维码'));
      await tester.tap(find.text('刷新二维码'));
      await tester.pump();
      expect(service.creations.length, 2);
      service.creations[1].complete(challenge('new'));
      await tester.pump();
      service.creations[0].complete(challenge('old'));
      await tester.pump();
      expect(
        tester.widget<LocalQrCode>(find.byType(LocalQrCode)).data,
        contains('token=new'),
      );
      expect(find.byType(Image), findsNothing);
      expect(find.text('我已扫码授权'), findsNothing);
      expect(storage.isNetdiskLoggedIn('quark'), isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'late poll after refresh cannot save credentials and polls never overlap',
    (tester) async {
      final service = PendingLogin();
      final storage = await open(tester, service);
      service.creations.single.complete(challenge('first'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 9));
      expect(service.polls.length, 1);
      await tester.ensureVisible(find.text('刷新二维码'));
      await tester.tap(find.text('刷新二维码'));
      await tester.pump();
      service.polls.single.complete(
        NetdiskPollResult(
          state: NetdiskPollState.confirmed,
          message: 'Authenticated',
          credential: credential(),
        ),
      );
      await tester.pump();
      expect(storage.getNetdiskCred('quark'), isEmpty);
      service.creations.last.complete(challenge('second'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      service.polls.last.complete(
        NetdiskPollResult(
          state: NetdiskPollState.confirmed,
          message: 'Authenticated',
          credential: credential(),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(storage.isNetdiskLoggedIn('quark'), isTrue);
      expect(find.byKey(const ValueKey('quark-browse-files')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('closing login ignores an in-flight successful response', (
    tester,
  ) async {
    final service = PendingLogin();
    final storage = await open(tester, service);
    service.creations.single.complete(challenge('closed'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.tap(find.byIcon(CupertinoIcons.xmark_circle_fill));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    service.polls.single.complete(
      NetdiskPollResult(
        state: NetdiskPollState.confirmed,
        message: 'Authenticated',
        credential: credential(),
      ),
    );
    await tester.pump();
    expect(storage.getNetdiskCred('quark'), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test(
    'legacy placeholders are not authenticated and external changes invalidate shared sessions',
    () async {
      SharedPreferences.setMockInitialValues({
        StorageService.keyQuarkCookie: '__puus=qr_auth_old',
      });
      final storage = await StorageService.init();
      final second = await StorageService.init();
      expect(storage.isNetdiskLoggedIn('quark'), isFalse);
      expect(identical(storage.quarkAccounts, second.quarkAccounts), isTrue);
      final generation = storage.quarkAccounts.generation;
      await storage.setNetdiskCred('quark', credential());
      expect(storage.isNetdiskLoggedIn('quark'), isTrue);
      expect(storage.quarkAccounts.generation, greaterThan(generation));
      await second.setNetdiskCred('quark', '');
      expect(storage.isNetdiskLoggedIn('quark'), isFalse);
    },
  );

  testWidgets('a late waiting response stays paused until one foreground poll', (tester) async {
    final service = PendingLogin();
    await open(tester, service);
    service.creations.single.complete(challenge('background-wait'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(service.polls.length, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    service.polls.single.complete(NetdiskPollResult(
      state: NetdiskPollState.waiting, message: 'Waiting'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(service.polls.length, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(service.polls.length, 2);
    await tester.pump(const Duration(seconds: 10));
    expect(service.polls.length, 2, reason: 'Resuming does not overlap polls.');
    service.polls.last.complete(NetdiskPollResult(
      state: NetdiskPollState.waiting, message: 'Waiting'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an in-flight confirmed login is saved while background polling stops', (tester) async {
    final service = PendingLogin();
    final storage = await open(tester, service);
    service.creations.single.complete(challenge('background-success'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    service.polls.single.complete(NetdiskPollResult(
      state: NetdiskPollState.confirmed, message: 'Authenticated', credential: credential()));
    await tester.pump();
    await tester.pump();
    expect(storage.isNetdiskLoggedIn('quark'), isTrue);
    await tester.pump(const Duration(seconds: 10));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(service.polls.length, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('QR creation finishing in background does not begin polling', (tester) async {
    final service = PendingLogin();
    await open(tester, service);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    service.creations.single.complete(challenge('background-create'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(service.polls, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(service.polls.length, 1);
    await tester.pumpWidget(const SizedBox());
    service.polls.single.complete(NetdiskPollResult(
      state: NetdiskPollState.waiting, message: 'Waiting'));
    await tester.pump();
  });
}
