import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/models.dart';

void main() {
  Future<HttpServer> server() async {
    final value = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => value.close(force: true));
    return value;
  }

  CmsSite source(Uri address) => CmsSite(
    key: 'redirect',
    name: 'Local fixture',
    type: 1,
    api: address.toString(),
    headers: {
      'Cookie': 'fixture=yes',
      'Proxy-Authorization': 'fixture-proxy',
      'User-Agent': 'Local regression fixture',
    },
  );

  test(
    'Basic auth survives same-origin redirects but never leaves or returns across origins',
    () async {
      final first = await server();
      final second = await server();
      final seen = <String, Map<String, String?>>{};
      Future<void> serve(
        HttpRequest request,
        String name,
        String? redirect,
      ) async {
        seen[name] = {
          'authorization': request.headers.value('authorization'),
          'cookie': request.headers.value('cookie'),
          'proxy-authorization': request.headers.value('proxy-authorization'),
          'user-agent': request.headers.value('user-agent'),
        };
        if (redirect != null) {
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set('location', redirect);
        } else {
          request.response.write(
            '{"list":[{"vod_id":"1","vod_name":"Fixture"}]}',
          );
        }
        await request.response.close();
      }

      first.listen((request) {
        final path = request.uri.path;
        serve(request, path, switch (path) {
          '/start' => '/same',
          '/same' => 'http://127.0.0.1:${second.port}/cross',
          _ => null,
        });
      });
      second.listen(
        (request) =>
            serve(request, '/cross', 'http://127.0.0.1:${first.port}/returned'),
      );
      final address = Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: first.port,
        userInfo: 'fixture:pa%3Ass',
        path: '/start',
      );
      final result = await CmsClient().fetchSearch(source(address), 'Fixture');
      expect(result.videos.single.title, 'Fixture');
      for (final path in ['/start', '/same']) {
        expect(
          seen[path]!['authorization'],
          'Basic ${base64Encode(utf8.encode('fixture:pa:ss'))}',
        );
        expect(seen[path]!['cookie'], 'fixture=yes');
      }
      for (final path in ['/cross', '/returned']) {
        expect(seen[path]!['authorization'], isNull);
        expect(seen[path]!['cookie'], isNull);
        expect(seen[path]!['proxy-authorization'], isNull);
        expect(seen[path]!['user-agent'], 'Local regression fixture');
      }
    },
  );

  test(
    'redirects cannot introduce URL credentials or non-HTTP schemes',
    () async {
      final origin = await server();
      var hits = 0;
      origin.listen((request) async {
        hits++;
        request.response.statusCode = HttpStatus.temporaryRedirect;
        request.response.headers.set(
          'location',
          request.uri.path == '/credentials'
              ? 'http://injected:secret@127.0.0.1:${origin.port}/target'
              : 'file:///fixture.json',
        );
        await request.response.close();
      });
      for (final path in ['/credentials', '/scheme']) {
        await expectLater(
          CmsClient().fetchSearch(
            source(Uri.parse('http://127.0.0.1:${origin.port}$path')),
            'Fixture',
          ),
          throwsFormatException,
        );
      }
      expect(hits, 2);
    },
  );

  test('redirect loops stop after five hops', () async {
    final origin = await server();
    var hits = 0;
    origin.listen((request) async {
      hits++;
      request.response.statusCode = HttpStatus.movedPermanently;
      request.response.headers.set('location', '/loop');
      await request.response.close();
    });
    await expectLater(
      CmsClient().fetchSearch(
        source(Uri.parse('http://127.0.0.1:${origin.port}/loop')),
        'Fixture',
      ),
      throwsFormatException,
    );
    expect(hits, 6);
  });
}
