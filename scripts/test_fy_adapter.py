"""FY protocol fixtures through the production local, no-JIT source host."""
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs, unquote
import base64
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
PNG = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lWQAAAAASUVORK5CYII=')
CATALOGUE = '''<a class="public-list-exp" href="/detail/123.html" title=" First &amp; 二 "><img data-src="/cover.jpg"><span class="ft2">更新 2</span><b class="public-prt">电影</b><b class="public-prt">2026</b></a><a class="public-list-exp" href="/detail/123.html">duplicate</a>'''
DETAIL = '''<h3 class="slide-info-title"> First &amp; 二 </h3><img class="lazy" data-src="/cover.jpg"><div class="detail-info"><div class="slide-info">a</div><div class="slide-info">b</div><div class="slide-info">演员： 甲 乙</div><div class="slide-info">d</div><div class="slide-info">连载 : 2</div></div><div id="height_limit">剧情 <b>中文</b></div><div class="anthology-tab"><div class="swiper-slide" aria-label="1 / 2">## A 线</div><div class="swiper-slide swiper-slide-duplicate">不要这条</div><div class="swiper-slide" aria-label="2 / 2">B 线</div></div><div class="anthology-list-box"><a href="/play/123-2-1.html">B1</a></div><div class="anthology-list-box"><a href="/play/123-1-2.html">A2</a><a href="/play/123-1-1.html">A1</a></div>'''


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, value, status=200, mime='text/html; charset=utf-8', cookies=(), location=None):
        if isinstance(value, dict): value = json.dumps(value, ensure_ascii=False)
        data = value if isinstance(value, bytes) else value.encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(data)))
        for cookie in cookies: self.send_header('Set-Cookie', cookie)
        if location: self.send_header('Location', location)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        parsed = urlsplit(self.path)
        query = parse_qs(parsed.query)
        self.server.requests.append({'method':'GET', 'path':parsed.path, 'query':query, 'headers':{k.lower():v for k,v in self.headers.items()}})
        cookie = self.headers.get('Cookie', '')
        if parsed.path == '/captcha.php':
            self.reply(PNG, mime='text/html' if self.server.bad_image else 'image/png', cookies=('sid=captcha; Path=/',))
        elif parsed.path == '/player/':
            if self.server.parser_down:
                self.reply('Unavailable', 503)
            else:
                self.reply('<div data-token="discarded" data-te="fixture-token"></div>', cookies=('parse=session; Path=/player',))
        elif self.server.protected and 'verified=yes' not in cookie:
            self.reply('<h1>验证码</h1><img src="/captcha.php?type=code"><input name="check">', cookies=('sid=captcha; Path=/',))
        elif parsed.path.startswith('/detail/'):
            self.reply(DETAIL)
        elif parsed.path.startswith('/play/'):
            identifier = parsed.path.split('/')[-1][:-5]
            if identifier == '123-1-1':
                self.reply('<script>var player_aaaa={"url":"' + self.server.origin + '/media.m3u8?x=1","from":"co"};</script>')
            elif identifier == '123-1-2':
                self.reply('<script>var player_aaaa={url:"opaque resource & 中文", from:"co", nested:{"x":"}"}};</script>')
            elif identifier == '123-1-3':
                self.reply('<script>var player_aaaa={"url":"","from":"co"};</script>')
            elif identifier == '123-1-5':
                self.reply('', 302, cookies=('redirect=once; Path=/',), location='/play/123-1-1.html')
            elif identifier == '123-1-6':
                self.reply('', 302, location=self.server.foreign_origin+'/redirect-sink')
            elif identifier == '123-1-7':
                self.reply('', 302, location='/play/123-1-7.html')
            else:
                self.reply('<html>No player object</html>')
        elif parsed.path.startswith('/cupfox-search/'):
            if query.get('wd') == ['empty']:
                self.reply('<html>暂无资源</html>')
            else:
                self.reply('<div class="search-box"><div class="thumb-txt"><a href="/detail/123.html">First &amp; 二</a></div><img src="/cover.jpg"><span class="public-list-prb">HD</span></div>')
        else:
            self.reply(CATALOGUE + '<span>2/4页</span><footer>登录验证码<img src="/captcha.php"></footer>', cookies=self.server.cookie_fields)

    def do_POST(self):
        if self.headers.get('Transfer-Encoding', '').lower() == 'chunked':
            chunks = []
            while True:
                size = int(self.rfile.readline().split(b';')[0].strip(), 16)
                if not size:
                    while self.rfile.readline().strip():
                        pass
                    break
                chunks.append(self.rfile.read(size))
                self.rfile.read(2)
            body = b''.join(chunks).decode()
        else:
            body = self.rfile.read(int(self.headers.get('Content-Length', '0'))).decode()
        parsed = urlsplit(self.path)
        self.server.requests.append({'method':'POST', 'path':parsed.path, 'body':parse_qs(body), 'headers':{k.lower():v for k,v in self.headers.items()}})
        if parsed.path == '/captcha.php':
            ok = parse_qs(body).get('check') == ['AB12'] and 'sid=captcha' in self.headers.get('Cookie', '')
            self.reply({'code':1 if ok else 0}, cookies=('verified=yes; Path=/',) if ok else ())
        elif parsed.path == '/player/mplayer.php':
            if self.server.parser_redirect:
                self.reply('', 303, location=self.server.foreign_origin+'/post-sink')
            elif parse_qs(body).get('token') != ['fixture-token'] or 'parse=session' not in self.headers.get('Cookie', ''):
                self.reply('Missing same-session token', 403)
            else:
                self.reply({'data':{'url':self.server.origin + '/resolved.m3u8'}})
        else:
            self.reply('Not found', 404)


class FyHostChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name)
        cls.servers = []
        for _ in range(2):
            server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
            server.daemon_threads = True
            server.origin = 'http://127.0.0.1:' + str(server.server_port)
            server.requests = []
            server.protected = server.bad_image = server.parser_down = False
            threading.Thread(target=server.serve_forever, daemon=True).start()
            cls.servers.append(server)
        cls.site, cls.parser = cls.servers
        cls.site.foreign_origin, cls.parser.foreign_origin = cls.parser.origin, cls.site.origin
        cls.ready = cls.root / 'ready.json'
        cls.process = subprocess.Popen([NODE, '--jitless', str(ROOT/'shared/catpaw/host.cjs'), str(cls.root), str(cls.ready)], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 10
        while not cls.ready.exists():
            if cls.process.poll() is not None or time.monotonic() > deadline: raise AssertionError('Host failed to start')
            time.sleep(.02)
        cls.state = json.loads(cls.ready.read_text())
        cls.counter = 0

    @classmethod
    def tearDownClass(cls):
        cls.process.stdin.close()
        cls.process.wait(timeout=8)
        for server in cls.servers:
            server.shutdown(); server.server_close()
        cls.temp.cleanup()

    def setUp(self):
        for server in self.servers:
            server.requests.clear()
            server.protected = server.bad_image = server.parser_down = server.parser_redirect = False
            server.cookie_fields = ('site=only; Path=/', 'limited=private; Path=/private')

    def install(self, origin=None):
        parsers = [(origin or self.parser.origin)+'/player/mplayer.php', (origin or self.site.origin)+'/player/mplayer.php']
        config = {'origin':origin or self.site.origin, 'parsers':parsers, 'userAgent':'Fixture-UA',
                  'parserMap':{key:parsers[0] for key in ['co','BBA','vwnet','YYNB','JD4K','JD2K','qiyi','bilibili','qq','youku']}}
        script = 'process.stdout.write(JSON.stringify(require(process.argv[1])(JSON.parse(process.argv[2]))))'
        rule = json.loads(subprocess.check_output([NODE, '--jitless', '-e', script, str(ROOT/'shared/catpaw/drpy-fy-adapter.cjs'), json.dumps(config)], stderr=subprocess.DEVNULL))
        type(self).counter += 1
        manifest = {'kind':'drpy','version':1,'runtime':'drpy2-ca23ffdb-1',
                    'sourceId':hashlib.sha256(str(type(self).counter).encode()).hexdigest(),
                    'origin':(origin or self.site.origin)+'/rule.js','rule':rule,'headers':{'Authorization':'Source fixture'},'requestTimeoutMs':2000}
        raw = json.dumps(manifest).encode()
        digest = hashlib.sha256(raw).hexdigest()
        (self.root/digest).mkdir()
        (self.root/digest/'drpy.json').write_bytes(raw)
        self.addCleanup(self.release, digest)
        return digest

    def release(self, digest):
        conn = http.client.HTTPConnection('127.0.0.1', self.state['port'], timeout=8)
        conn.request('POST', '/'+self.state['secret']+'/'+digest+'/_release')
        conn.getresponse().read(); conn.close()

    def call(self, digest, method, args, status=200):
        conn = http.client.HTTPConnection('127.0.0.1', self.state['port'], timeout=12)
        conn.request('POST', '/'+self.state['secret']+'/'+digest+'/api/drpy', json.dumps({'version':1,'method':method,'args':args}))
        response = conn.getresponse()
        value = json.loads(response.read())
        self.assertEqual(response.status, status, value)
        conn.close()
        return value

    def action(self, source, operation, status=200, **values):
        return self.call(source, 'action', [json.dumps({'type':'verification','operation':operation,**values})], status)

    def test_catalogue_filter_search_detail_and_direct_play(self):
        source = self.install()
        home = self.call(source,'home',[True])
        self.assertEqual(len(home['class']),8)
        self.assertEqual([f['key'] for f in home['filters']['1']], ['type','class','area','year','lang','letter','orderBy'])
        self.assertEqual(self.site.requests,[])
        self.assertEqual(self.call(source,'homeVod',[])['list'][0]['vod_name'],'First & 二')
        self.assertEqual(self.call(source,'category',['1',2,True,{'area':'美国','class':'动作','letter':'A','orderBy':'score','year':'2026'}])['pagecount'],4)
        self.assertEqual(unquote(self.site.requests[-1]['path']),'/cupfox-list/1-美国--动作--A-score--2---2026.html')
        detail = self.call(source,'detail',['123,ignored'])['list'][0]
        self.assertEqual(detail['vod_actor'],'甲 乙')
        self.assertEqual(detail['vod_content'],'剧情 中文')
        self.assertEqual(detail['vod_play_from'],'A 线$$$B 线')
        self.assertEqual(detail['vod_play_url'],'A1$123-1-1#A2$123-1-2$$$B1$123-2-1')
        self.assertTrue(self.call(source,'search',['中文 & %',False,1])['list'])
        self.assertEqual(self.site.requests[-1]['query']['wd'],['中文 & %'])
        count = len(self.site.requests)
        self.assertFalse(self.call(source,'search',['中文',False,2])['list'])
        self.assertEqual(len(self.site.requests),count)
        self.assertFalse(self.call(source,'search',['empty',False,1])['list'])
        play = self.call(source,'play',['A 线','123-1-1',[]])
        self.assertEqual(play['url'],self.site.origin+'/media.m3u8?x=1')
        count = len(self.site.requests)
        self.assertEqual(self.call(source,'play',['A 线','123-1-1',[]]),play)
        self.assertEqual(len(self.site.requests),count)

    def test_parser_session_form_and_cross_origin_credential_isolation(self):
        source = self.install()
        self.call(source,'homeVod',[])
        result = self.call(source,'play',['A','123-1-2',[]])
        self.assertEqual(result['url'],self.parser.origin+'/resolved.m3u8')
        first,last = self.parser.requests
        self.assertEqual(first['query']['url'],['opaque resource & 中文'])
        self.assertNotIn('authorization',first['headers'])
        self.assertNotIn('cookie',first['headers'])
        self.assertEqual(last['body'],{'url':['opaque resource & 中文'],'token':['fixture-token']})
        self.assertEqual(last['headers']['cookie'],'parse=session')
        self.assertEqual(self.site.requests[-1]['headers']['cookie'],'site=only')
        self.assertEqual(self.site.requests[-1]['headers']['authorization'],'Source fixture')

    def test_parser_failure_tries_original_fallback(self):
        self.parser.parser_down = True
        result = self.call(self.install(),'play',['A','123-1-2',[]])
        self.assertEqual(result['url'],self.site.origin+'/resolved.m3u8')

    def test_manual_verification_retry_restart_and_source_isolation(self):
        self.site.protected = True
        source = self.install()
        self.assertEqual(self.call(source,'homeVod',[],422),{'error':'drpy_verification_required'})
        image = self.action(source,'challenge')
        self.assertEqual(base64.b64decode(image['imageBase64']),PNG)
        self.assertFalse(self.action(source,'submit',id=image['id'],code='NOPE')['verified'])
        self.assertTrue(self.action(source,'submit',id=image['id'],code='AB12')['verified'])
        self.assertTrue(self.call(source,'homeVod',[])['list'])
        self.release(source)
        self.assertTrue(self.call(source,'homeVod',[])['list'])
        other = self.install()
        self.assertEqual(self.call(other,'homeVod',[],422),{'error':'drpy_verification_required'})

    def test_verification_refresh_rejects_old_id_and_invalid_image(self):
        source = self.install()
        old = self.action(source,'challenge')
        new = self.action(source,'challenge')
        count = len(self.site.requests)
        self.assertEqual(self.action(source,'submit',422,id=old['id'],code='AB12'),{'error':'drpy_action_invalid'})
        self.assertEqual(self.action(source,'submit',422,id=new['id'],code='x'),{'error':'drpy_action_invalid'})
        self.assertEqual(len(self.site.requests),count)
        self.site.bad_image = True
        self.assertEqual(self.action(source,'challenge',422),{'error':'drpy_verification_unavailable'})

    def test_cookie_expiry_deletion_domain_secure_and_combined_headers(self):
        source = self.install()
        self.site.cookie_fields = ('keep=yes; Expires=Wed, 09 Jun 2038 10:18:14 GMT; Path=/, combined=yes; Path=/',
                                  'remove=yes; Path=/', 'expired=no; Max-Age=0; Path=/',
                                  'foreign=no; Domain=example.invalid; Path=/', 'secure=no; Secure; Path=/')
        self.call(source,'homeVod',[])
        self.site.cookie_fields = ('remove=; Max-Age=0; Path=/',)
        self.call(source,'homeVod',[])
        self.assertEqual(set(self.site.requests[-1]['headers']['cookie'].split('; ')), {'keep=yes','combined=yes','remove=yes'})
        self.call(source,'detail',['123'])
        self.assertEqual(set(self.site.requests[-1]['headers']['cookie'].split('; ')), {'keep=yes','combined=yes'})

    def test_redirects_recompute_cookie_and_bound_origin_method_and_hops(self):
        source = self.install()
        self.assertEqual(self.call(source,'play',['A','123-1-5',[]])['url'],self.site.origin+'/media.m3u8?x=1')
        self.assertEqual(self.site.requests[-1]['headers']['cookie'],'redirect=once')
        self.assertEqual(self.call(source,'play',['A','123-1-6',[]],422),{'error':'drpy_source_unavailable'})
        self.assertEqual(self.parser.requests,[])
        before = len(self.site.requests)
        self.assertEqual(self.call(source,'play',['A','123-1-7',[]],422),{'error':'drpy_source_unavailable'})
        self.assertEqual(len(self.site.requests)-before,2)
        self.site.parser_redirect = self.parser.parser_redirect = True
        self.assertEqual(self.call(source,'play',['A','123-1-2',[]],422),{'error':'drpy_media_unresolved'})
        self.assertFalse(any(r['path'].endswith('sink') for s in self.servers for r in s.requests))

    def test_bad_ids_filters_and_missing_media_fail_without_fake_success(self):
        source = self.install()
        self.assertEqual(self.call(source,'detail',['../../other'],422),{'error':'drpy_invalid_id'})
        self.assertEqual(self.call(source,'category',['1',1,True,{'year':'unlisted'}],422),{'error':'drpy_unsupported_filter'})
        self.assertEqual(self.call(source,'category',['1',1,True,{'__proto__':'unlisted'}],422),{'error':'drpy_unsupported_filter'})
        self.assertEqual(self.site.requests,[])
        self.assertEqual(self.call(source,'play',['A','123-1-3',[]],422),{'error':'drpy_media_unresolved'})
        self.assertEqual(self.call(source,'play',['A','123-1-4',[]],422),{'error':'drpy_media_unresolved'})

    def test_native_ios_fixture_uses_the_same_production_protocol(self):
        ready = self.root/'ios-fixture-ready.json'
        wrapper = '''const http=require('node:http'),fs=require('node:fs');
globalThis.catServerFactory=handler=>{const s=http.createServer(handler),listen=s.listen.bind(s);
s.listen=(_port,_host,cb)=>listen(0,'127.0.0.1',()=>{fs.writeFileSync(process.argv[2],JSON.stringify({origin:'http://127.0.0.1:'+s.address().port}));if(cb)cb();});return s;};
require(process.argv[1]).start();process.stdin.resume();process.stdin.on('end',()=>process.exit(0));'''
        process = subprocess.Popen([NODE,'--jitless','-e',wrapper,str(ROOT/'scripts/ios_runtime/fixture.cjs'),str(ready)],
                                   env={**os.environ,'NODE_PATH':str(self.root)},stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic()+5
            while not ready.exists():
                if process.poll() is not None or time.monotonic()>deadline: self.fail('iOS fixture failed to start')
                time.sleep(.02)
            origin = json.loads(ready.read_text())['origin']
            source = self.install(origin)
            self.assertEqual(len(self.call(source,'home',[True])['class']),8)
            image = self.action(source,'challenge')
            self.assertEqual(base64.b64decode(image['imageBase64']),PNG)
            self.assertFalse(self.action(source,'submit',id=image['id'],code='NOPE')['verified'])
            self.assertTrue(self.action(source,'submit',id=image['id'],code='AB12')['verified'])
            self.assertEqual(self.call(source,'homeVod',[])['list'][0]['vod_name'],'FY 本机影片')
            self.assertEqual(self.call(source,'category',['1',2,True,{'area':'美国','year':'2026'}])['pagecount'],4)
            self.assertEqual(self.call(source,'detail',['123'])['list'][0]['vod_play_url'],'第一集$123-1-1#第二集$123-1-2')
            self.assertEqual(self.call(source,'play',['线路 A','123-1-1',[]])['url'],origin+'/fy-media.m3u8')
            self.release(source)
            self.assertEqual(len(self.call(source,'homeVod',[])['list']),1)
        finally:
            process.stdin.close()
            process.wait(timeout=8)


if __name__ == '__main__':
    unittest.main()
