import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  test(
    'Python byte and URL codecs survive real HTTP catalogue to playback',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final base = 'http://127.0.0.1:${server.port}';
      final observed = <String, Object?>{};
      server.listen((request) async {
        final response = request.response;
        switch (request.uri.path) {
          case '/catalog':
            observed['query'] = request.uri.queryParametersAll;
            response.headers.contentType = ContentType.json;
            response.write('{"ok":true}');
          case '/binary':
            response.headers.contentType = ContentType.binary;
            response.add([0, 255, 128, 1]);
          case '/find':
            observed['form'] = await utf8.decoder.bind(request).join();
            observed['contentType'] = request.headers.value('content-type');
            response.write(
              '{"list":[{"vod_id":"42","vod_name":"Python bytes"}]}',
            );
          case '/resolve':
            observed['body'] = jsonDecode(
              await utf8.decoder.bind(request).join(),
            );
            observed['authorization'] = request.headers.value('authorization');
            observed['cookie'] = request.headers.value('cookie');
            response.write(
              jsonEncode({
                'url': '$base/media.mp4',
                'header': {'Referer': '$base/'},
              }),
            );
          default:
            response.statusCode = 404;
        }
        await response.close();
      });
      final client = CmsClient();
      final imported = await client.resolveConfigInput(
        rawTextInput:
            '''
import base64, requests
from urllib.parse import quote, unquote, urljoin, urlparse, parse_qs
from base.spider import Spider as Base
class Spider(Base):
    def homeContent(self, filter):
        r = self.fetch('$base/catalog#f', params=[('q',['中文 a','two']),('empty',None)], timeout=2, allow_redirects=False)
        r.raise_for_status()
        if r.headers['Content-Type'].split(';')[0] != 'application/json': raise ValueError('header')
        binary = self.fetch('$base/binary').content
        if list(base64.urlsafe_b64decode('AP-AAQ==')) != list(binary): raise ValueError('binary')
        u = urlparse('https://user:pass@[::1]:8443/a;p?x=1#f')
        if u.hostname != '::1' or u.port != 8443: raise ValueError('parse')
        if urljoin('$base/a/b', '../../') != '$base/': raise ValueError('join')
        if parse_qs('q=a+b&q=c')['q'] != ['a b','c']: raise ValueError('query')
        return {'list':[{'vod_id':quote('asset/1', safe=''), 'vod_name':base64.urlsafe_b64encode(binary).decode('ascii')}]}
    def searchContent(self, key, quick, pg='1'):
        return self.post('$base/find', data=[('wd',key),('pg',pg),('format',['mp4','mkv'])], headers={'content-type':'application/custom-form'}).json()
    def detailContent(self, ids):
        return {'list':[{'vod_id':ids[0], 'vod_name':'Python bytes', 'vod_play_from':'A', 'vod_play_url':'正片\$asset%2F1'}]}
    def playerContent(self, flag, id, vip):
        return requests.post('$base/resolve', json={'id':unquote(id),'title':'中文'}, cookies={'session':'fixture'}, auth=('fixture','secret')).json()
''',
      );
      final site = imported.config.sites.single;
      final home = (await client.fetchHome(site)).$2.videos.single;
      expect(home.id, 'asset%2F1');
      expect(home.title, 'AP-AAQ==');
      expect(observed['query'], {
        'q': ['中文 a', 'two'],
      });
      final found = (await client.fetchSearch(
        site,
        'keyword with space',
        page: 3,
      )).videos.single;
      expect(
        observed['form'],
        'wd=keyword+with+space&pg=3&format=mp4&format=mkv',
      );
      expect(observed['contentType'], 'application/custom-form');
      final detail = await client.fetchDetail(site, found);
      final playback = await client.resolveEpisodeForPlayback(
        site,
        detail.lines.single.episodes.single,
      );
      expect(playback.url, '$base/media.mp4');
      expect(playback.headers['Referer'], '$base/');
      expect(observed['body'], {'id': 'asset/1', 'title': '中文'});
      expect(observed['authorization'], 'Basic Zml4dHVyZTpzZWNyZXQ=');
      expect(observed['cookie'], 'session=fixture');
    },
  );

  test(
    'Python can catch HTTP and malformed JSON errors from the real host',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.statusCode = 404;
        request.response.write('missing');
        await request.response.close();
      });
      final client = CmsClient();
      final imported = await client.resolveConfigInput(
        rawTextInput:
            '''
import requests, json, base64
from requests.exceptions import HTTPError
class Spider:
    def homeContent(self, filter):
        errors = []
        try: requests.get('http://127.0.0.1:${server.port}/missing').raise_for_status()
        except HTTPError: errors.append('http')
        try: json.loads('not JSON')
        except ValueError: errors.append('json')
        try: base64.b64decode('YQ')
        except ValueError: errors.append('padding')
        return {'list':[{'vod_id':'1','vod_name':','.join(errors)}]}
''',
      );
      expect(
        (await client.fetchHome(
          imported.config.sites.single,
        )).$2.videos.single.title,
        'http,json,padding',
      );
    },
  );
}
