import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/js_source_host.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  tearDown(JsSourceHost.closeAll);

  Future<String> call(String key) => JsSourceHost.invoke(
    entry: 'pkg://fixture/source.js',
    modules: const {
      'pkg://fixture/source.js':
          'let count=0; export default {home(){return ++count}};',
    },
    sessionKey: key,
    method: 'home',
    arguments: const [],
  );

  Future<String?> cached(String key) => JsSourceHost.callCached(
    sessionKey: key,
    method: 'home',
    arguments: const [],
  );

  test(
    'paused playback keeps state through browsing until its last owner exits',
    () async {
      final releaseA = JsSourceHost.pinForPlayback('playing');
      final releaseB = JsSourceHost.pinForPlayback('playing');
      expect(await call('playing'), '1');
      for (var i = 0; i < 8; i++) {
        await call('browse-$i');
      }
      expect(await cached('playing'), '2');
      releaseA();
      releaseA(); // Repeated disposal must not release another player's ownership.
      for (var i = 8; i < 16; i++) {
        await call('browse-$i');
      }
      expect(await cached('playing'), '3');
      releaseB();
      for (var i = 16; i < 24; i++) {
        await call('browse-$i');
      }
      expect(await cached('playing'), isNull);
    },
  );

  test('full playback pool waits and resumes when an owner releases', () async {
    final releases = <void Function()>[];
    for (var i = 0; i < 6; i++) {
      releases.add(JsSourceHost.pinForPlayback('playing-$i'));
      await call('playing-$i');
    }
    var completed = false;
    final waiting = call('waiting').then((value) {
      completed = true;
      return value;
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(completed, isFalse);
    for (var i = 0; i < 6; i++) {
      expect(await cached('playing-$i'), '2');
    }
    releases.first();
    expect(await waiting.timeout(const Duration(seconds: 3)), '1');
    expect(await cached('playing-0'), isNull);
    for (final release in releases) {
      release();
    }
  });

  test(
    'deletion revokes old playback state and a late release cannot evict a reimport',
    () async {
      final oldRelease = JsSourceHost.pinForPlayback('source');
      expect(await call('source'), '1');
      await JsSourceHost.retainSessions({});
      expect(await cached('source'), isNull);
      final newRelease = JsSourceHost.pinForPlayback('source');
      expect(await call('source'), '1');
      oldRelease();
      for (var i = 0; i < 8; i++) {
        await call('other-$i');
      }
      expect(await cached('source'), '2');
      newRelease();
    },
  );
}
