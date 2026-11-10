import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  test(
    'Python Session retains scoped cookies through real HTTP redirects',
    () async {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      addTearDown(() => server.close(force: true));
      final base = 'http://127.0.0.1:${server.port}';
      final other = 'http://localhost:${server.port}';
      final observed = <String, Map<String, String>>{};
      server.listen((request) async {
        final response = request.response;
        response.headers.contentType = ContentType.json;
        final label = request.uri.queryParameters['label'] ?? request.uri.path;
        observed[label] = {
          'cookie': request.headers.value('cookie') ?? '',
          'auth': request.headers.value('authorization') ?? '',
          'header': request.headers.value('x-session') ?? '',
        };
        switch (request.uri.path) {
          case '/login':
            response.headers.add(
              'set-cookie',
              'sid=fixture; Path=/auth; HttpOnly',
            );
            response.headers.add(
              'set-cookie',
              'root=all; Path=/; Expires=Wed, 01 Jan 2031 00:00:00 GMT',
            );
            response.headers.add(
              'set-cookie',
              'unrelated=no; Domain=example.test; Path=/',
            );
            response.headers.add('set-cookie', 'secure=no; Secure; Path=/');
          case '/redirect':
            response.statusCode = 302;
            response.headers.set('location', '/auth/resource?label=redirected');
            response.headers.add('set-cookie', 'redirect=kept; Path=/auth');
          case '/cross':
            response.statusCode = 302;
            response.headers.set(
              'location',
              '$other/auth/resource?label=cross',
            );
          case '/expire':
            response.headers.add(
              'set-cookie',
              'sid=gone; Path=/auth; Max-Age=0',
            );
        }
        response.write('{"ok":true}');
        await response.close();
      });
      final client = CmsClient();
      final imported = await client.resolveConfigInput(
        rawTextInput:
            '''
import requests
from requests.cookies import RequestsCookieJar
class Spider:
    def homeContent(self, filter):
        with requests.Session() as s:
            s.headers.update({'X-Session':'active'})
            r = s.get('$base/login')
            assert r.cookies.get('sid') == 'fixture'
            cookie = [c for c in s.cookies if c.name == 'sid'][0]
            assert cookie.value == 'fixture' and cookie.domain == '127.0.0.1'
            assert cookie.path == '/auth' and not cookie.secure and cookie.expires is None
            assert not cookie.domain_specified
            assert dict(r.cookies)['sid'] == 'fixture'
            assert {c.name:c.value for c in s.cookies}['root'] == 'all'
            duplicate = RequestsCookieJar()
            duplicate.set('sid','one',domain='one.example.test',path='/auth',secure=True,expires=1924992000)
            duplicate.set('sid','two',domain='two.example.test',path='/')
            assert [(c.domain,c.path,c.value) for c in duplicate] == [('one.example.test','/auth','one'),('two.example.test','/','two')]
            assert list(duplicate)[0].expires == 1924992000
            copy = duplicate.copy()
            list(copy)[0].value = 'copy-only'
            assert duplicate.get('sid',domain='one.example.test') == 'one'
            s.get('$base/auth/resource', params={'label':'authenticated'})
            s.get('$base/authentic', params={'label':'boundary'})
            requests.Session().get('$base/auth/resource', params={'label':'isolated'})
            redirected = s.get('$base/redirect')
            assert len(redirected.history) == 1
            s.get('$base/cross', headers={'Authorization':'Bearer fixture'}).raise_for_status()
            s.get('$base/expire')
            s.close()
            s.get('$base/auth/resource', params={'label':'closed_reused'})
            s.cookies.clear()
            s.get('$base/auth/resource', params={'label':'cleared'})
            return {'list':[{'vod_id':'session','vod_name':'session ready'}]}
''',
      );
      expect(
        (await client.fetchHome(
          imported.config.sites.single,
        )).$2.videos.single.title,
        'session ready',
      );
      expect(observed['authenticated'], {
        'cookie': 'sid=fixture; root=all',
        'auth': '',
        'header': 'active',
      });
      expect(observed['boundary']!['cookie'], 'root=all');
      expect(observed['isolated']!['cookie'], '');
      expect(
        observed['redirected']!['cookie'],
        'sid=fixture; redirect=kept; root=all',
      );
      expect(observed['cross']!['cookie'], '');
      expect(observed['cross']!['auth'], '');
      expect(observed['closed_reused']!['cookie'], 'redirect=kept; root=all');
      expect(observed['cleared']!['cookie'], '');
    },
  );
}
