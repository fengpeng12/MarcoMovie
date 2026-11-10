"""Auete adapter and exact-code literal reader; synthetic HTTP/DEX fixtures only."""
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import base64
import hashlib
import html
import http.client
import json
import subprocess
import tempfile
import threading
import unittest
import urllib.parse
import test_guard_bootstrap as guard

ROOT, NODE = guard.ROOT, guard.NODE

class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        self.server.paths.append(self.path)
        path = urllib.parse.urlsplit(self.path).path
        origin = self.server.origin
        if 'searchword=challenge' in self.path:
            body = '<form method="post" action="?scheckAC=check"><input name="validate"><input type="hidden" name="searchword" value="challenge"><img src="include/vdimgck.php"></form>'
        elif 'play-' in path:
            mode = int(path.rsplit('-',1)[1].split('.')[0])
            values = [
                'base64decode("'+base64.b64encode((origin+'/media.mp4?token=fixture').encode()).decode().rstrip('=')+'")',
                json.dumps(origin+'/plain.mp4'), '"relative/movie.m3u8?token=fixture"',
                '(globalThis.untrustedExecuted=true,"'+origin+'/unsafe.mp4")',
                '"file:///fixture.mp4"', json.dumps(origin.replace('://','://fixture:secret@')+'/media.mp4'),
            ]
            body = '<div><script>var now='+values[mode]+'; var ignored=1;</script></div>'
        elif path == '/Movie/dzp/alpha/':
            body = ('<div class="detail-main-card"><h1 class="detail-title">《Fixture》</h1>'
                    '<div class="detail-poster"><img src="/poster.png"></div></div>'
                    '<div class="message"><p><span class="detail-label">地区：</span><b>Fixture region</b></p>'
                    '<p><span class="detail-label">年代：</span><b>2025</b></p><p class="detail-des">Fixture plot</p></div>')
            for line in range(2):
                body += '<div class="play-card" id="player_list"><div class="card-header"><span><b>线路：Line'+str(line)+'</b></span></div><ul class="episode-list">'
                body += ''.join('<li><a href="/Movie/dzp/alpha/play-'+str(line)+'-'+str(i)+'.html">Episode'+str(i)+'</a></li>' for i in range(3))
                body += '</ul></div>'
        else:
            second = 'index2.html' in path
            ident = 'beta' if second else 'alpha'
            title = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query).get('searchword',['Fixture'])[0]
            body = '<ul class="navbar-nav mr-auto"><li><a href="/Movie/index.html">电影</a></li><li><a href="/Tv/index.html">电视剧</a></li></ul>'
            body += '<ul class="threadlist"><li><a class="pic"><img src="/poster.png"></a><h2><a title="'+title+'" href="/Movie/dzp/'+ident+'/">'+title+'</a></h2><span class="hdtag">Test</span></li></ul>'
        data = body.encode()
        self.send_response(200); self.send_header('Content-Type','text/html; charset=utf-8'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)

class AueteChecks(unittest.TestCase):
    setUpClass = classmethod(guard.HostChecks.setUpClass.__func__)
    tearDownClass = classmethod(guard.HostChecks.tearDownClass.__func__)
    request = guard.HostChecks.request

    def test_adapter_six_methods_filters_and_pagination(self):
        fixture = ThreadingHTTPServer(('127.0.0.1',0),Fixture)
        fixture.daemon_threads=True; fixture.origin='http://127.0.0.1:'+str(fixture.server_port);fixture.paths=[]
        threading.Thread(target=fixture.serve_forever,daemon=True).start()
        try:
            config={'origin':fixture.origin,'mediaBase':fixture.origin+'/cdn/','userAgent':'Fixture-UA'}
            js="console.log(JSON.stringify(require(process.argv[1])(JSON.parse(process.argv[2]))))"
            rule=json.loads(subprocess.check_output([NODE,'--jitless','-e',js,str(ROOT/'shared/catpaw/drpy-auete-adapter.cjs'),json.dumps(config)],stderr=subprocess.DEVNULL))
            manifest={'kind':'drpy','version':1,'runtime':'drpy2-ca23ffdb-1','sourceId':'e'*64,
                      'origin':fixture.origin+'/rule.js','rule':rule,'headers':{},'requestTimeoutMs':2000}
            data=json.dumps(manifest).encode(); digest=hashlib.sha256(data).hexdigest()
            (self.root/digest).mkdir(); (self.root/digest/'drpy.json').write_bytes(data)
            api='/'+self.state['secret']+'/'+digest+'/api/drpy'
            def call(method,args):
                status,value=self.request({'version':1,'method':method,'args':args},path=api)
                self.assertEqual(status,200,value);return value
            home=call('home',[True]);self.assertEqual(len(home['class']),2)
            self.assertEqual(home['filters']['Movie'][0]['value'][1],{'n':'喜剧片','v':'xjp'})
            recommended=call('homeVod',[]);self.assertEqual(recommended['list'][0]['vod_name'],'Fixture')
            category=call('category',['Movie',1,True,{'type':'xjp'}]);self.assertIn('/Movie/xjp/index.html',fixture.paths)
            for selected in ['动作','动作片','dzp']:
                call('category',['Movie',2,True,{'type':selected}]);self.assertEqual(fixture.paths[-1],'/Movie/dzp/index2.html')
                call('category',['Movie',1,True,{'class':selected}]);self.assertEqual(fixture.paths[-1],'/Movie/dzp/index.html')
            call('category',['Movie',1,True,{'type':'动作','class':'dzp','area':'全部','year':''}])
            self.assertEqual(fixture.paths[-1],'/Movie/dzp/index.html')
            for selected in [{'type':'动作','class':'喜剧'}, {'area':'中国大陆'}, {'year':'2025'}]:
                status,error=self.request({'version':1,'method':'category','args':['Movie',1,True,selected]},path=api)
                self.assertEqual((status,error),(422,{'error':'drpy_filter_not_supported'}))
            for category_id,selected in [('Movie','未知'),('Tv','动作')]:
                status,error=self.request({'version':1,'method':'category','args':[category_id,1,True,{'type':selected}]},path=api)
                self.assertEqual((status,error),(422,{'error':'drpy_filter_not_supported'}))
            page2=call('category',['Movie',2,True,{}]);self.assertIn('/Movie/index2.html',fixture.paths)
            self.assertNotEqual(category['list'][0]['vod_id'],page2['list'][0]['vod_id'])
            self.assertEqual(call('search',['Fixture search',False,2])['list'][0]['vod_name'],'Fixture search')
            status,verification=self.request({'version':1,'method':'search','args':['challenge',False,1]},path=api)
            self.assertEqual((status,verification),(422,{'error':'drpy_verification_required'}))
            detail=call('detail',[category['list'][0]['vod_id']])['list'][0]
            self.assertEqual(detail['vod_name'],'Fixture');self.assertEqual(detail['vod_year'],'2025')
            self.assertEqual(detail['vod_play_from'],'Line0$$$Line1')
            self.assertEqual(len(detail['vod_play_url'].split('$$$')),2)
            for mode,expected in [(0,'/media.mp4?token=fixture'),(1,'/plain.mp4'),(2,'/cdn/relative/movie.m3u8?token=fixture')]:
                play=call('play',['Line0',fixture.origin+'/Movie/dzp/alpha/play-0-'+str(mode)+'.html',[]])
                self.assertEqual(play['parse'],0);self.assertEqual(play['url'],fixture.origin+expected)
            for mode in [3,4,5]:
                status,value=self.request({'version':1,'method':'play','args':['Line0',fixture.origin+'/Movie/dzp/alpha/play-0-'+str(mode)+'.html',[]]},path=api)
                self.assertEqual(status,422);self.assertEqual(value['error'],'drpy_media_unresolved' if mode==3 else 'drpy_media_protocol')
                self.assertNotIn('secret',json.dumps(value))
            self.assertFalse(any('/unsafe.mp4' in path for path in fixture.paths))
        finally:
            fixture.shutdown();fixture.server_close()

    def test_unknown_auete_artifact_explicit(self):
        data=b'synthetic unknown Auete';digest=hashlib.sha256(data).hexdigest()
        (self.root/'imports'/(digest+'.jar')).write_bytes(data)
        self.assertEqual(self.request({'version':1,'adapter':'auete-v1','artifactHash':digest}),
                         (422,{'error':'guard_artifact_unsupported'}))

class ReviewedLiteralChecks(unittest.TestCase):
    setUp=guard.ReaderChecks.setUp
    tearDown=guard.ReaderChecks.tearDown
    run_reader=guard.ReaderChecks.run_reader

    def test_exact_code_fingerprint_and_known_unit(self):
        data,code=guard.fixture_dex();size=int.from_bytes(data[code+12:code+16],'little')
        digest=hashlib.sha256(data[code:code+16+size*2]).hexdigest()
        expression="new x.Dex(b).reviewedLiteral('Lfixture/Source;','<init>','"+digest+"',3,'yq')"
        self.assertEqual(self.run_reader(data,expression)['value'],'http://127.0.0.1:9')
        self.assertIn('error',self.run_reader(data,expression.replace(digest,'0'*64)))
        self.assertIn('error',self.run_reader(data,expression.replace(",3,'yq'",",0,'yq'")))
        self.assertIn('error',self.run_reader(data,expression.replace("'yq'","'SN'")))


PNG = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lWQAAAAASUVORK5CYII=')


class VerificationFixture(Fixture):
    def reply(self, body, *, mime='text/html; charset=utf-8', status=200, cookies=(), location=None):
        data = body if isinstance(body, bytes) else body.encode()
        self.send_response(status)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(data)))
        for cookie in cookies:
            self.send_header('Set-Cookie', cookie)
        if location:
            self.send_header('Location', location)
        self.end_headers()
        self.wfile.write(data)

    def session(self):
        cookie = self.headers.get('Cookie', '')
        values = dict(part.strip().split('=', 1) for part in cookie.split(';') if '=' in part)
        return values.get('PHPSESSID'), values

    def form(self, word, page):
        action = '?scheckAC=check&page='+str(page)+'&searchtype=&order=&tid=&area=&year=&letter=&yuyan=&state=&money=&ver=&jq='
        if self.server.foreign_form:
            action = 'https://outside.invalid/auete4so.php?scheckAC=check'
        return ('<form id="f_login" method="post" action="'+action+'">'
                '<img id="vdimgck" src="include/vdimgck.php">'
                '<input name="validate" type="text"><input type="hidden" name="searchword" value="'+html.escape(word, quote=True)+'"></form>')

    def record(self, method, body=None):
        parsed = urllib.parse.urlsplit(self.path)
        self.server.requests.append({'method':method, 'path':parsed.path,
            'query':urllib.parse.parse_qs(parsed.query, keep_blank_values=True),
            'headers':{key.lower():value for key,value in self.headers.items()}, 'body':body})

    def do_GET(self):
        self.record('GET')
        parsed = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        session, cookies = self.session()
        if parsed.path == '/include/vdimgck.php':
            self.server.images += 1
            self.reply(PNG, mime='text/html' if self.server.bad_image else 'image/png',
                       cookies=('captcha=image'+str(self.server.images)+'; Path=/',))
        elif parsed.path == '/auete4so.php':
            if session in self.server.verified:
                if self.server.bad_result:
                    self.reply('<html>Upstream returned an unrelated error</html>')
                else:
                    super().do_GET()
            else:
                if not session:
                    self.server.sessions += 1
                    session = 'session'+str(self.server.sessions)
                self.reply(self.form(query.get('searchword',[''])[0],query.get('page',['1'])[0]),
                    cookies=('PHPSESSID='+session+'; Path=/; HttpOnly', 'limited=private; Path=/private'))
        else:
            super().do_GET()

    def do_POST(self):
        if self.headers.get('Transfer-Encoding', '').lower() == 'chunked':
            chunks = []
            while True:
                size = int(self.rfile.readline().split(b';')[0].strip(),16)
                if not size:
                    while self.rfile.readline().strip():
                        pass
                    break
                chunks.append(self.rfile.read(size)); self.rfile.read(2)
            raw = b''.join(chunks)
        else:
            raw = self.rfile.read(int(self.headers.get('Content-Length',0)))
        body = urllib.parse.parse_qs(raw.decode(),keep_blank_values=True)
        self.record('POST',body)
        session,cookies = self.session()
        page = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)['page'][0]
        if session and cookies.get('captcha') and body.get('validate') == ['AB12']:
            self.server.verified.add(session)
            if self.server.redirect:
                self.reply('',status=303,location=self.server.redirect)
            else:
                self.reply('<html>Verification submitted</html>')
        else:
            self.reply(self.form(body.get('searchword',[''])[0],page))


class AueteVerificationChecks(unittest.TestCase):
    setUpClass = classmethod(guard.HostChecks.setUpClass.__func__)
    tearDownClass = classmethod(guard.HostChecks.tearDownClass.__func__)
    request = guard.HostChecks.request
    counter = 0

    def setUp(self):
        self.site = ThreadingHTTPServer(('127.0.0.1',0),VerificationFixture)
        self.site.daemon_threads = True
        self.site.origin = 'http://127.0.0.1:'+str(self.site.server_port)
        self.site.paths = []; self.site.requests = []; self.site.verified = set()
        self.site.sessions = self.site.images = 0
        self.site.bad_image = self.site.foreign_form = self.site.bad_result = False
        self.site.redirect = None
        threading.Thread(target=self.site.serve_forever,daemon=True).start()

    def tearDown(self):
        self.site.shutdown(); self.site.server_close()

    def install(self):
        type(self).counter += 1
        config = {'origin':self.site.origin,'mediaBase':self.site.origin+'/cdn/','userAgent':'Fixture-UA'}
        js = 'console.log(JSON.stringify(require(process.argv[1])(JSON.parse(process.argv[2]))))'
        rule = json.loads(subprocess.check_output([NODE,'--jitless','-e',js,
            str(ROOT/'shared/catpaw/drpy-auete-adapter.cjs'),json.dumps(config)],stderr=subprocess.DEVNULL))
        manifest = {'kind':'drpy','version':1,'runtime':'drpy2-ca23ffdb-1',
            'sourceId':hashlib.sha256(('auete-verification'+str(type(self).counter)).encode()).hexdigest(),
            'origin':self.site.origin+'/rule.js','rule':rule,'headers':{},'requestTimeoutMs':2000}
        data = json.dumps(manifest).encode(); digest = hashlib.sha256(data).hexdigest()
        (self.root/digest).mkdir(); (self.root/digest/'drpy.json').write_bytes(data)
        self.addCleanup(self.release,digest)
        return digest

    def release(self,digest):
        conn = http.client.HTTPConnection('127.0.0.1',self.state['port'],timeout=8)
        conn.request('POST','/'+self.state['secret']+'/'+digest+'/_release')
        conn.getresponse().read(); conn.close()

    def call(self,source,method,args,status=200):
        actual,value = self.request({'version':1,'method':method,'args':args},
            path='/'+self.state['secret']+'/'+source+'/api/drpy')
        self.assertEqual(actual,status,value)
        return value

    def action(self,source,operation,status=200,**values):
        return self.call(source,'action',[json.dumps({'type':'verification','operation':operation,**values})],status)

    def protect(self,source,word='影片 & 二',page=2):
        self.assertEqual(self.call(source,'search',[word,False,page],422),{'error':'drpy_verification_required'})

    def test_manual_form_session_search_retry_and_source_isolation(self):
        source = self.install(); word = '影片 & 二'
        self.protect(source,word)
        image = self.action(source,'challenge')
        self.assertEqual(base64.b64decode(image['imageBase64']),PNG)
        self.assertFalse(self.action(source,'submit',id=image['id'],code='NOPE')['verified'])
        refreshed = self.action(source,'challenge')
        self.assertEqual(self.action(source,'submit',422,id=image['id'],code='AB12'),{'error':'drpy_action_invalid'})
        self.assertTrue(self.action(source,'submit',id=refreshed['id'],code='AB12')['verified'])
        post = [r for r in self.site.requests if r['method']=='POST'][-1]
        self.assertEqual(post['body'],{'validate':['AB12'],'searchword':[word]})
        self.assertEqual(post['query']['scheckAC'],['check']); self.assertEqual(post['query']['page'],['2'])
        self.assertIn('PHPSESSID=session1',post['headers']['cookie'])
        self.assertIn('captcha=image2',post['headers']['cookie'])
        self.assertNotIn('limited=',post['headers']['cookie'])
        self.assertEqual(post['headers']['origin'],self.site.origin)
        referer = urllib.parse.urlsplit(post['headers']['referer'])
        self.assertEqual(urllib.parse.parse_qs(referer.query)['searchword'],[word])
        result = self.call(source,'search',[word,False,2])
        self.assertEqual(result['list'][0]['vod_name'],word)
        self.release(source)
        self.assertEqual(self.call(source,'search',[word,False,2])['list'][0]['vod_name'],word)
        other = self.install(); self.protect(other)
        request = [r for r in self.site.requests if r['path']=='/auete4so.php'][-1]
        self.assertNotIn('cookie',request['headers'])
        self.assertEqual(self.action(other,'submit',422,id=refreshed['id'],code='AB12'),{'error':'drpy_action_invalid'})

    def test_pending_search_survives_worker_restart_but_image_id_does_not(self):
        source = self.install(); self.protect(source,'第二个搜索',3)
        stale = self.action(source,'challenge'); self.release(source)
        self.assertEqual(self.action(source,'submit',422,id=stale['id'],code='AB12'),{'error':'drpy_action_invalid'})
        image = self.action(source,'challenge')
        self.assertTrue(self.action(source,'submit',id=image['id'],code='AB12')['verified'])
        post = [r for r in self.site.requests if r['method']=='POST'][-1]
        self.assertEqual(post['body']['searchword'],['第二个搜索']); self.assertEqual(post['query']['page'],['3'])

    def test_untrusted_form_and_wrong_image_type_never_submit(self):
        source = self.install(); self.site.foreign_form = True
        self.assertEqual(self.call(source,'search',['test',False,1],422),{'error':'drpy_verification_unavailable'})
        self.site.foreign_form = False; self.protect(source); self.site.bad_image = True
        self.assertEqual(self.action(source,'challenge',422),{'error':'drpy_verification_unavailable'})
        self.assertEqual(self.action(source,'submit',422,id='invented',code='AB12'),{'error':'drpy_action_invalid'})
        self.assertFalse(any(r['method']=='POST' for r in self.site.requests))

    def test_post_redirect_is_same_origin_and_success_requires_search_content(self):
        source = self.install(); self.protect(source); image = self.action(source,'challenge')
        self.site.redirect = '/auete4so.php?searchword=ignored'
        self.assertTrue(self.action(source,'submit',id=image['id'],code='AB12')['verified'])
        other = self.install(); self.protect(other); image = self.action(other,'challenge')
        self.site.bad_result = True
        self.assertEqual(self.action(other,'submit',422,id=image['id'],code='AB12'),{'error':'drpy_verification_unavailable'})
        self.site.bad_result = False
        third = self.install(); self.protect(third); image = self.action(third,'challenge')
        self.site.redirect = 'https://outside.invalid/auete4so.php'
        self.assertEqual(self.action(third,'submit',422,id=image['id'],code='AB12'),{'error':'drpy_source_unavailable'})

if __name__=='__main__':
    unittest.main(verbosity=2)
