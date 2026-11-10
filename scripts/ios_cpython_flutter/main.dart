// Disposable integration app. Never routes imported user scripts to CPython.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:quickjs_engine/quickjs_engine.dart';

import 'transport_fixture.dart';
import 'source_fixture.dart';

const python = MethodChannel('marco_movie/experimental_python');
const node = MethodChannel('marco_movie/catpaw');

Future<Map<String, dynamic>> bridge(
  String method, [
  Map<String, dynamic>? args,
]) async => Map<String, dynamic>.from(
  await python.invokeMethod(method, args).timeout(const Duration(seconds: 15))
      as Map,
);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(
        body: Center(child: Text('Experimental runtime validation')),
      ),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(runFixture());
  });
}

Future<void> runFixture() async {
  final checks = <Map<String, dynamic>>[];
  final report = <String, dynamic>{
    'passed': false,
    'checks': checks,
    'scope': 'Owned Flutter simulator fixture only',
    'physical_device_tested': false,
    'user_sources_tested': false,
    'hard_cancellation_tested': false,
  };
  String? output;
  QuickJsRuntime2? js;
  PythonTransportFixture? pythonHttp;
  var beats = 0;
  final heartbeat = Timer.periodic(const Duration(milliseconds: 20), (_) {
    beats++;
  });
  final watchdog = Timer(const Duration(seconds: 50), () {
    if (output != null) {
      File(output).writeAsStringSync(
        jsonEncode({
          ...report,
          'passed': false,
          'failure':
              'Flutter fixture deadline; no hard Python cancellation attempted',
        }),
      );
    }
  });
  final http = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  void check(String name, bool passed) {
    checks.add({'name': name, 'passed': passed});
    if (!passed) throw StateError(name);
  }

  Future<String> getText(String url) async {
    final request = await http.getUrl(Uri.parse(url));
    final response = await request.close().timeout(const Duration(seconds: 5));
    if (response.statusCode != 200) {
      throw StateError('Owned server HTTP ${response.statusCode}');
    }
    return utf8.decode(
      await response.fold<List<int>>([], (all, bytes) => all..addAll(bytes)),
    );
  }

  Future<Map<String, dynamic>> call(
    String handle,
    String method,
    List<Object?> args,
  ) => bridge('call', {
    'version': 1,
    'handle': handle,
    'method': method,
    'args': args,
  });
  Future<void> rejected(
    String name,
    String method,
    Map<String, dynamic> args,
    String code,
  ) async {
    try {
      await bridge(method, args);
    } on PlatformException catch (error) {
      check(name, error.code == code);
      return;
    }
    check(name, false);
  }

  try {
    final initial = await bridge('capabilities', {'initialize': false});
    output = '${initial['documents']}/result.json';
    final order = initial['order'] as String;
    report['order'] = order;
    report['initial_signals'] = initial['signals'];
    if (order == 'python-first') await bridge('capabilities');
    final beforeNode = await bridge('capabilities', {'initialize': false});
    check(
      'launch_order_observed',
      initial['initialized'] == false &&
          beforeNode['initialized'] == (order == 'python-first'),
    );
    report['before_node_signals'] = beforeNode['signals'];
    check('actual_ios_flutter', Platform.isIOS);
    check(
      'owned_fixture_gate',
      initial['ownedFixtureOnly'] == true && initial['hardCancel'] == false,
    );
    final root = Directory('${initial['documents']}/node-fixture');
    await root.create(recursive: true);
    final ready = File('${root.path}/ready.json');
    if (await ready.exists()) await ready.delete();
    await File(
      '${root.path}/host.cjs',
    ).writeAsString(await rootBundle.loadString('assets/node-fixture.cjs'));
    await node.invokeMethod('start', {
      'root': root.path,
      'script': '${root.path}/host.cjs',
      'ready': ready.path,
    });
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!await ready.exists() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final nodeReady = jsonDecode(await ready.readAsString()) as Map;
    final origin = nodeReady['origin'] as String;
    final ping = jsonDecode(await getText('$origin/ping?q=initial')) as Map;
    report['node_runtime'] = ping['runtime'];
    check('pinned_node18', ping['runtime'] == 'v18.20.4');
    final afterNode = await bridge('capabilities', {'initialize': false});
    report['after_node_signals'] = afterNode['signals'];
    final capabilities = await bridge('capabilities');
    report['capabilities'] = {...capabilities}..remove('documents');
    check(
      'pinned_cpython',
      (capabilities['runtime'] as String).startsWith('3.14.10 '),
    );
    check(
      'python_preserves_existing_sigint',
      capabilities['pythonPreservedSigint'] == true,
    );
    js = QuickJsRuntime2(stackSize: 1024 * 1024);
    final firstJs = js.evaluate(
      'globalThis.fixtureCount=1; JSON.stringify({value:6*7,text:"中文"})',
    );
    check(
      'quickjs_execution',
      !firstJs.isError && jsonDecode(firstJs.stringResult)['value'] == 42,
    );
    final afterBoth = await bridge('capabilities', {'initialize': false});
    report['after_all_signals'] = afterBoth['signals'];
    check(
      'signal_policy_after_both',
      afterBoth['signals']['sigpipe'] == 'ignored',
    );
    final openArgs = {'version': 1, 'source': 'synthetic-v1', 'origin': origin};
    final a = (await bridge('open', openArgs))['handle'] as String;
    final b = (await bridge('open', openArgs))['handle'] as String;
    check(
      'opaque_unique_sessions',
      a != b && RegExp(r'^[0-9A-Fa-f-]{36}$').hasMatch(a),
    );
    await rejected('unknown_source_rejected', 'open', {
      ...openArgs,
      'source': 'user-script',
    }, 'invalid_request');
    await rejected('external_origin_rejected', 'open', {
      ...openArgs,
      'origin': 'https://example.invalid',
    }, 'invalid_request');
    await rejected(
      'session_capacity_bounded',
      'open',
      openArgs,
      'runtime_limit',
    );
    final home = await call(a, 'home', [true]);
    check('home_classes', home['class'][0]['type_name'] == '电影');
    check('source_instance_initial_count', home['fixture_calls'] == 1);
    check('native_requests_version', home['requests'] == '2.34.2');
    final other = await call(b, 'home', [true]);
    check('source_instance_state_separate', other['fixture_calls'] == 1);
    check(
      'subinterpreter_module_state_separate',
      home['module_instance'] == 1 && other['module_instance'] == 1,
    );
    check(
      'recommendations',
      (await call(a, 'homeVod', []))['list'][0]['vod_name'] == '本机示例',
    );
    check(
      'category_page',
      (await call(a, 'category', [
            'film',
            '2',
            false,
            <String, String>{},
          ]))['page'] ==
          2,
    );
    check(
      'search_unicode',
      (await call(a, 'search', ['中文查询', false]))['list'][0]['vod_name'] ==
          '中文查询',
    );
    final detail = (await call(a, 'detail', [
      <String>['opaque/\$#?中文'],
    ]))['list'][0];
    check('detail_opaque_id', detail['vod_id'] == 'opaque/\$#?中文');
    check('detail_bs4', detail['vod_content'] == '本机详情');
    check('detail_episodes', detail['vod_play_url'] == '第一集\$episode-1');
    final play = await call(a, 'play', ['local', 'episode-1', <String>[]]);
    check(
      'play_resolution',
      play['parse'] == 0 && play['episode'] == 'episode-1',
    );
    check(
      'synthetic_hls_prefix',
      (await getText(play['url'] as String)).startsWith('#EXTM3U\n'),
    );
    final proxy = await call(a, 'proxy', [<String, String>{}]);
    check(
      'binary_proxy_status_headers',
      proxy['status'] == 206 &&
          proxy['mime'] == 'application/octet-stream' &&
          proxy['headers']['X-Fixture'] == 'bytes',
    );
    check(
      'binary_proxy_exact_bytes',
      base64Decode(proxy['bodyBase64'] as String).join(',') ==
          '0,255,128,13,10,65',
    );
    check('same_source_retained_for_proxy', proxy['fixture_calls'] == 7);
    await rejected('unknown_method_rejected', 'call', {
      'version': 1,
      'handle': a,
      'method': 'eval',
      'args': <Object?>[],
    }, 'invalid_request');
    await rejected('python_exception_is_reported', 'call', {
      'version': 1,
      'handle': a,
      'method': 'detail',
      'args': <Object?>[<String>[]],
    }, 'python_error');
    check(
      'source_recovers_after_error',
      (await call(a, 'home', [false]))['fixture_calls'] == 8,
    );
    await rejected('fixture_redirect_rejected', 'call', {
      'version': 1,
      'handle': a,
      'method': 'search',
      'args': ['redirect-fixture', false],
    }, 'python_error');
    check(
      'source_recovers_after_redirect',
      (await call(a, 'home', [false]))['fixture_calls'] == 10,
    );
    check(
      'release_existing',
      (await bridge('release', {'version': 1, 'handle': a}))['released'] ==
          true,
    );
    await rejected('released_handle_invalid', 'call', {
      'version': 1,
      'handle': a,
      'method': 'home',
      'args': [false],
    }, 'invalid_handle');
    check(
      'release_idempotent',
      (await bridge('release', {'version': 1, 'handle': a}))['released'] ==
          false,
    );
    check(
      'other_session_survives_release',
      (await call(b, 'home', [false]))['fixture_calls'] == 2,
    );
    final fresh = (await bridge('open', openArgs))['handle'] as String;
    check('new_session_identity', fresh != a && fresh != b);
    check(
      'new_session_state_reset',
      (await call(fresh, 'home', [false]))['fixture_calls'] == 1,
    );
    await bridge('release', {'version': 1, 'handle': fresh});
    await bridge('release', {'version': 1, 'handle': b});
    check(
      'quickjs_state_survives_python',
      js.evaluate('++fixtureCount').stringResult == '2',
    );
    check(
      'node_survives_python',
      (jsonDecode(await getText('$origin/ping?q=after')) as Map)['q'] ==
          'after',
    );
    check('flutter_main_loop_responsive', beats >= 2);

    // This additive probe uses a fresh own-GIL interpreter and the real
    // requests adapter through an asynchronous, same-process Dart transport.
    // The original retained-source checks above remain unchanged.
    final transportFixture = await PythonTransportFixture.start();
    pythonHttp = transportFixture;
    python.setMethodCallHandler(
      (call) => transportFixture.handle(call, python),
    );
    final beatsBeforeTransport = beats;
    final transportReport = await bridge('transportProbe', {
      'version': 1,
      'origins': transportFixture.origins.map((origin) => '$origin').toList(),
    });
    check('transport_ui_responsive', beats - beatsBeforeTransport >= 2);
    report['transport'] = transportReport;
    if (transportReport['version'] != 1 || transportReport['passed'] != true) {
      throw StateError('Native transport probe did not complete');
    }
    final transportNames = <String>{};
    for (final item in transportReport['checks'] as List) {
      final name = item['name'] as String;
      if (!name.startsWith('transport_') || !transportNames.add(name)) {
        throw StateError('Malformed native transport checks');
      }
      check(name, item['passed'] == true);
    }
    // Allow the deliberately cancelled server responses to finish. Their late
    // callbacks must not change completed calls or store cookies.
    await Future<void>.delayed(const Duration(milliseconds: 900));
    check(
      'transport_native_cancel_ack',
      transportFixture.cancellationRequests == 1 &&
          transportFixture.nativeCancellations == 1,
    );
    check(
      'transport_tasks_drained',
      transportFixture.transport.activeRequestCount == 0,
    );
    check('transport_no_server_errors', transportFixture.failures.isEmpty);
    check(
      'transport_quickjs_survives',
      js.evaluate('++fixtureCount').stringResult == '3',
    );
    check(
      'transport_node_survives',
      (jsonDecode(await getText('$origin/ping?q=transport')) as Map)['q'] ==
          'transport',
    );
    await pythonHttp.close();
    pythonHttp = null;
    await runNativeSourceFixture(python, check, () => beats);
    check(
      'source_quickjs_survives',
      js.evaluate('++fixtureCount').stringResult == '4',
    );
    check(
      'source_node_survives',
      (jsonDecode(await getText('$origin/ping?q=source')) as Map)['q'] ==
          'source',
    );
    report['passed'] = true;
  } catch (error, stack) {
    report['failure'] = error.toString();
    report['stack'] = stack.toString();
  } finally {
    watchdog.cancel();
    heartbeat.cancel();
    python.setMethodCallHandler(null);
    await pythonHttp?.close();
    http.close(force: true);
    js?.dispose();
    report['heartbeat'] = beats;
    if (output != null) await File(output).writeAsString(jsonEncode(report));
  }
}
