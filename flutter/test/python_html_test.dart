import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/js_source_host.dart';
import 'package:marco_movie/core/python_source_assets.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  tearDown(() => CmsClient.closeScriptSessions());

  test(
    'Python substitutions preserve backreferences and expose unsupported cases',
    () async {
      const entry = 'pkg://fixture/sub.py';
      final actual = jsonDecode(
        await JsSourceHost.invoke(
          entry: entry,
          pythonPrelude: await loadPythonSourcePrelude(),
          method: 'home',
          arguments: [true],
          modules: {
            entry: r'''
import re
class Spider:
    def homeContent(self, filter):
        result = {'line':re.sub(r'[#\s]+', ' ', '## A\t 线').strip(), 'object':re.sub(r'([{,]\s*)(\w+)\s*:', r'\1"\2":', '{name:1, 中文:2}'), 'count':re.subn('a', 'x', 'aba')}
        errors = []
        for item in range(8):
            try:
                if item == 0: re.sub('(', '', 'x')
                if item == 1: re.sub('(a)', r'\2', 'a')
                if item == 2: re.sub('^', 'x', 'a')
                if item == 3: re.sub('a', lambda m: 'x', 'a')
                if item == 4: re.sub('a', 'x' * 65536, 'a' * 33)
                if item == 5: re.sub('a', 'x', 'a', flags=4294967298)
                if item == 6: re.sub(r'(?P<name>a)', 'x', 'a')
                if item == 7: re.sub('a', r'\q', 'a')
            except (ValueError, TypeError, NotImplementedError): errors.append(item)
        result['errors'] = errors
        return result
''',
          },
        ),
      );
      expect(actual, {
        'line': 'A 线',
        'object': '{"name":1, "中文":2}',
        'count': ['xbx', 2],
        'errors': [0, 1, 2, 3, 4, 5, 6, 7],
      });
    },
  );

  test(
    'Python HTML catalogue, detail and play use the production local parser',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final origin = 'http://127.0.0.1:${server.port}';
      server.listen((request) async {
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          request.uri.path == '/catalog'
              ? '<div class="slide"><a href="/detail"> One &amp; <em>二</em> </a><img data-src="/cover.jpg"></div><div class="slide duplicate"><a href="/bad">duplicate</a></div>'
              : '<h1> One &amp; 二 </h1><p class="description">剧情 <b>中文</b></p><ol><li><a href="/media.mp4?one=1&amp;two=2">正片</a></li></ol>',
        );
        await request.response.close();
      });
      final client = CmsClient();
      final imported = await client.resolveConfigInput(
        rawTextInput:
            '''
from bs4 import BeautifulSoup
from urllib.parse import urljoin
from base.spider import Spider as Base
class Spider(Base):
    def homeContent(self, filter):
        self.soup = BeautifulSoup(self.fetch('$origin/catalog').text, 'html.parser')
        nodes = self.soup.select('.slide:not(.duplicate) a')
        return {'list':[{'vod_id':urljoin('$origin', n.get('href')), 'vod_name':n.get_text(' ', strip=True)} for n in nodes]}
    def detailContent(self, ids):
        assert self.soup.select_one('.slide img').get('data-src') == '/cover.jpg'
        doc = BeautifulSoup(self.fetch(ids[0]).text, 'html.parser')
        self.link = doc.select_one('ol > li a')
        return {'list':[{'vod_id':ids[0], 'vod_name':doc.select_one('h1').get_text(strip=True), 'vod_content':doc.select_one('.description').get_text(' ', strip=True), 'vod_play_from':'Local', 'vod_play_url':self.link.text + '\$' + urljoin('$origin', self.link.get('href'))}]}
    def playerContent(self, flag, id, vip):
        assert self.link.get('href') == '/media.mp4?one=1&two=2'
        return {'url':id, 'header':{'Referer':'$origin/'}}
''',
      );
      final site = imported.config.sites.single;
      final video = (await client.fetchHome(site)).$2.videos.single;
      expect(video.title, 'One & 二');
      final detail = await client.fetchDetail(site, video);
      expect(detail.lines.single.episodes.single.name, '正片');
      final play = await CmsClient().resolveEpisodeForPlayback(
        site,
        detail.lines.single.episodes.single,
      );
      expect(play.url, '$origin/media.mp4?one=1&two=2');
      expect(play.headers['Referer'], '$origin/');
    },
  );

  test(
    'HTML nodes stay source-local and unsupported parser features fail clearly',
    () async {
      final prelude = await loadPythonSourcePrelude();
      const entry = 'pkg://fixture/limited.py';
      final result = jsonDecode(
        await JsSourceHost.invoke(
          entry: entry,
          pythonPrelude: prelude,
          method: 'home',
          arguments: [true],
          modules: {
            entry: '''
from bs4 import BeautifulSoup
class Spider:
    def homeContent(self, filter):
        first = BeautifulSoup('<p>one &amp; 二</p>', 'html.parser').select_one('p')
        second = BeautifulSoup('<p>other</p>', 'html.parser').select_one('p')
        errors = []
        try: BeautifulSoup('<p>x</p>', 'lxml')
        except NotImplementedError: errors.append('parser')
        try: first.select('[')
        except ValueError: errors.append('selector')
        try: first.find('p')
        except AttributeError: errors.append('method')
        try: BeautifulSoup('x' * (2 * 1024 * 1024 + 1), 'html.parser')
        except ValueError: errors.append('size')
        return {'first':first.text, 'second':second.text, 'errors':errors}
''',
          },
        ),
      );
      expect(result, {
        'first': 'one & 二',
        'second': 'other',
        'errors': ['parser', 'selector', 'method', 'size'],
      });
    },
  );
}
