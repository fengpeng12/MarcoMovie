import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/ui/mobile_player_chrome.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late MobilePlayerChrome chrome;
  late List<MethodCall> calls;
  Completer<void>? delayedOrientation;
  Completer<void>? delayedMode;

  setUp(() {
    chrome = MobilePlayerChrome();
    calls = [];
    delayedOrientation = null;
    delayedMode = null;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      if (call.method == 'SystemChrome.setPreferredOrientations' &&
          (call.arguments as List).length == 2 &&
          (call.arguments as List).contains(
            'DeviceOrientation.landscapeLeft',
          )) {
        await delayedOrientation?.future;
      }
      if (call.method == 'SystemChrome.setEnabledSystemUIMode' &&
          call.arguments == 'SystemUiMode.immersiveSticky') {
        await delayedMode?.future;
      }
      return null;
    });
  });

  tearDown(() async {
    await chrome.close();
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  List<String> modes() => calls
      .where((call) => call.method == 'SystemChrome.setEnabledSystemUIMode')
      .map((call) => call.arguments as String)
      .toList();

  test(
    'closing restores the default orientation policy and visible system bars',
    () async {
      expect(await chrome.setLandscape(true), isTrue);
      expect(await chrome.setLandscape(false), isTrue);
      await chrome.close();
      final orientations = calls
          .where(
            (call) => call.method == 'SystemChrome.setPreferredOrientations',
          )
          .map((call) => call.arguments)
          .toList();
      expect(orientations, [
        ['DeviceOrientation.landscapeLeft', 'DeviceOrientation.landscapeRight'],
        ['DeviceOrientation.portraitUp'],
        DeviceOrientation.values
            .map((orientation) => orientation.toString())
            .toList(),
      ]);
      expect(modes(), [
        'SystemUiMode.immersiveSticky',
        'SystemUiMode.edgeToEdge',
        'SystemUiMode.edgeToEdge',
      ]);
      final count = calls.length;
      expect(await chrome.setLandscape(true), isFalse);
      await chrome.close();
      expect(calls.length, count);
    },
  );

  test(
    'exiting during a delayed orientation reply cannot re-enter immersive mode',
    () async {
      delayedOrientation = Completer<void>();
      final entry = chrome.setLandscape(true);
      await Future<void>.delayed(Duration.zero);
      await chrome.close();
      delayedOrientation!.complete();
      expect(await entry, isFalse);
      expect(modes(), ['SystemUiMode.edgeToEdge']);
    },
  );

  test(
    'a newer portrait request wins over a delayed landscape reply',
    () async {
      delayedOrientation = Completer<void>();
      final entry = chrome.setLandscape(true);
      await Future<void>.delayed(Duration.zero);
      expect(await chrome.setLandscape(false), isTrue);
      delayedOrientation!.complete();
      expect(await entry, isFalse);
      expect(modes(), ['SystemUiMode.edgeToEdge']);
    },
  );

  test(
    'exiting while the immersive reply is delayed leaves restoration last',
    () async {
      delayedMode = Completer<void>();
      final entry = chrome.setLandscape(true);
      await Future<void>.delayed(Duration.zero);
      expect(modes(), ['SystemUiMode.immersiveSticky']);
      await chrome.close();
      delayedMode!.complete();
      expect(await entry, isFalse);
      expect(modes(), [
        'SystemUiMode.immersiveSticky',
        'SystemUiMode.edgeToEdge',
      ]);
    },
  );
}
