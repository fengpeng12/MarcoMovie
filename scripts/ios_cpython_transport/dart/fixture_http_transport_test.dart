import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'fixture_http_transport.dart';

final checks = <String, bool>{};
var serial = 0;
String id() => (++serial).toRadixString(16).padLeft(32, '0');
void check(String name, bool value) {
  if (checks.containsKey(name)) throw StateError('Duplicate check: $name');
  checks[name] = value;
  if (!value) throw StateError('Failed: $name');
}

Future<void> rejects(
  String name,
  Future<dynamic> Function() job, [
  String? kind,
]) async {
  Object? failure;
  try {
    await job();
  } catch (error) {
    failure = error;
  }
  check(
    name,
    kind == null
        ? failure is FormatException
        : failure is FixtureTransportException && failure.kind == kind,
  );
}

Map<String, Object?> envelope(
  Uri base,
  String path, {
  String? callId,
  String? requestId,
  String method = 'GET',
  Uint8List? body,
  List<List<String>> headers = const [],
  int budget = 3000,
  int? connect,
  int? read,
}) => {
  'version': 1,
  'callId': callId ?? id(),
  'requestId': requestId ?? id(),
  'url': '$base/$path',
  'method': method,
  'headers': headers,
  'body': body ?? Uint8List(0),
  'connectTimeoutMs': connect ?? budget,
  'readTimeoutMs': read ?? budget,
  'deadlineRemainingMs': budget,
};
bool equalBytes(List<int> a, List<int> b) =>
    a.length == b.length &&
    List.generate(a.length, (i) => a[i] == b[i]).every((v) => v);

Future<void> main(List<String> arguments) async {
  final token = 'd' * 32;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final second = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final origin = Uri.parse('http://127.0.0.1:${server.port}/$token');
  final other = Uri.parse('http://127.0.0.1:${second.port}/$token');
  var hits = 0;
  var otherHits = 0;
  final pending = <String, Completer<void>>{};
  final compressed = Uint8List.fromList(
    gzip.encode(utf8.encode('{"compressed":true}')),
  );
  second.listen((request) async {
    otherHits++;
    await request.drain<void>();
    request.response.write('other');
    await request.response.close();
  });
  server.listen((request) async {
    hits++;
    final path = request.uri.path.split('/').last;
    final body = BytesBuilder();
    try {
      await for (final chunk in request) {
        body.add(chunk);
      }
      if (path.startsWith('wait')) {
        pending.putIfAbsent(path, Completer<void>.new).complete();
        await Future<void>.delayed(const Duration(milliseconds: 400));
        request.response.headers.add(
          'set-cookie',
          'late=must-not-deliver; Path=/',
        );
      }
      switch (path) {
        case 'echo':
          request.response.headers.contentType = ContentType.binary;
          request.response.add(body.takeBytes());
        case 'metadata':
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'method': request.method,
              'body': base64.encode(body.takeBytes()),
              'cookie': request.headers.value('cookie'),
              'authorization': request.headers.value('authorization'),
              'contentType': request.headers.value('content-type'),
            }),
          );
        case 'cookies':
          request.response.headers.add(
            'set-cookie',
            'a=one; Path=/; Expires=Wed, 09 Jun 2038 10:18:14 GMT',
          );
          request.response.headers.add(
            'set-cookie',
            'a=two; Path=/scope; HttpOnly',
          );
          request.response.write('cookies');
        case 'redirect':
          request.response.statusCode = 302;
          request.response.headers.set('location', '$other/metadata');
        case 'gzip':
          request.response.headers.set('content-encoding', 'gzip');
          request.response.add(compressed);
        case 'head':
          request.response.contentLength = 4;
        case 'status':
          request.response.statusCode = 401;
          request.response.headers.set(
            'www-authenticate',
            'Basic realm="owned"',
          );
          request.response.write('unauthorized');
        case 'drip':
          for (var i = 0; i < 20; i++) {
            request.response.add([i]);
            await request.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 30));
          }
        case 'idle':
          request.response.add([1]);
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 400));
          request.response.add([2]);
        case 'large':
          request.response.add(
            Uint8List(FixtureHttpTransport.maxBodyBytes + 1),
          );
        case 'largeHeaders':
          request.response.headers.set('x-large', 'a' * 33000);
        default:
          request.response.write('ok');
      }
      await request.response.close();
    } catch (_) {
      // Expected when the client closes a timed-out/oversized request.
      request.response.close().ignore();
    }
  });
  final transport = FixtureHttpTransport(allowedOrigins: [origin, other]);
  try {
    final bytes = Uint8List.fromList([0, 255, 128, 65]);
    final response = await transport.request(
      envelope(origin, 'echo', method: 'POST', body: bytes),
    );
    check(
      'binary_bytes_exact_roundtrip',
      response['body'] is Uint8List &&
          equalBytes(response['body'] as Uint8List, bytes),
    );
    check(
      'strict_response_eight_fields',
      response.keys.toSet().containsAll({
            'version',
            'callId',
            'requestId',
            'url',
            'status',
            'reason',
            'headers',
            'body',
          }) &&
          response.length == 8,
    );
    for (final item in [
      ('json', '{"name":"中文"}', 'application/json'),
      ('form', 'a=one+two&b=%E4%B8%AD', 'application/x-www-form-urlencoded'),
    ]) {
      final prepared = Uint8List.fromList(utf8.encode(item.$2));
      final result = await transport.request(
        envelope(
          origin,
          'metadata',
          method: 'POST',
          body: prepared,
          headers: [
            ['content-type', item.$3],
          ],
        ),
      );
      final metadata = jsonDecode(utf8.decode(result['body'] as Uint8List));
      check(
        '${item.$1}_prepared_bytes_not_reencoded',
        metadata['body'] == base64.encode(prepared) &&
            metadata['contentType'] == item.$3,
      );
    }
    final cookies = await transport.request(envelope(origin, 'cookies'));
    final pairs = (cookies['headers'] as List)
        .where((p) => p[0] == 'set-cookie')
        .toList();
    check(
      'duplicate_set_cookie_with_expires_preserved',
      pairs.length == 2 &&
          pairs[0][1] ==
              'a=one; Path=/; Expires=Wed, 09 Jun 2038 10:18:14 GMT' &&
          pairs[1][1] == 'a=two; Path=/scope; HttpOnly',
    );
    final absent = await transport.request(envelope(origin, 'metadata'));
    check(
      'no_implicit_cookie_jar',
      jsonDecode(utf8.decode(absent['body'] as Uint8List))['cookie'] == null,
    );
    final explicit = await transport.request(
      envelope(
        origin,
        'metadata',
        headers: [
          ['cookie', 'owned=explicit'],
          ['authorization', 'Bearer fixture'],
        ],
      ),
    );
    final meta = jsonDecode(utf8.decode(explicit['body'] as Uint8List));
    check(
      'explicit_cookie_authorization_preserved',
      meta['cookie'] == 'owned=explicit' &&
          meta['authorization'] == 'Bearer fixture',
    );
    final redirect = await transport.request(envelope(origin, 'redirect'));
    check(
      'one_hop_no_automatic_redirect',
      redirect['status'] == 302 && otherHits == 0,
    );
    final cross = await transport.request(envelope(other, 'metadata'));
    check(
      'second_explicitly_owned_origin_allowed',
      cross['status'] == 200 && otherHits == 1,
    );
    final wire = await transport.request(envelope(origin, 'gzip'));
    check(
      'gzip_wire_bytes_not_decoded',
      equalBytes(wire['body'] as Uint8List, compressed) &&
          (wire['headers'] as List).any(
            (p) => p[0] == 'content-encoding' && p[1] == 'gzip',
          ),
    );
    final head = await transport.request(
      envelope(origin, 'head', method: 'HEAD'),
    );
    check(
      'head_keeps_length_metadata_no_body',
      (head['body'] as Uint8List).isEmpty &&
          (head['headers'] as List).any(
            (p) => p[0] == 'content-length' && p[1] == '4',
          ),
    );
    final previous = hits;
    final denied = await transport.request(envelope(origin, 'status'));
    check(
      'http_error_response_no_auth_retry',
      denied['status'] == 401 && hits == previous + 1,
    );
    final reuse = envelope(origin, 'metadata');
    await transport.request(reuse);
    await rejects('request_id_reuse_rejected', () => transport.request(reuse));
    final sharedCall = id();
    await transport.request(
      envelope(origin, 'metadata', callId: sharedCall, budget: 2000),
    );
    final hop = await transport.request(
      envelope(origin, 'metadata', callId: sharedCall, budget: 1500),
    );
    check(
      'fresh_request_same_call_multihop_allowed',
      hop['callId'] == sharedCall,
    );

    final invalid = <String, Map<String, Object?>>{
      'extra_capability': {...envelope(origin, 'metadata'), 'verify': false},
      'untyped_body': {
        ...envelope(origin, 'echo'),
        'body': <int>[0, 255],
      },
      'oversize_body': envelope(
        origin,
        'echo',
        method: 'POST',
        body: Uint8List(FixtureHttpTransport.maxBodyBytes + 1),
      ),
      'get_body': envelope(origin, 'echo', body: bytes),
      'host_header': envelope(
        origin,
        'metadata',
        headers: [
          ['host', 'other'],
        ],
      ),
      'duplicate_header': envelope(
        origin,
        'metadata',
        headers: [
          ['x-a', '1'],
          ['x-a', '2'],
        ],
      ),
      'header_injection': envelope(
        origin,
        'metadata',
        headers: [
          ['x-a', 'ok\r\nbad'],
        ],
      ),
      'header_unicode': envelope(
        origin,
        'metadata',
        headers: [
          ['x-a', '中'],
        ],
      ),
      'uppercase_header': envelope(
        origin,
        'metadata',
        headers: [
          ['X-A', '1'],
        ],
      ),
      'phase_over_budget': envelope(origin, 'metadata', budget: 20, read: 21),
      'zero_budget': envelope(origin, 'metadata', budget: 0),
      'noninteger_budget': {
        ...envelope(origin, 'metadata'),
        'deadlineRemainingMs': 12.5,
      },
      'bad_identity': {...envelope(origin, 'metadata'), 'callId': 'wrong'},
      'unsupported_method': envelope(origin, 'metadata', method: 'TRACE'),
    };
    final beforeInvalid = hits;
    for (final entry in invalid.entries) {
      await rejects(
        'reject_${entry.key}',
        () => transport.request(entry.value),
      );
    }
    for (final tail in [
      '/$token/../escape',
      '/$token/%2e%2e/escape',
      '/$token/%252e%252e/escape',
      '/$token/%2fescape',
      '/${token}other/metadata',
      '/wrong/metadata',
    ]) {
      await rejects(
        'reject_path_${checks.length}',
        () => transport.request({
          ...envelope(origin, 'metadata'),
          'url': '${origin.origin}$tail',
        }),
      );
    }
    for (final url in [
      'https://127.0.0.1:${server.port}/$token/metadata',
      'http://localhost:${server.port}/$token/metadata',
      'http://user@127.0.0.1:${server.port}/$token/metadata',
      '$origin/metadata#fragment',
      'http://example.invalid/$token/metadata',
    ]) {
      await rejects(
        'reject_url_${checks.length}',
        () => transport.request({...envelope(origin, 'metadata'), 'url': url}),
      );
    }
    check('invalid_inputs_never_reach_server', hits == beforeInvalid);
    await rejects(
      'response_byte_cap',
      () => transport.request(envelope(origin, 'large')),
    );
    await rejects(
      'response_header_profile_cap',
      () => transport.request(envelope(origin, 'largeHeaders')),
    );

    final timer = Stopwatch()..start();
    await rejects(
      'header_wait_timeout',
      () => transport.request(envelope(origin, 'waitHeader', read: 70)),
      'timeout',
    );
    check('header_timeout_closes_promptly', timer.elapsedMilliseconds < 1000);
    await rejects(
      'response_body_idle_timeout',
      () => transport.request(envelope(origin, 'idle', read: 70)),
      'timeout',
    );
    await rejects(
      'drip_total_deadline_not_extended_by_progress',
      () => transport.request(envelope(origin, 'drip', budget: 160, read: 90)),
      'timeout',
    );
    final cancellation = id();
    pending['waitCancel'] = Completer<void>();
    final cancelled = rejects(
      'cancel_inflight_call',
      () => transport.request(
        envelope(origin, 'waitCancel', callId: cancellation),
      ),
      'cancelled',
    );
    await pending['waitCancel']!.future;
    final survivor = transport.request(envelope(origin, 'metadata'));
    transport.cancel(cancellation);
    await cancelled;
    check(
      'cancellation_does_not_close_sibling_client',
      (await survivor)['status'] == 200,
    );
    final concurrentCall = id();
    pending['waitSharedDeadline'] = Completer<void>();
    final concurrentTimer = Stopwatch()..start();
    final firstHop = rejects(
      'same_call_shorter_budget_interrupts_older_hop',
      () => transport.request(
        envelope(origin, 'waitSharedDeadline', callId: concurrentCall),
      ),
      'timeout',
    );
    await pending['waitSharedDeadline']!.future;
    await transport.request(
      envelope(origin, 'metadata', callId: concurrentCall, budget: 60),
    );
    await firstHop;
    check(
      'shared_deadline_shortened_promptly',
      concurrentTimer.elapsedMilliseconds < 300,
    );
    await rejects(
      'cancelled_call_tombstone_rejects_new_hop',
      () =>
          transport.request(envelope(origin, 'metadata', callId: cancellation)),
      'cancelled',
    );
    final early = id();
    transport.cancel(early);
    await rejects(
      'cancel_before_first_request',
      () => transport.request(envelope(origin, 'metadata', callId: early)),
      'cancelled',
    );
    final deadlineCall = id();
    await transport.request(
      envelope(origin, 'metadata', callId: deadlineCall, budget: 120),
    );
    await Future<void>.delayed(const Duration(milliseconds: 160));
    await rejects(
      'call_deadline_cannot_be_reset',
      () =>
          transport.request(envelope(origin, 'metadata', callId: deadlineCall)),
      'timeout',
    );
    await Future<void>.delayed(const Duration(milliseconds: 450));
    check(
      'late_result_no_active_task_or_redelivery',
      transport.activeRequestCount == 0,
    );

    final offline = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final offlineOrigin = Uri.parse('http://127.0.0.1:${offline.port}/$token');
    await offline.close();
    final disconnected = FixtureHttpTransport(allowedOrigins: [offlineOrigin]);
    await rejects(
      'connection_error_has_fixed_kind',
      () => disconnected.request(envelope(offlineOrigin, 'metadata')),
      'connection',
    );
    check(
      'connection_error_releases_task',
      disconnected.activeRequestCount == 0,
    );
    disconnected.close();

    final bounded = FixtureHttpTransport(allowedOrigins: [origin]);
    for (var i = 0; i < FixtureHttpTransport.maxCalls; i++) {
      bounded.cancel(id());
    }
    await rejects(
      'bounded_call_tombstone_capacity',
      () => bounded.request(envelope(origin, 'metadata')),
    );
    bounded.close();
    final requests = FixtureHttpTransport(allowedOrigins: [origin]);
    final lifetime = id();
    for (var i = 0; i < FixtureHttpTransport.maxRequests; i++) {
      await requests.request(
        envelope(origin, 'metadata', callId: lifetime, budget: 45000),
      );
    }
    await rejects(
      'bounded_request_identity_capacity',
      () => requests.request(
        envelope(origin, 'metadata', callId: lifetime, budget: 45000),
      ),
    );
    requests.close();
    final closing = id();
    pending['waitClose'] = Completer<void>();
    final closed = rejects(
      'close_cancels_pending_request',
      () => transport.request(envelope(origin, 'waitClose', callId: closing)),
      'cancelled',
    );
    await pending['waitClose']!.future;
    transport.close();
    transport.close();
    await closed;
    await rejects(
      'closed_transport_cannot_reopen',
      () => transport.request(envelope(origin, 'metadata')),
      'cancelled',
    );
    check('all_completed_tasks_removed', transport.activeRequestCount == 0);
  } finally {
    transport.close();
    await server.close(force: true);
    await second.close(force: true);
  }
  final report = {
    'version': 1,
    'runtime': Platform.version,
    'fixtureOnly': true,
    'checks': checks,
    'count': checks.length,
    'allPassed': checks.values.every((v) => v),
  };
  final encoded = const JsonEncoder.withIndent('  ').convert(report);
  if (arguments.isNotEmpty)
    await File(arguments.single).writeAsString('$encoded\n');
  stdout.writeln(encoded);
}
