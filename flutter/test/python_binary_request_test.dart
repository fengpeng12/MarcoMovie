import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/js_source_host.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  test(
    'Python binary uploads preserve bytes, redirects and session boundaries',
    () async {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      addTearDown(() => server.close(force: true));
      final base = 'http://127.0.0.1:${server.port}';
      final observed = <String, Map<String, Object?>>{};
      server.listen((request) async {
        final bytes = await request.fold<List<int>>(
          [],
          (all, part) => all..addAll(part),
        );
        observed[request.uri.path] = {
          'method': request.method,
          'bytes': bytes,
          'contentType': request.headers.value('content-type'),
          'authorization': request.headers.value('authorization'),
          'cookie': request.headers.value('cookie'),
        };
        final response = request.response;
        if (request.uri.path == '/redirect-307') {
          response.statusCode = 307;
          response.headers.set('location', '/after-307');
        } else if (request.uri.path == '/redirect-303') {
          response.statusCode = 303;
          response.headers.set('location', '/after-303');
        } else if (request.uri.path == '/cross-307') {
          response.statusCode = 307;
          response.headers.set(
            'location',
            'http://localhost:${server.port}/after-cross',
          );
        }
        response.write(jsonEncode({'bytes': bytes}));
        await response.close();
      });
      final client = CmsClient();
      final imported = await client.resolveConfigInput(
        rawTextInput:
            '''
import requests
class Spider:
    def homeContent(self, filter):
        data = bytes([0,255,128,65])
        headers = {'Content-Type':'application/octet-stream'}
        assert requests.post('$base/upload',data=data,headers=headers).json()['bytes'] == list(data)
        assert requests.post('$base/empty',data=b'').json()['bytes'] == []
        s = requests.Session()
        assert s.post('$base/redirect-307',data=data,headers=headers).json()['bytes'] == list(data)
        assert requests.post('$base/redirect-303',data=data,headers=headers).json()['bytes'] == []
        s.cookies.set('local','secret',domain='127.0.0.1')
        result = s.post('$base/cross-307',data=data,headers={'Authorization':'Bearer fixture'})
        assert result.json()['bytes'] == list(data)
        return {'list':[{'vod_id':'bytes','vod_name':'binary upload ready'}]}
''',
      );
      expect(
        (await client.fetchHome(
          imported.config.sites.single,
        )).$2.videos.single.title,
        'binary upload ready',
      );
      for (final path in [
        '/upload',
        '/redirect-307',
        '/after-307',
        '/cross-307',
        '/after-cross',
      ]) {
        expect(observed[path]!['method'], 'POST', reason: path);
        expect(observed[path]!['bytes'], [0, 255, 128, 65], reason: path);
      }
      expect(observed['/upload']!['contentType'], 'application/octet-stream');
      expect(observed['/empty']!['bytes'], isEmpty);
      expect(observed['/after-303']!['method'], 'GET');
      expect(observed['/after-303']!['bytes'], isEmpty);
      expect(observed['/after-303']!['contentType'], isNull);
      expect(observed['/cross-307']!['authorization'], 'Bearer fixture');
      expect(observed['/cross-307']!['cookie'], 'local=secret');
      expect(observed['/after-cross']!['authorization'], isNull);
      expect(observed['/after-cross']!['cookie'], isNull);
    },
  );

  test(
    'Binary bridge rejects ambiguous and noncanonical bodies before HTTP',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var requests = 0;
      server.listen((request) async {
        requests++;
        await request.response.close();
      });
      final entry = 'http://127.0.0.1:${server.port}/fixture.js';
      final source =
          '''
module.exports = { async home() {
  const bad = [
    {bodyBase64:'%%%='}, {bodyBase64:'AP+AQQ'}, {bodyBase64:'AP_AQQ=='},
    {bodyBase64:'AR=='}, {bodyBase64:'AA==\\n'}, {bodyBase64:[]},
    {bodyBase64:'AA==',data:'text'}, {bodyBase64:'AA==',body:null}
  ];
  let rejected = 0;
  for (const options of bad) {
    try { await req('$entry', {...options,method:'POST'}); }
    catch (_) { rejected++; }
  }
  return {rejected};
} };
''';
      final result = await JsSourceHost.invoke(
        entry: entry,
        modules: {entry: source},
        method: 'home',
        arguments: [],
      );
      expect(jsonDecode(result), {'rejected': 8});
      expect(requests, 0);
    },
  );
}
