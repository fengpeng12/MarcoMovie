import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/js_source_host.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  test(
    'real JS HTTP keeps same-origin auth and strips it across origin changes',
    () async {
      final first = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final second = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => first.close(force: true));
      addTearDown(() => second.close(force: true));
      final base = 'http://127.0.0.1:${first.port}';
      final other = 'http://127.0.0.1:${second.port}';
      void listen(HttpServer server) {
        server.listen((request) async {
          final body = await utf8.decoder.bind(request).join();
          final response = request.response;
          final path = request.uri.path;
          final location = switch (path) {
            '/same' => '/echo',
            '/cross' => '$other/echo',
            '/roundtrip' => '$other/back',
            '/back' => '$base/echo',
            '/post' || '/keep' => '/echo',
            '/loop' => '/loop',
            _ => null,
          };
          if (location != null) {
            response.statusCode = path == '/keep'
                ? 307
                : path == '/post'
                ? 303
                : 302;
            response.headers.set('location', location);
          }
          response.headers.contentType = ContentType.json;
          response.write(
            jsonEncode({
              'auth': request.headers.value('authorization'),
              'cookie': request.headers.value('cookie'),
              'cookie2': request.headers.value('cookie2'),
              'proxy': request.headers.value('proxy-authorization'),
              'custom': request.headers.value('x-fixture'),
              'method': request.method,
              'body': body,
            }),
          );
          await response.close();
        });
      }

      listen(first);
      listen(second);

      Future<Map<String, dynamic>> invoke(
        String url, [
        Map<String, Object?> options = const {},
      ]) async {
        const entry = 'pkg://fixture/source.js';
        return jsonDecode(
              await JsSourceHost.invoke(
                entry: entry,
                modules: {
                  entry:
                      'export async function home(){return await req(${jsonEncode(url)},${jsonEncode(options)});}',
                },
                method: 'home',
                arguments: [],
              ),
            )
            as Map<String, dynamic>;
      }

      final options = <String, Object?>{
        'headers': {
          'aUtHoRiZaTiOn': 'Basic fixture',
          'CoOkIe': 'sid=fixture',
          'Cookie2': 'legacy=fixture',
          'Proxy-Authorization': 'Basic proxy',
          'X-Fixture': 'preserved',
        },
      };
      final same = jsonDecode(
        (await invoke('$base/same', options))['content'] as String,
      );
      expect(same['auth'], 'Basic fixture');
      expect(same['cookie'], 'sid=fixture');
      for (final path in ['/cross', '/roundtrip']) {
        final response = await invoke('$base$path', options);
        final received = jsonDecode(response['content'] as String);
        expect(received['auth'], isNull);
        expect(received['cookie'], isNull);
        expect(received['cookie2'], isNull);
        expect(received['proxy'], isNull);
        expect(received['custom'], 'preserved');
      }
      final credentialUrl = Uri.parse(
        '$base/same',
      ).replace(userInfo: 'user:p%40ss').toString();
      final authenticated = await invoke(credentialUrl);
      expect(
        jsonDecode(authenticated['content'] as String)['auth'],
        'Basic ${base64Encode(utf8.encode('user:p@ss'))}',
      );
      expect(authenticated['url'], '$base/echo');
      final manual = await invoke('$base/cross', {...options, 'redirect': 0});
      expect(manual['code'], 302);
      expect(manual['url'], '$base/cross');

      final post = jsonDecode(
        (await invoke('$base/post', {
              'method': 'POST',
              'body': '中文',
            }))['content']
            as String,
      );
      expect(post['method'], 'GET');
      expect(post['body'], isEmpty);
      final keep = jsonDecode(
        (await invoke('$base/keep', {'method': 'PUT', 'body': '中文'}))['content']
            as String,
      );
      expect(keep['method'], 'PUT');
      expect(keep['body'], '中文');
      await expectLater(
        invoke('$base/loop'),
        throwsA(predicate((e) => e.toString().contains('重定向过多'))),
      );
    },
  );
}
