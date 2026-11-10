import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/ui/desktop_player_window.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('window_manager');
  late DesktopPlayerWindow window;
  late List<MethodCall> calls;
  late bool full;
  late bool failEntry;
  late bool delayTransitions;
  late List<({bool full, Completer<void> done})> transitions;

  setUp(() {
    calls = [];
    full = false;
    failEntry = false;
    delayTransitions = false;
    transitions = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'isFullScreen') return full;
          if (call.method == 'setFullScreen') {
            final target = call.arguments['isFullScreen'] as bool;
            if (failEntry && target) throw PlatformException(code: 'fixture');
            void complete() {
              full = target;
              if (target) {
                window.onWindowEnterFullScreen();
              } else {
                window.onWindowLeaveFullScreen();
              }
            }

            if (delayTransitions) {
              final done = Completer<void>();
              transitions.add((full: target, done: done));
              unawaited(done.future.then((_) => complete()));
            } else {
              complete();
            }
          }
          return null;
        });
  });

  tearDown(() async {
    delayTransitions = false;
    failEntry = false;
    await window.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  List<MethodCall> writes() =>
      calls.where((c) => c.method != 'isFullScreen').toList();

  test(
    'Windows hides the title before native fullscreen and restores the frame',
    () async {
      window = DesktopPlayerWindow(macOS: false);
      await window.initialize();
      await window.toggle();
      expect(window.fullscreen, true);
      expect(writes().first.method, 'setTitleBarStyle');
      expect(writes().first.arguments, {
        'titleBarStyle': 'hidden',
        'windowButtonVisibility': false,
      });
      expect(writes()[1].method, 'setFullScreen');
      expect(writes()[1].arguments, {'isFullScreen': true});
      expect(await window.exitFullscreen(), true);
      expect(window.fullscreen, false);
      expect(writes().last.arguments, {
        'titleBarStyle': 'normal',
        'windowButtonVisibility': true,
      });
      expect(await window.exitFullscreen(), false);
    },
  );

  test(
    'Mac serializes rapid toggles until the native animation completes',
    () async {
      window = DesktopPlayerWindow(macOS: true);
      await window.initialize();
      delayTransitions = true;
      final enter = window.toggle();
      final leave = window.toggle();
      await Future<void>.delayed(Duration.zero);
      expect(transitions.length, 1);
      expect(transitions[0].full, true);
      transitions[0].done.complete();
      await enter;
      await Future<void>.delayed(Duration.zero);
      expect(transitions.length, 2);
      expect(transitions[1].full, false);
      transitions[1].done.complete();
      await leave;
      expect(window.fullscreen, false);
      expect(writes().last.arguments, {
        'titleBarStyle': 'hidden',
        'windowButtonVisibility': true,
      });
    },
  );

  test(
    'leaving the route during a Mac entry restores its original state',
    () async {
      window = DesktopPlayerWindow(macOS: true);
      await window.initialize();
      delayTransitions = true;
      final enter = window.toggle();
      await Future<void>.delayed(Duration.zero);
      final close = window.close();
      transitions[0].done.complete();
      await enter;
      await Future<void>.delayed(Duration.zero);
      expect(transitions[1].full, false);
      transitions[1].done.complete();
      await close;
      expect(full, false);
    },
  );

  test(
    'a player opened in fullscreen preserves that state on return',
    () async {
      full = true;
      window = DesktopPlayerWindow(macOS: false);
      await window.initialize();
      await window.toggle();
      await window.close();
      expect(full, true);
      expect(writes().last.arguments['windowButtonVisibility'], false);
    },
  );

  test(
    'failed entry restores visible window controls and can be retried',
    () async {
      window = DesktopPlayerWindow(macOS: false);
      await window.initialize();
      failEntry = true;
      await expectLater(window.toggle(), throwsA(isA<PlatformException>()));
      expect(window.fullscreen, false);
      expect(writes().last.arguments, {
        'titleBarStyle': 'normal',
        'windowButtonVisibility': true,
      });
      failEntry = false;
      await window.toggle();
      expect(window.fullscreen, true);
    },
  );

  test(
    'system fullscreen exit updates state and restores Mac buttons',
    () async {
      window = DesktopPlayerWindow(macOS: true);
      await window.initialize();
      await window.toggle();
      full = false;
      window.onWindowLeaveFullScreen();
      await Future<void>.delayed(Duration.zero);
      expect(window.fullscreen, false);
      expect(writes().last.arguments, {
        'titleBarStyle': 'hidden',
        'windowButtonVisibility': true,
      });
    },
  );
}
