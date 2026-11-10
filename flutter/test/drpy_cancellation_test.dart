import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/catpaw_host.dart';
import 'package:marco_movie/core/drpy_source.dart';
import 'package:marco_movie/core/models.dart';

import 'drpy_host_test.dart' as fixture;

class RecordingHost extends CatPawHost {
  int installs = 0, calls = 0;
  final manifests = <Map<String, dynamic>>[];
  Completer<void>? installing;
  @override
  Future<String> installDrpy(Object manifest) async {
    installs++;
    manifests.add(Map<String, dynamic>.from(manifest as Map));
    await installing?.future;
    return 'catpaw://${'a' * 64}/api/drpy';
  }

  @override
  Future<String> callDrpy(
    String address,
    String method,
    List<Object?> args, {
    Completer<void>? cancellation,
  }) async {
    calls++;
    return '{}';
  }
}

const remote = CmsSite(
  key: 'fixture',
  name: 'Fixture',
  type: 3,
  api: 'csp_Drpy',
  ext: 'https://fixture.invalid/rule.js',
);
const rule = "var rule={title:'fixture',host:'https://fixture.invalid'};";

void main() {
  test('ownerless inline rules isolate state while imported rule updates retain it', () async {
    final host = RecordingHost();
    final source = DrpySource(host: host, read: (_, __) async => rule);
    CmsSite inline(String script, {String owner = '', String origin = ''}) => CmsSite(
      key: 'script_imported', name: 'Rule', type: 3, api: 'csp_LocalRule.js',
      subscriptionId: owner, ext: jsonEncode({'script': script, 'origin': origin}));
    await source.invoke(inline(rule), 'home', [false]);
    final first = host.manifests.last['sourceId'];
    await source.invoke(inline('$rule\nrule.title="another";'), 'home', [false]);
    expect(host.manifests.last['sourceId'], isNot(first));
    await source.invoke(inline(rule, owner: 'subscription'), 'home', [false]);
    final owned = host.manifests.last['sourceId'];
    await source.invoke(inline('$rule\nrule.title="updated";', owner: 'subscription'), 'home', [false]);
    expect(host.manifests.last['sourceId'], owned);
    await source.invoke(inline(rule, origin: 'https://first.invalid/rule.js'), 'home', [false]);
    final remoteId = host.manifests.last['sourceId'];
    await source.invoke(inline(rule, origin: 'https://second.invalid/rule.js'), 'home', [false]);
    expect(host.manifests.last['sourceId'], isNot(remoteId));
  });
  test(
    'rule userinfo becomes scoped Basic auth while origin is redacted',
    () async {
      final host = RecordingHost();
      final source = DrpySource(host: host, read: (_, __) async => rule);
      await source.invoke(
        remote.copyWith(
          ext: 'https://user:pass@fixture.invalid/rule.js#private',
        ),
        'home',
        [true],
      );
      expect(host.manifests.last['origin'], 'https://fixture.invalid/rule.js');
      expect(
        (host.manifests.last['headers'] as Map)['Authorization'],
        'Basic dXNlcjpwYXNz',
      );
      await source.invoke(
        remote.copyWith(
          ext: 'https://user:pass@fixture.invalid/other.js#private',
          headers: {'authorization': 'Bearer explicit'},
        ),
        'home',
        [true],
      );
      expect(host.manifests.last['headers'], {
        'authorization': 'Bearer explicit',
      });
    },
  );
  test(
    'cancelled source never starts installation or a cached invocation',
    () async {
      final host = RecordingHost();
      var reads = 0;
      final source = DrpySource(
        host: host,
        read: (_, __) async {
          reads++;
          return rule;
        },
      );
      final cancelled = Completer<void>()..complete();
      await expectLater(
        source.invoke(remote, 'home', [true], cancellation: cancelled),
        throwsFormatException,
      );
      expect(reads, 0);
      expect(host.installs, 0);
      expect(host.calls, 0);
      await source.invoke(remote, 'home', [true]);
      expect(host.calls, 1);
      await expectLater(
        source.callCached(remote, 'home', [true], cancellation: cancelled),
        throwsFormatException,
      );
      expect(host.calls, 1);
      final synchronousStop = Completer<void>();
      final immediate = DrpySource(
        host: host,
        read: (_, __) async {
          synchronousStop.complete();
          return rule;
        },
      );
      await expectLater(
        immediate.invoke(remote, 'home', [true], cancellation: synchronousStop),
        throwsFormatException,
      );
      await Future<void>.delayed(Duration.zero);
      expect(host.calls, 1);
    },
  );

  test(
    'cancelling installation cannot execute late or abort another caller',
    () async {
      final host = RecordingHost();
      final downloads = <Completer<String>>[];
      final source = DrpySource(
        host: host,
        read: (_, __) {
          final response = Completer<String>();
          downloads.add(response);
          return response.future;
        },
      );
      final cancellation = Completer<void>();
      final abandoned = expectLater(
        source.invoke(remote, 'home', [true], cancellation: cancellation),
        throwsFormatException,
      );
      final retained = source.invoke(remote, 'home', [true]);
      expect(downloads, hasLength(2));
      cancellation.complete();
      await abandoned.timeout(const Duration(seconds: 1));
      downloads[1].complete(rule);
      await retained;
      downloads[0].complete(rule);
      await Future<void>.delayed(Duration.zero);
      expect(host.installs, 1);
      expect(host.calls, 1);

      final staging = RecordingHost()..installing = Completer<void>();
      final duringWrite = DrpySource(
        host: staging,
        read: (_, __) async => rule,
      );
      final stop = Completer<void>();
      final pending = expectLater(
        duringWrite.invoke(remote, 'home', [true], cancellation: stop),
        throwsFormatException,
      );
      await Future<void>.delayed(Duration.zero);
      expect(staging.installs, 1);
      stop.complete();
      await pending.timeout(const Duration(seconds: 1));
      staging.installing!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(staging.calls, 0);
    },
  );

  test(
    'cancellation during resolve returns before startup and sends no late call',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'drpy-resolve-cancel-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final installer = CatPawHost(directory: () async => directory);
      final address = await installer.installDrpy(fixture.manifest());
      final storage = Completer<Directory>();
      final host = CatPawHost(
        directory: () => storage.future,
        executable: 'must-not-start',
      );
      addTearDown(host.close);
      final cancellation = Completer<void>();
      final result = expectLater(
        host.callDrpy(address, 'home', [true], cancellation: cancellation),
        throwsFormatException,
      );
      await Future<void>.delayed(Duration.zero);
      cancellation.complete();
      await result.timeout(const Duration(seconds: 1));
      storage.complete(directory);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(await File('${directory.path}/ready.json').exists(), isFalse);
    },
  );

  test(
    'cancelling one address caller does not release another active caller',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'drpy-concurrent-cancel-',
      );
      final node = (await Process.run('node', [
        '-p',
        'process.execPath',
      ])).stdout.toString().trim();
      final bootstrap = await fixture.fixtureBootstrap(directory);
      final state = Directory('${directory.path}/state');
      final host = CatPawHost(
        directory: () async => state,
        executable: node,
        bootstrap: bootstrap,
      );
      addTearDown(() async {
        await host.close();
        await directory.delete(recursive: true);
      });
      final address = await host.installDrpy(fixture.manifest());
      final stop = Completer<void>();
      final abandoned = expectLater(
        host.callDrpy(address, 'search', [
          'hold',
          false,
          1,
        ], cancellation: stop),
        throwsFormatException,
      );
      final retained = host.callDrpy(address, 'search', ['hold', false, 1]);
      final started = File('${state.path}/started.txt');
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while ((!await started.exists() || await started.length() != 2) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(await started.length(), 2);
      stop.complete();
      await abandoned;
      expect((jsonDecode(await retained) as Map)['list'], hasLength(1));
      expect(await File('${state.path}/releases.txt').exists(), isFalse);
      expect(
        (jsonDecode(await host.callDrpy(address, 'home', [true]))
            as Map)['list'],
        hasLength(1),
      );
    },
  );

  test(
    'actual in-flight cancellation stops source work and address remains reusable',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'drpy-call-cancel-',
      );
      final node = (await Process.run('node', [
        '-p',
        'process.execPath',
      ])).stdout.toString().trim();
      final host = CatPawHost(
        directory: () async => directory,
        executable: node,
        bootstrap: '${Directory.current.path}/assets/catpaw/host.cjs',
      );
      addTearDown(() async {
        await host.close();
        await directory.delete(recursive: true);
      });
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final started = Completer<void>(), disconnected = Completer<void>();
      HttpResponse? held;
      server.listen((request) {
        held = request.response;
        request.response.done.then(
          (_) {
            if (!disconnected.isCompleted) disconnected.complete();
          },
          onError: (Object _) {
            if (!disconnected.isCompleted) disconnected.complete();
          },
        );
        started.complete();
      });
      final base = 'http://127.0.0.1:${server.port}';
      final address = await host.installDrpy({
        ...fixture.manifest(),
        'origin': '$base/rule.js',
        'rule':
            'var rule=${jsonEncode({'title': 'cancel fixture', 'host': base, 'homeUrl': '/', 'searchUrl': '/slow?wd=**', '一级': 'js:VODS=[];', 'class_parse': 'js:input=[{type_id:"1",type_name:getItem("finished","none")}];', '搜索': 'js:request(input);setItem("finished","yes");VODS=[];'})};',
      });
      final cancellation = Completer<void>();
      final pending = expectLater(
        host.callDrpy(address, 'search', [
          'first',
          false,
          1,
        ], cancellation: cancellation),
        throwsFormatException,
      );
      await started.future.timeout(const Duration(seconds: 8));
      cancellation.complete();
      await pending.timeout(const Duration(seconds: 2));
      final home =
          jsonDecode(await host.callDrpy(address, 'home', [true])) as Map;
      expect((home['class'] as List).single['type_name'], 'none');
      try {
        held?.write('{}');
        await held?.close();
      } catch (_) {}
      await disconnected.future.timeout(const Duration(seconds: 2));
    },
  );
}
