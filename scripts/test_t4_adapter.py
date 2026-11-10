"""Synthetic T4 protocol checks through the actual isolated DRPY host/router."""
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit, unquote
import hashlib
import http.client
import json
import os
import shutil
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
NODE = os.environ.get('MARCOMOVIE_NODE') or shutil.which('node')

class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        path = urlsplit(self.path)
        params = parse_qs(path.query, keep_blank_values=True)
        self.server.requests.append({'path': path.path, 'params': params, 'headers': dict(self.headers)})
        status = 200
        first = {'vod_id': 'id$@@/#&=?', 'vod_name': 'Fixture 电影', 'vod_pic': '/poster.jpg',
                 'type_id': '1', 'vod_play_from': 'Line$$$Second',
                 'vod_play_url': 'One$/media.m3u8?x=1$$$Two$opaque$@@/#',
                 'vod_content': '<p>Synopsis <b>text</b></p>'}
        doc = {'code': 1, 'page': '3', 'pagecount': '4', 'limit': '2', 'total': '8', 'list': [first]}
        kind = params.get('t', [''])[0]
        if path.path == '/bad-home':
            doc = '<html>Service failed</html>'
        elif path.path == '/parse':
            doc = {'url': self.server.origin + '/media.m3u8', 'header': {'Referer': self.server.origin + '/watch'}}
        elif path.path.startswith('/web/'):
            keyword = unquote(path.path.split('/wd/', 1)[1][:-5])
            if keyword == 'verify':
                doc = '<html><body>系统安全验证<input name="verify"></body></html>'
            elif keyword == 'empty':
                doc = '<html><body>暂无相关结果</body></html>'
            elif keyword == 'broken':
                doc = '<html><body>Maintenance</body></html>'
            else:
                doc = '<a href="/index.php/vod/detail/id/123.html">Fixture 电影</a>'
        elif 'play' in params:
            if params['play'][0] == 'bad-media':
                doc = {'url': 'javascript:alert(1)'}
            else:
                doc = {'url': '/media.m3u8', 'parse': 0, 'header': json.dumps({'X-Playback': 'explicit', 'Authorization': 'Explicit fixture', 'Host': 'discard'})}
        elif kind == 'down':
            status = 503
            doc = {'list': []}
        elif kind == 'captcha':
            doc = '<html><body>Checking your browser</body></html>'
        elif kind == 'broken':
            doc = '<html>Maintenance</html>'
        elif kind == 'code0':
            doc = {'code': 0, 'msg': 'failed', 'list': []}
        elif kind == 'shape':
            doc = {'code': 1, 'list': None}
        elif kind == 'empty':
            doc.update(page=4, list=[], total=6)
        elif 'ids' in params:
            first['vod_id'] = params['ids'][0]
        elif 'wd' in params:
            if params['wd'][0] == 'empty':
                doc['list'] = []
            else:
                first['vod_name'] = params['wd'][0]
        elif 'ac' not in params:
            doc.update({'class': [{'type_id': 1, 'type_name': '电影'}, {'type_id': 2, 'type_name': '剧集'}, {'type_id': 3, 'type_name': '排除'}],
                        'filters': {'1': [{'key': 'year', 'name': 'Year', 'value': [{'n': '2026', 'v': '2026'}]}]}})
        body = doc if isinstance(doc, str) else json.dumps(doc, ensure_ascii=False)
        data = body.encode('utf-8')
        self.send_response(status)
        # Actual CMS endpoints can serve JSON with this MIME.
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

class T4HostChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name)
        cls.server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
        cls.server.daemon_threads = True
        cls.server.origin = 'http://127.0.0.1:' + str(cls.server.server_port)
        cls.server.requests = []
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.ready = cls.root / 'ready.json'
        cls.process = subprocess.Popen([NODE, '--jitless', str(ROOT / 'shared/catpaw/host.cjs'), str(cls.root), str(cls.ready)], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        end = time.monotonic() + 10
        while not cls.ready.exists():
            if cls.process.poll() is not None or time.monotonic() > end:
                raise AssertionError('Host failed to start')
            time.sleep(.02)
        cls.state = json.loads(cls.ready.read_text())
        cls.counter = 0

    @classmethod
    def tearDownClass(cls):
        cls.process.stdin.close()
        cls.process.wait(timeout=8)
        cls.server.shutdown()
        cls.server.server_close()
        cls.temp.cleanup()

    def setUp(self):
        self.server.requests.clear()

    def install(self, **changes):
        origin = self.server.origin
        config = {'origin': origin, 'api': origin + '/cms?token=fixture', 'type': 1,
                  'categories': None, 'excludedCategories': None, 'searchBase': '', 'playUrl': '', 'userAgent': 'Fixture-UA'}
        config.update(changes)
        js = 'console.log(JSON.stringify(require(process.argv[1])(JSON.parse(process.argv[2]))))'
        rule = json.loads(subprocess.check_output([NODE, '--jitless', '-e', js, str(ROOT / 'shared/catpaw/drpy-t4-adapter.cjs'), json.dumps(config)], stderr=subprocess.DEVNULL))
        type(self).counter += 1
        identity = hashlib.sha256(str(type(self).counter).encode()).hexdigest()
        manifest = {'kind': 'drpy', 'version': 1, 'runtime': 'drpy2-ca23ffdb-1', 'sourceId': identity,
                    'origin': origin + '/rule.js', 'rule': rule, 'headers': {'Authorization': 'Inherited fixture'}, 'requestTimeoutMs': 2000}
        raw = json.dumps(manifest).encode()
        digest = hashlib.sha256(raw).hexdigest()
        (self.root / digest).mkdir()
        (self.root / digest / 'drpy.json').write_bytes(raw)
        self.addCleanup(self.release, digest)
        return digest

    def release(self, digest):
        c = http.client.HTTPConnection('127.0.0.1', self.state['port'], timeout=8)
        c.request('POST', '/' + self.state['secret'] + '/' + digest + '/_release')
        c.getresponse().read()
        c.close()

    def call(self, digest, method, args, expected=200):
        c = http.client.HTTPConnection('127.0.0.1', self.state['port'], timeout=10)
        c.request('POST', '/' + self.state['secret'] + '/' + digest + '/api/drpy', json.dumps({'version': 1, 'method': method, 'args': args}))
        r = c.getresponse()
        value = json.loads(r.read())
        self.assertEqual(r.status, expected, value)
        c.close()
        return value

    def test_six_methods_real_pagination_and_opaque_ids(self):
        source = self.install()
        home = self.call(source, 'home', [True])
        self.assertEqual(len(home['class']), 3)
        self.assertEqual(home['filters'], {})
        count = len(self.server.requests)
        self.assertEqual(self.call(source, 'homeVod', [])['list'][0]['vod_id'], 'id$@@/#&=?')
        self.assertEqual(len(self.server.requests), count)
        category = self.call(source, 'category', ['1', 3, True, {}])
        self.assertEqual({k: category[k] for k in ['page', 'pagecount', 'limit', 'total']}, {'page': 3, 'pagecount': 4, 'limit': 2, 'total': 8})
        identifier = category['list'][0]['vod_id']
        detail = self.call(source, 'detail', [identifier])['list'][0]
        self.assertEqual(detail['vod_id'], identifier)
        self.assertEqual(self.server.requests[-1]['params']['ids'], [identifier])
        self.assertEqual(detail['vod_content'], 'Synopsis text')
        self.assertEqual(detail['vod_play_from'], 'Line$$$Second')
        self.assertIn('opaque$@@/#', detail['vod_play_url'])
        word = '关键 $@@/#&=?'
        search = self.call(source, 'search', [word, False, 3])
        self.assertEqual(search['list'][0]['vod_name'], word)
        self.assertEqual(self.server.requests[-1]['params']['wd'], [word])
        self.assertEqual(self.server.requests[-1]['params']['token'], ['fixture'])
        play = self.call(source, 'play', ['Line', '/media.m3u8?x=1', []])
        self.assertEqual(play['url'], self.server.origin + '/media.m3u8?x=1')
        self.assertEqual(play['parse'], 0)
        self.assertEqual(play['header'], {'User-Agent': 'Fixture-UA'})

    def test_category_name_allow_and_exclude_lists(self):
        source = self.install(categories=['电影', '剧集'], excludedCategories=['剧集'])
        self.assertEqual(self.call(source, 'home', [False])['class'], [{'type_id': '1', 'type_name': '电影'}])
        other = self.install(categories=[])
        self.assertEqual(self.call(other, 'home', [False])['class'], [])
        self.assertEqual(len(self.call(source, 'home', [False])['class']), 1)

    def test_unsupported_filter_rejected_before_network(self):
        source = self.install()
        count = len(self.server.requests)
        value = self.call(source, 'category', ['1', 1, False, {'year': '2026'}], 422)
        self.assertEqual(value, {'error': 'drpy_filter_not_supported'})
        self.assertEqual(len(self.server.requests), count)
        self.assertEqual(self.call(source, 'category', ['1', 3, True, {'year': '', 'area': '全部'}])['pagecount'], 4)

    def test_valid_empty_is_distinct_from_network_or_parse_failure(self):
        source = self.install()
        empty = self.call(source, 'category', ['empty', 4, False, {}])
        self.assertEqual((empty['list'], empty['page'], empty['pagecount']), ([], 4, 4))
        self.assertEqual(self.call(source, 'search', ['empty', False, 1])['list'], [])
        for kind in ['down', 'broken', 'code0', 'shape']:
            with self.subTest(kind=kind):
                self.assertEqual(self.call(source, 'category', [kind, 1, False, {}], 422), {'error': 'drpy_source_unavailable'})
        self.assertEqual(self.call(source, 'category', ['captcha', 1, False, {}], 422), {'error': 'drpy_verification_required'})
        self.assertTrue(self.call(source, 'category', ['1', 3, False, {}])['list'])

    def test_bad_home_is_not_silently_initialized(self):
        source = self.install(api=self.server.origin + '/bad-home')
        self.assertEqual(self.call(source, 'home', [False], 422), {'error': 'drpy_source_unavailable'})

    def test_web_search_real_contract_and_challenge_boundary(self):
        source = self.install(searchBase=self.server.origin + '/web/')
        self.assertEqual(self.call(source, 'search', ['verify', False, 1], 422), {'error': 'drpy_verification_required'})
        self.assertEqual(self.call(source, 'search', ['broken', False, 1], 422), {'error': 'drpy_source_unavailable'})
        self.assertEqual(self.call(source, 'search', ['empty', False, 1])['list'], [])
        result = self.call(source, 'search', ['Fixture', False, 1])
        self.assertEqual(result['list'][0]['vod_id'], '123')
        self.assertEqual(self.server.requests[-1]['params']['ids'], ['123'])

    def test_type4_preserves_play_identifiers_and_explicit_headers(self):
        source = self.install(type=4)
        self.call(source, 'home', [True])
        self.assertEqual(self.server.requests[-1]['params']['filter'], ['true'])
        opaque = 'opaque$@@/#&=?'
        result = self.call(source, 'play', ['A&B', opaque, []])
        self.assertEqual(self.server.requests[-1]['params']['play'], [opaque])
        self.assertEqual(self.server.requests[-1]['params']['flag'], ['A&B'])
        self.assertEqual(result['header'], {'X-Playback': 'explicit', 'Authorization': 'Explicit fixture'})
        self.assertEqual(result['url'], self.server.origin + '/media.m3u8')
        self.assertEqual(self.call(source, 'play', ['Line', 'bad-media', []], 422), {'error': 'drpy_media_protocol'})

    def test_explicit_foreign_parser_does_not_inherit_site_credentials(self):
        foreign = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
        foreign.daemon_threads = True
        foreign.origin = 'http://127.0.0.1:' + str(foreign.server_port)
        foreign.requests = []
        threading.Thread(target=foreign.serve_forever, daemon=True).start()
        try:
            source = self.install(playUrl=foreign.origin + '/parse?url=')
            self.call(source, 'home', [False])
            inherited = {k.lower(): v for k, v in self.server.requests[-1]['headers'].items()}
            self.assertEqual(inherited['authorization'], 'Inherited fixture')
            self.call(source, 'play', ['Line', 'opaque', []])
            received = {k.lower(): v for k, v in foreign.requests[-1]['headers'].items()}
            self.assertNotIn('authorization', received)
            self.assertNotIn('cookie', received)
        finally:
            foreign.shutdown()
            foreign.server_close()

    def test_configured_play_prefix_and_direct_cdn_no_implicit_secret(self):
        source = self.install(playUrl=self.server.origin + '/parse?url=')
        result = self.call(source, 'play', ['Line', 'opaque', []])
        self.assertEqual(self.server.requests[-1]['params']['url'], ['opaque'])
        self.assertEqual(result['header'], {'Referer': self.server.origin + '/watch'})
        direct = self.install()
        result = self.call(direct, 'play', ['Line', 'https://media.example.invalid/video.m3u8', []])
        self.assertEqual(result['header'], {'User-Agent': 'Fixture-UA'})
        for value in ['file:///fixture.mp4', 'javascript:void(0)', 'http://name:secret@example.invalid/video']:
            self.assertEqual(self.call(direct, 'play', ['Line', value, []], 422), {'error': 'drpy_media_protocol'})

if __name__ == '__main__':
    subprocess.run([NODE, '--jitless', str(ROOT / 'scripts/test_t4_adapter.cjs')], check=True)
    unittest.main()
