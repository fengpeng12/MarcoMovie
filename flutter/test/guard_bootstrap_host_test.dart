import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/catpaw_host.dart';

import 'drpy_host_test.dart' as fixture;

const _rule = "var rule={title:'Fixture',host:'https://fixture.invalid'};";

Future<String> _bootstrap(Directory directory) async {
  final script = await fixture.fixtureBootstrap(directory);
  await File(script).writeAsString(r'''
const fs=require('node:fs'),http=require('node:http'),path=require('node:path'),crypto=require('node:crypto');
const root=process.argv[2],ready=process.argv[3],secret='b'.repeat(64);
const busyCounts=new Map();
const server=http.createServer(async(req,res)=>{
  let raw='';for await(const chunk of req)raw+=chunk;
  if(req.url.endsWith('/api/drpy')) {
    const mode=JSON.parse(raw).args[0];
    res.writeHead(422,{'Content-Type':'application/json'});
    if(mode==='errorhold'){
      res.on('close',()=>{if(!res.writableEnded)fs.writeFileSync(path.join(root,'error-aborted.txt'),'1');});
      res.write('{"error":');fs.writeFileSync(path.join(root,'error-started.txt'),'1');
      await new Promise(resolve=>setTimeout(resolve,200));
      if(!res.destroyed)res.end('"drpy_verification_required"}');return;
    }
    if(mode==='oversized'){res.end('x'.repeat(16385));return;}
    if(mode==='malformed'){res.end('private-error-body');return;}
    res.end(JSON.stringify({error:mode}));return;
  }
  if(req.url.endsWith('/_release')) {res.writeHead(422);res.end('{"error":"drpy_verification_required"}');return;}
  const value=JSON.parse(raw),data=fs.readFileSync(path.join(root,'imports',value.artifactHash+'.jar'));
  fs.appendFileSync(path.join(root,'requests.txt'),JSON.stringify({url:req.url,method:req.method,
    contentType:req.headers['content-type'],authorization:req.headers.authorization||'',body:value,
    hash:crypto.createHash('sha256').update(data).digest('hex')})+'\n');
  res.setHeader('Content-Type','application/json');
  const mode=data.toString();
  if(mode==='hold'){
    res.on('close',()=>{if(!res.writableEnded)fs.writeFileSync(path.join(root,'aborted.txt'),'1');});
    fs.writeFileSync(path.join(root,'started.txt'),'1');
    await new Promise(resolve=>setTimeout(resolve,200));
  }
  if(res.destroyed)return;
  let result={version:1,rule:"var rule={title:'Fixture',host:'https://fixture.invalid'};",origin:'https://fixture.invalid'};
  if(mode.startsWith('busy')){
    const count=(busyCounts.get(mode)||0)+1;busyCounts.set(mode,count);
    fs.writeFileSync(path.join(root,'busy.txt'),String(count));
    if(mode!=='busy'||count<3){res.statusCode=429;result={error:'bootstrap_busy'};}
  }
  if(mode==='userinfo')result.origin='https://user:secret@fixture.invalid';
  if(mode==='file')result.origin='file:///private/source';
  if(mode==='fragment')result.origin+='\u0023fragment';
  if(mode==='wrongversion')result.version=2;
  if(mode==='extra')result.extra='unsupported';
  if(mode==='empty')result.rule='';
  if(mode==='unsupported'){res.statusCode=422;result={error:'guard_artifact_unsupported'};}
  res.end(JSON.stringify(result));
});
server.listen(0,'127.0.0.1',()=>fs.writeFileSync(ready,JSON.stringify({port:server.address().port,secret})));
process.stdin.resume();process.stdin.on('end',()=>server.close());
''');
  return script;
}

Future<void> _waitFor(File file) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!await file.exists()) {
    if (DateTime.now().isAfter(deadline)) throw StateError('fixture deadline');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late Directory directory;
  late CatPawHost host;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('marco-guard-host-');
    final node = (await Process.run('node', [
      '-p',
      'process.execPath',
    ])).stdout.toString().trim();
    host = CatPawHost(
      directory: () async => Directory('${directory.path}/state'),
      executable: node,
      bootstrap: await _bootstrap(directory),
    );
  });
  tearDown(() async {
    await host.close();
    await directory.delete(recursive: true);
  });

  test(
    'stages exact bytes and sends only authenticated artifact identity',
    () async {
      final bytes = [0, 1, 127, 128, 255];
      final hash = sha256.convert(bytes).toString();
      expect(await host.bootstrapGuard(bytes), {
        'version': 1,
        'rule': _rule,
        'origin': 'https://fixture.invalid',
      });
      expect(
        await File('${directory.path}/state/imports/$hash.jar').readAsBytes(),
        bytes,
      );
      final observed =
          jsonDecode(
                (await File(
                  '${directory.path}/state/requests.txt',
                ).readAsLines()).single,
              )
              as Map;
      expect(observed['url'], '/${'b' * 64}/_port-bootstrap');
      expect(observed['method'], 'POST');
      expect(observed['contentType'], startsWith('application/json'));
      expect(observed['authorization'], isEmpty);
      expect(observed['hash'], hash);
      expect(observed['body'], {
        'version': 1,
        'adapter': 'dm84-v1',
        'artifactHash': hash,
      });
      await host.bootstrapGuard(bytes);
      await File('${directory.path}/state/imports/$hash.jar').writeAsBytes([1]);
      await expectLater(host.bootstrapGuard(bytes), throwsFormatException);
      expect(
        await File('${directory.path}/state/requests.txt').readAsLines(),
        hasLength(2),
      );
    },
  );

  test('the same staged artifact can request each explicit adapter', () async {
    final bytes = [0, 1, 255];
    await host.bootstrapGuard(bytes);
    await host.bootstrapGuard(bytes, adapter: 'auete-v1');
    await host.bootstrapGuard(bytes, adapter: 'bttwoo-v1');
    final requests =
        (await File('${directory.path}/state/requests.txt').readAsLines())
            .map((line) => (jsonDecode(line) as Map)['body'] as Map)
            .toList();
    expect(requests.map((body) => body['adapter']), [
      'dm84-v1',
      'auete-v1',
      'bttwoo-v1',
    ]);
    expect(requests[0]['artifactHash'], requests[1]['artifactHash']);
    expect(requests[0]['artifactHash'], requests[2]['artifactHash']);
    expect(await Directory('${directory.path}/state/imports').list().length, 1);
  });

  test('only T4 forwards a bounded extension to the local bootstrap', () async {
    await host.bootstrapGuard(
      [0, 1, 255],
      adapter: 't4-v1',
      extension: 'ZmFrZQ==',
    );
    final requests = await File(
      '${directory.path}/state/requests.txt',
    ).readAsLines();
    final body = (jsonDecode(requests.single) as Map)['body'] as Map;
    expect(body['adapter'], 't4-v1');
    expect(body['extension'], 'ZmFrZQ==');
    expect(body.keys.toSet(), {
      'version',
      'adapter',
      'artifactHash',
      'extension',
    });
    for (final invalid in [null, '', '汉' * 6000]) {
      await expectLater(
        host.bootstrapGuard([1], adapter: 't4-v1', extension: invalid),
        throwsFormatException,
      );
    }
    await expectLater(
      host.bootstrapGuard([1], extension: 'ZmFrZQ=='),
      throwsFormatException,
    );
    expect(
      await File('${directory.path}/state/requests.txt').readAsLines(),
      hasLength(1),
    );
  });

  test(
    'invalid adapter and input are rejected before starting the host',
    () async {
      for (final bytes in [
        <int>[],
        [-1],
        [256],
        List<int>.filled(16 * 1024 * 1024 + 1, 0),
      ]) {
        await expectLater(host.bootstrapGuard(bytes), throwsFormatException);
      }
      await expectLater(
        host.bootstrapGuard([1], adapter: '../other'),
        throwsFormatException,
      );
      await expectLater(
        host.bootstrapGuard([1], adapter: 'auete-v2'),
        throwsFormatException,
      );
      await expectLater(
        host.bootstrapGuard([1], adapter: 'bttwoo-v2'),
        throwsFormatException,
      );
      expect(await Directory('${directory.path}/state').exists(), isFalse);
    },
  );

  test(
    'rejects malformed outputs and reports an unsupported artifact explicitly',
    () async {
      for (final mode in [
        'userinfo',
        'file',
        'fragment',
        'wrongversion',
        'extra',
        'empty',
      ]) {
        await expectLater(
          host.bootstrapGuard(utf8.encode(mode)),
          throwsFormatException,
          reason: mode,
        );
      }
      await expectLater(
        host.bootstrapGuard(utf8.encode('unsupported')),
        throwsA(
          isA<GuardBootstrapException>().having(
            (e) => e.code,
            'code',
            'guard_artifact_unsupported',
          ),
        ),
      );
    },
  );

  test(
    'busy bootstrap retries are bounded and only retry the transient code',
    () async {
      expect((await host.bootstrapGuard(utf8.encode('busy')))['rule'], _rule);
      expect(
        await File('${directory.path}/state/requests.txt').readAsLines(),
        hasLength(3),
      );
      final timer = Stopwatch()..start();
      await expectLater(
        host.bootstrapGuard(utf8.encode('busyforever')),
        throwsA(
          isA<GuardBootstrapException>().having(
            (e) => e.code,
            'code',
            'bootstrap_busy',
          ),
        ),
      );
      expect(timer.elapsed, greaterThanOrEqualTo(const Duration(seconds: 2)));
      expect(timer.elapsed, lessThan(const Duration(seconds: 5)));
      expect(
        (await File(
          '${directory.path}/state/requests.txt',
        ).readAsLines()).length,
        lessThan(20),
      );
    },
  );

  test('cancellation interrupts busy backoff without a late retry', () async {
    final cancellation = Completer<void>();
    final call = host.bootstrapGuard(
      utf8.encode('busyforever'),
      cancellation: cancellation,
    );
    final check = expectLater(call, throwsFormatException);
    await _waitFor(File('${directory.path}/state/busy.txt'));
    cancellation.complete();
    await check;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(
      await File('${directory.path}/state/requests.txt').readAsLines(),
      hasLength(1),
    );
  });

  test(
    'cancellation before or during staging never invokes the extractor',
    () async {
      final cancelled = Completer<void>()..complete();
      await expectLater(
        host.bootstrapGuard([1], cancellation: cancelled),
        throwsFormatException,
      );
      expect(await Directory('${directory.path}/state').exists(), isFalse);
      final waiting = Completer<Directory>();
      final started = Completer<void>();
      final delayed = CatPawHost(
        directory: () {
          started.complete();
          return waiting.future;
        },
      );
      final cancellation = Completer<void>();
      final call = delayed.bootstrapGuard([1], cancellation: cancellation);
      final check = expectLater(call, throwsFormatException);
      await started.future;
      cancellation.complete();
      await check;
      waiting.complete(Directory('${directory.path}/delayed'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        await File('${directory.path}/delayed/ready.json').exists(),
        isFalse,
      );
      expect(
        await Directory('${directory.path}/delayed/imports').exists(),
        isFalse,
      );
      await delayed.close();
    },
  );

  test(
    'cancellation closes the in-flight request and subsequent calls work',
    () async {
      final cancellation = Completer<void>();
      final call = host.bootstrapGuard(
        utf8.encode('hold'),
        cancellation: cancellation,
      );
      final check = expectLater(call, throwsFormatException);
      await _waitFor(File('${directory.path}/state/started.txt'));
      cancellation.complete();
      await check;
      await _waitFor(File('${directory.path}/state/aborted.txt'));
      expect((await host.bootstrapGuard([42]))['rule'], _rule);
    },
  );

  test(
    'DRPY 422 errors are typed, bounded and hide unknown response content',
    () async {
      final address = await host.installDrpy(fixture.manifest());
      await expectLater(
        host.callDrpy(address, 'search', ['drpy_verification_required']),
        throwsA(
          isA<DrpySourceException>()
              .having((e) => e.code, 'code', 'drpy_verification_required')
              .having((e) => e.message, 'message', '此片源需要完成网站验证码，暂时无法加载'),
        ),
      );
      await expectLater(
        host.callDrpy(address, 'play', ['drpy_local_proxy_not_supported']),
        throwsA(
          isA<DrpySourceException>().having(
            (e) => e.code,
            'code',
            'drpy_local_proxy_not_supported',
          ),
        ),
      );
      await expectLater(
        host.callDrpy(address, 'category', ['drpy_filter_not_supported']),
        throwsA(
          isA<DrpySourceException>()
              .having((e) => e.code, 'code', 'drpy_filter_not_supported')
              .having((e) => e.message, 'message', '此片源不支持当前筛选条件'),
        ),
      );
      for (final mode in ['private-error-body', 'malformed']) {
        await expectLater(
          host.callDrpy(address, 'search', [mode]),
          throwsA(
            allOf(
              isNot(isA<DrpySourceException>()),
              predicate(
                (Object e) => !e.toString().contains('private-error-body'),
              ),
            ),
          ),
        );
      }
      await expectLater(
        host.callDrpy(address, 'search', ['oversized']),
        throwsFormatException,
      );
      await expectLater(
        host.read(
          address.replaceFirst('/api/drpy', '/_release'),
          method: 'POST',
        ),
        throwsA(isNot(isA<DrpySourceException>())),
      );
    },
  );

  test(
    'cancellation still closes a partially received DRPY error body',
    () async {
      final address = await host.installDrpy(fixture.manifest());
      final cancellation = Completer<void>();
      final call = host.callDrpy(address, 'search', [
        'errorhold',
      ], cancellation: cancellation);
      final check = expectLater(
        call,
        throwsA(
          isA<FormatException>().having((e) => e.message, 'message', '搜索已取消'),
        ),
      );
      await _waitFor(File('${directory.path}/state/error-started.txt'));
      cancellation.complete();
      await check;
      await _waitFor(File('${directory.path}/state/error-aborted.txt'));
    },
  );

  test(
    'pinned real router rejects an unreviewed artifact with the typed code',
    () async {
      await host.close();
      final node = (await Process.run('node', [
        '-p',
        'process.execPath',
      ])).stdout.toString().trim();
      host = CatPawHost(
        directory: () async => Directory('${directory.path}/real'),
        executable: node,
        bootstrap: '${Directory.current.path}/assets/catpaw/host.cjs',
      );
      final bytes = utf8.encode('Synthetic unknown plugin, never executed.');
      for (final adapter in ['dm84-v1', 'auete-v1', 'bttwoo-v1']) {
        await expectLater(
          host.bootstrapGuard(bytes, adapter: adapter),
          throwsA(
            isA<GuardBootstrapException>().having(
              (e) => e.code,
              'code',
              'guard_artifact_unsupported',
            ),
          ),
        );
      }
      final hash = sha256.convert(bytes).toString();
      expect(
        await File('${directory.path}/real/imports/$hash.jar').readAsBytes(),
        bytes,
      );
      expect(
        await File('${directory.path}/real/drpy-bootstrap-worker.cjs').exists(),
        isTrue,
      );
    },
  );
}
