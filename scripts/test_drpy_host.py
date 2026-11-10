"""Exercise DRPY through the real authenticated local router, synthetic data only."""
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hashlib
import gzip
import http.client
import json
import os
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


class Fixtures(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(url.query)
        content_type = 'text/html; charset=utf-8'
        self.server.requests.append((url.path, dict(self.headers)))
        if url.path == '/search' and query.get('wd',[''])[0].startswith('concurrent-'):
            time.sleep(.15)
        if url.path == '/slow':
            time.sleep(2)
            return
        if url.path == '/redirect':
            self.send_response(302)
            self.send_header('Location', self.server.other + '/echo')
            self.end_headers()
            return
        if url.path == '/echo':
            data = json.dumps(dict(self.headers)).encode()
        elif url.path == '/helper.js':
            data = b'globalThis.fixtureHelper="loaded actual remote helper";'
        elif url.path == '/json':
            data = json.dumps({'items': [{'name': 'JSON fixture', 'id': '/detail/42'}]}).encode()
        elif url.path == '/detail/42':
            data = json.dumps({'vod_id': self.server.origin + '/detail/42', 'vod_name': 'Fixture detail',
                'vod_play_from': 'fixture', 'vod_play_url': 'Episode$' + self.server.origin + '/resolve'}).encode()
        elif url.path == '/resolve':
            data = json.dumps({'parse': 0, 'url': self.server.origin + '/never-download.mp4', 'header': {'X-Fixture': 'ok'}}).encode()
        elif url.path == '/large':
            data = b'x' * (6 * 1024 * 1024 + 1)
        elif url.path == '/compressed-large':
            data = gzip.compress(b'x' * (7 * 1024 * 1024))
        elif url.path == '/encoded':
            data = '<article class="item"><a href="/detail/42"><h3>中文测试</h3><img src="/poster.png"></a><span>test</span></article>'.encode(query.get('codec', ['utf-8'])[0])
            charset = query.get('charset', [''])[0]
            content_type = 'text/html' + ('; charset=' + charset if charset else '')
        else:
            title = query.get('wd', ['HTML fixture'])[0]
            area = query.get('area', [''])[0]
            data = f'<article class="item"><a href="/detail/42"><h3>{title}{area}</h3><img src="/poster.png"></a><span>test</span></article>'.encode()
        self.send_response(200)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(data)))
        if url.path == '/compressed-large':
            self.send_header('Content-Encoding','gzip')
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass


class DrpyChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name)
        cls.servers = []
        for _ in range(2):
            server = ThreadingHTTPServer(('127.0.0.1', 0), Fixtures)
            server.daemon_threads = True
            server.requests = []
            server.origin = 'http://127.0.0.1:' + str(server.server_port)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            cls.servers.append(server)
        cls.servers[0].other = cls.servers[1].origin
        cls.origin = cls.servers[0].origin
        cls.node = os.environ.get('MARCOMOVIE_NODE') or shutil.which('node')
        cls.ready = cls.root / 'ready.json'
        cls.process = subprocess.Popen([cls.node, '--jitless', str(ROOT/'shared/catpaw/host.cjs'), str(cls.root), str(cls.ready)],
            stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        until = time.monotonic()+8
        while not cls.ready.exists():
            if cls.process.poll() is not None or time.monotonic()>until:
                raise AssertionError('DRPY router startup failed')
            time.sleep(.02)
        state = json.loads(cls.ready.read_text())
        cls.base = f'http://127.0.0.1:{state["port"]}/{state["secret"]}'
        cls.rule = {'title': 'Synthetic fixture', 'host': cls.origin, 'homeUrl': '/home',
            'url': '/category/fyclass?page=fypage&fyfilter', 'filter_url': 'area={{fl.area}}',
            'class_name': 'Films', 'class_url': 'films', 'searchable': 2, 'quickSearch': 1, 'filterable': 1,
            'filter': {'films': [{'key': 'area', 'name': 'Area', 'value': [{'n': 'Local', 'v': 'local'}]}]},
            '推荐': '.item;h3&&Text;img&&src;span&&Text;a&&href',
            '一级': '.item;h3&&Text;img&&src;span&&Text;a&&href',
            'searchUrl': '/search?wd=**&page=fypage', '搜索': '*',
            '二级': 'js:VOD=JSON.parse(request(input));', 'play_parse': True, 'lazy': 'js:input=JSON.parse(request(input));'}

    @classmethod
    def tearDownClass(cls):
        cls.process.stdin.close()
        cls.process.wait(timeout=8)
        cls.process.stderr.close()
        for server in cls.servers:
            server.shutdown()
            server.server_close()
        cls.temp.cleanup()

    def install(self, rule=None, source='fixture', **changes):
        manifest = {'kind': 'drpy', 'version': 1, 'runtime': 'drpy2-ca23ffdb-1',
            'sourceId': hashlib.sha256(source.encode()).hexdigest(), 'origin': self.origin+'/fixture.js',
            'rule': rule if isinstance(rule,str) else 'var rule = '+json.dumps(rule or self.rule, ensure_ascii=False)+';',
            'headers': {}, 'requestTimeoutMs': 1000, **changes}
        data = json.dumps(manifest, ensure_ascii=False, separators=(',', ':')).encode()
        key = hashlib.sha256(data).hexdigest()
        folder = self.root/key
        folder.mkdir(exist_ok=True)
        (folder/'drpy.json').write_bytes(data)
        return key

    def call(self, key, method, *args):
        body = json.dumps({'version': 1, 'method': method, 'args': args}, ensure_ascii=False).encode()
        req = urllib.request.Request(self.base+'/'+key+'/api/drpy', data=body,
            headers={'Content-Type':'application/json'}, method='POST')
        with urllib.request.urlopen(req, timeout=45) as response:
            return json.load(response)

    def release(self, key):
        req=urllib.request.Request(self.base+'/'+key+'/_release', data=b'', method='POST')
        with urllib.request.urlopen(req, timeout=8) as response:
            return json.load(response)

    def test_01_lifecycle_html_jinja_unicode_detail_play(self):
        key = self.install()
        self.assertEqual(self.call(key,'home',True)['class'][0]['type_id'],'films')
        self.assertEqual(self.call(key,'homeVod')['list'][0]['vod_name'],'HTML fixture')
        listing = self.call(key,'category','films',2,True,{'area':'local'})
        self.assertEqual(listing['list'][0]['vod_name'],'HTML fixturelocal')
        self.assertEqual(self.call(key,'search','中文',False,1)['list'][0]['vod_name'],'中文')
        detail = self.call(key,'detail',listing['list'][0]['vod_id'])['list'][0]
        self.assertEqual(detail['vod_name'],'Fixture detail')
        play = self.call(key,'play','fixture',self.origin+'/resolve',[])
        self.assertEqual(play['parse'],0)
        self.assertEqual(play['header']['X-Fixture'],'ok')
        self.assertFalse(any(p.endswith('.mp4') for p,_ in self.servers[0].requests))

    def test_02_jsonpath_and_crypto_dependencies(self):
        rule={**self.rule, 'url':'/json', 'filter_url':'', '一级':'json:items;name;;;id',
            '二级':'js:VOD={vod_name:md5("fixture"),vod_play_from:"",vod_play_url:""};'}
        key=self.install(rule,'json')
        self.assertEqual(self.call(key,'category','films',1,False,{})['list'][0]['vod_name'],'JSON fixture')
        self.assertEqual(self.call(key,'detail',self.origin+'/detail/42')['list'][0]['vod_name'],hashlib.md5(b'fixture').hexdigest())

    def test_http_rule_encoding_without_response_charset(self):
        # getHtml() in the pinned core creates fresh options without encoding.
        # Exercise its ordinary category path, including the Chinese rule alias.
        for name in ('encoding', '编码'):
            with self.subTest(rule_field=name):
                rule={**self.rule, name:'gbk', 'url':'/encoded?codec=gbk', 'filter_url':''}
                key=self.install(rule,'rule-encoding-'+name)
                try:
                    result=self.call(key,'category','films',1,False,{})
                    self.assertEqual(result['list'][0]['vod_name'],'中文测试')
                finally:
                    self.release(key)

    def test_http_explicit_encoding_overrides_rule_and_response(self):
        rule={**self.rule, 'encoding':'utf-8',
            '二级':'js:VOD={vod_name:pdfh(request(input,{encoding:"gbk"}),"h3&&Text"),vod_play_from:"",vod_play_url:""};'}
        key=self.install(rule,'explicit-encoding')
        try:
            # A per-call override intentionally corrects a mislabelled response.
            result=self.call(key,'detail',self.origin+'/encoded?codec=gbk&charset=utf-8')
            self.assertEqual(result['list'][0]['vod_name'],'中文测试')
        finally:
            self.release(key)

    def test_http_response_charset_overrides_rule_fallback(self):
        for rule_encoding, response_encoding in (('gbk','utf-8'), ('utf-8','gbk')):
            with self.subTest(rule=rule_encoding,response=response_encoding):
                rule={**self.rule, 'encoding':rule_encoding, 'filter_url':'',
                    'url':'/encoded?codec='+response_encoding+'&charset='+response_encoding}
                key=self.install(rule,'response-encoding-'+rule_encoding)
                try:
                    result=self.call(key,'category','films',1,False,{})
                    self.assertEqual(result['list'][0]['vod_name'],'中文测试')
                finally:
                    self.release(key)

    def test_http_utf8_without_declared_encoding(self):
        rule={**self.rule, 'url':'/encoded', 'filter_url':''}
        key=self.install(rule,'default-encoding')
        try:
            result=self.call(key,'category','films',1,False,{})
            self.assertEqual(result['list'][0]['vod_name'],'中文测试')
        finally:
            self.release(key)

    def test_empty_category_sentinel_and_real_no_data_id(self):
        rule={**self.rule,'一级':'js:VODS=[];','搜索':'js:VODS=[];'}
        key=self.install(rule,'empty-category')
        self.assertEqual(self.call(key,'category','films',1,False,{})['list'],[])
        self.release(key)
        rule={**self.rule,'一级':'js:VODS=[{vod_id:"no_data",vod_name:"Real film",vod_pic:"",vod_remarks:""}];'}
        key=self.install(rule,'real-no-data-id')
        self.assertEqual(self.call(key,'category','films',1,False,{})['list'][0]['vod_name'],'Real film')
        self.release(key)

    def test_03_storage_survives_release_and_isolated_by_source(self):
        rule={**self.rule,'二级':'js:let n=Number(getItem("count","0"))+1;setItem("count",String(n));VOD={vod_name:String(n),vod_play_from:"",vod_play_url:""};'}
        one=self.install(rule,'state-one')
        two=self.install(rule,'state-two')
        self.assertEqual(self.call(one,'detail',self.origin+'/detail/42')['list'][0]['vod_name'],'1')
        self.assertTrue(self.release(one)['released'])
        self.assertEqual(self.call(one,'detail',self.origin+'/detail/42')['list'][0]['vod_name'],'2')
        self.assertEqual(self.call(two,'detail',self.origin+'/detail/42')['list'][0]['vod_name'],'1')
        changed=self.install(rule,'state-one',headers={'X-Refresh':'new-manifest'})
        self.assertEqual(self.call(changed,'detail',self.origin+'/detail/42')['list'][0]['vod_name'],'3')

    def test_04_http_timeout_then_recovery(self):
        rule={**self.rule,'二级':'js:VOD=JSON.parse(request(input,{timeout:120}));'}
        key=self.install(rule,'timeout')
        start=time.monotonic()
        with self.assertRaises(urllib.error.HTTPError) as error:
            self.call(key,'detail',self.origin+'/slow')
        self.assertEqual(error.exception.code,422)
        self.assertIn(b'drpy_http_timeout',error.exception.read())
        self.assertLess(time.monotonic()-start,3)
        self.assertEqual(self.call(key,'detail',self.origin+'/detail/42')['list'][0]['vod_name'],'Fixture detail')

    def test_05_auth_redirect_and_request_headers(self):
        rule={**self.rule,'二级':'js:VOD={vod_name:request(input),vod_play_from:"",vod_play_url:""};'}
        key=self.install(rule,'auth',headers={'Authorization':'Bearer synthetic','Cookie':'synthetic=yes','Cookie2':'legacy=synthetic'})
        first=json.loads(self.call(key,'detail',self.origin+'/echo')['list'][0]['vod_name'])
        self.assertEqual(first.get('authorization'),'Bearer synthetic')
        other=json.loads(self.call(key,'detail',self.origin+'/redirect')['list'][0]['vod_name'])
        self.assertNotIn('authorization',other)
        self.assertNotIn('cookie',other)
        self.assertNotIn('cookie2',other)
        direct=json.loads(self.call(key,'detail',self.servers[1].origin+'/echo')['list'][0]['vod_name'])
        self.assertNotIn('authorization',direct)

    def test_06_hash_schema_and_method_rejection(self):
        key=self.install(source='tamper')
        (self.root/key/'drpy.json').write_text('{}')
        with self.assertRaises(urllib.error.HTTPError) as error:self.call(key,'home',True)
        self.assertEqual(error.exception.code,503)
        key=self.install(source='schema',runtime='unknown-fork')
        with self.assertRaises(urllib.error.HTTPError):self.call(key,'home',True)
        key=self.install(source='method')
        with self.assertRaises(urllib.error.HTTPError) as error:self.call(key,'eval','secret')
        self.assertEqual(error.exception.code,400)

    def test_07_more_than_three_idle_sources_evict_safely(self):
        for number in range(5):
            key=self.install(source='idle-'+str(number))
            self.assertEqual(self.call(key,'home',True)['class'][0]['type_id'],'films')

    def test_08_release_cancels_blocked_source(self):
        rule={**self.rule,'二级':'js:VOD=JSON.parse(request(input,{timeout:15000}));'}
        key=self.install(rule,'release',requestTimeoutMs=15000)
        failures=[]
        def pending():
            try:self.call(key,'detail',self.origin+'/slow')
            except Exception as error:failures.append(type(error).__name__)
        thread=threading.Thread(target=pending)
        thread.start();time.sleep(.25)
        start=time.monotonic();self.release(key);thread.join(3)
        self.assertFalse(thread.is_alive())
        self.assertTrue(failures)
        self.assertLess(time.monotonic()-start,3)

    def test_09_ocr_disabled_and_oversized_response(self):
        rule={**self.rule,'二级':'js:OcrApi.classification("synthetic");'}
        key=self.install(rule,'ocr')
        before=len(self.servers[0].requests)
        with self.assertRaises(urllib.error.HTTPError) as error:self.call(key,'detail',self.origin+'/detail/42')
        self.assertEqual(error.exception.code,422)
        self.assertIn(b'drpy_ocr_not_configured',error.exception.read())
        self.assertEqual(len(self.servers[0].requests),before)
        rule={**self.rule,'二级':'js:VOD=JSON.parse(request(input));'}
        key=self.install(rule,'large')
        with self.assertRaises(urllib.error.HTTPError) as error:self.call(key,'detail',self.origin+'/large')
        self.assertEqual(error.exception.code,422)
        self.assertIn(b'drpy_http_response_too_large',error.exception.read())
        with self.assertRaises(urllib.error.HTTPError) as error:self.call(key,'detail',self.origin+'/compressed-large')
        self.assertEqual(error.exception.code,422)
        self.assertIn(b'drpy_http_response_too_large',error.exception.read())

    def test_10_vm_cpu_deadline_and_followup(self):
        rule={**self.rule,'二级':'js:while(true){}'}
        key=self.install(rule,'cpu')
        start=time.monotonic()
        with self.assertRaises(urllib.error.HTTPError) as error:self.call(key,'detail',self.origin+'/detail/42')
        self.assertEqual(error.exception.code,422)
        self.assertIn(b'drpy_execution_timeout',error.exception.read())
        self.assertLess(time.monotonic()-start,23)
        self.assertEqual(self.call(key,'home',True)['class'][0]['type_id'],'films')

    def test_11_mixed_active_workers_obey_three_limit(self):
        bundle=b'exports.start=async()=>{const server=catServerFactory((req,res)=>{});server.listen(0,"127.0.0.1")};'
        cat=hashlib.sha256(bundle).hexdigest()
        folder=self.root/cat;folder.mkdir(exist_ok=True);(folder/'index.cjs').write_bytes(bundle)
        rule={**self.rule,'二级':'js:VOD=JSON.parse(request(input,{timeout:15000}));'}
        keys=[self.install(rule,'active-'+str(i),requestTimeoutMs=15000) for i in range(2)]
        threads=[]
        def pending(key):
            try:
                if key==cat:urllib.request.urlopen(self.base+'/'+cat+'/api/hold',timeout=5).close()
                else:self.call(key,'detail',self.origin+'/slow')
            except Exception:pass
        try:
            for key in keys:
                self.call(key,'home',True)
                count=sum(p=='/slow' for p,_ in self.servers[0].requests)
                thread=threading.Thread(target=pending,args=(key,));thread.start();threads.append(thread)
                until=time.monotonic()+2
                while sum(p=='/slow' for p,_ in self.servers[0].requests)==count and time.monotonic()<until:time.sleep(.01)
            thread=threading.Thread(target=pending,args=(cat,));thread.start();threads.append(thread)
            time.sleep(.15)
            fourth=self.install(source='fourth-active')
            # Once a DRPY request finishes its slot can be reused. The active
            # CatPaw server stays protected while the fourth source waits.
            self.assertEqual(self.call(fourth,'home',True)['class'][0]['type_id'],'films')
        finally:
            for key in keys+[cat]:self.release(key)
            for thread in threads:thread.join(3)
        self.assertTrue(all(not t.is_alive() for t in threads))

    def test_12_proxy_text_binary_ranges_and_release(self):
        playlist='#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="?do=js&kind=key"\n?do=js&kind=key\n'
        rule={**self.rule,'lazy':'js:input={parse:0,url:getProxyUrl()+"&kind=playlist"};',
            'proxy_rule':'js:input=input.kind==="key"?[200,"application/octet-stream",[0,1,255,42]]:[200,"application/vnd.apple.mpegurl",'+json.dumps(playlist)+'];'}
        key=self.install(rule,'local-proxy')
        try:
            play=self.call(key,'play','fixture','unused',[])
            self.assertTrue(play['url'].startswith(self.base+'/'+key+'/proxy?'))
            with urllib.request.urlopen(play['url'],timeout=8) as response:
                text=response.read().decode()
            self.assertIn(self.base+'/'+key+'/proxy?do=js&kind=key',text)
            with urllib.request.urlopen(urllib.request.Request(play['url'],headers={'Range':'bytes=0-7'}),timeout=8) as response:
                self.assertEqual(response.status,200)
                self.assertEqual(response.read().decode(),text)
            target=play['url'].replace('kind=playlist','kind=key')
            with urllib.request.urlopen(urllib.request.Request(target,headers={'Range':'bytes=1-2'}),timeout=8) as response:
                self.assertEqual(response.status,206)
                self.assertEqual(response.headers['Content-Range'],'bytes 1-2/4')
                self.assertEqual(response.read(),bytes([1,255]))
            with urllib.request.urlopen(urllib.request.Request(target,method='HEAD'),timeout=8) as response:
                self.assertEqual(response.headers['Content-Length'],'4')
                self.assertEqual(response.read(),b'')
            with self.assertRaises(urllib.error.HTTPError) as failure:
                urllib.request.urlopen(urllib.request.Request(target,headers={'Range':'bytes=99-100'}),timeout=8)
            self.assertEqual(failure.exception.code,416)
            for number in range(4):
                other=self.install(source='proxy-background-'+str(number))
                self.call(other,'home',True);self.release(other)
            with urllib.request.urlopen(target,timeout=8) as response:self.assertEqual(response.read(),bytes([0,1,255,42]))
        finally:self.release(key)

    def test_local_package_nested_helpers_and_json(self):
        rule={**self.rule,'预处理':'js:require("./helpers/entry.js");',
            '二级':'js:VOD={vod_name:fixtureHelper+JSON.parse(request("pkg://archive/data.json")).name,vod_play_from:"",vod_play_url:""};'}
        modules={'pkg://archive/helpers/entry.js':'require("./nested/value.js");',
            'pkg://archive/helpers/nested/value.js':'globalThis.fixtureHelper="local:";',
            'pkg://archive/data.json':'{"name":"中文"}'}
        key=self.install(rule,'local-modules',origin='pkg://archive/main.js',modules=modules)
        try:self.assertEqual(self.call(key,'detail',self.origin+'/detail/42')['list'][0]['vod_name'],'local:中文')
        finally:self.release(key)
        key=self.install(rule,'missing-module',origin='pkg://archive/main.js',modules={})
        with self.assertRaises(urllib.error.HTTPError) as error:self.call(key,'home',True)
        self.assertIn(b'drpy_local_module_missing',error.exception.read())
        self.release(key)
        key=self.install(rule,'foreign-module',origin='pkg://archive/main.js',modules={'pkg://other/helper.js':'secret'})
        with self.assertRaises(urllib.error.HTTPError) as error:self.call(key,'home',True)
        self.assertEqual(error.exception.code,503)

    def test_embedded_reset_releases_workers_and_preserves_router(self):
        key=self.install({**self.rule,'预处理':'js:setItem("boots",String(Number(getItem("boots","0"))+1));',
            '二级':'js:VOD={vod_name:getItem("boots"),vod_play_from:"",vod_play_url:""};'},'reset-state')
        self.assertEqual(self.call(key,'detail',self.origin+'/detail/42')['list'][0]['vod_name'],'1')
        req=urllib.request.Request(self.base+'/_reset',data=b'',method='POST')
        with urllib.request.urlopen(req,timeout=8) as response:self.assertEqual(json.load(response),{'reset':True})
        self.assertEqual(self.call(key,'detail',self.origin+'/detail/42')['list'][0]['vod_name'],'2')
        self.release(key)

    def test_13_upstream_remote_helper_uses_same_bounded_transport(self):
        rule={**self.rule,'二级':'js:require(HOST+"/helper.js");VOD={vod_name:globalThis.fixtureHelper,vod_play_from:"",vod_play_url:""};'}
        key=self.install(rule,'helper')
        self.assertEqual(self.call(key,'detail',self.origin+'/detail/42')['list'][0]['vod_name'],'loaded actual remote helper')

    def test_14_let_const_and_comment_rule_initialization(self):
        for declaration in ['var','let','const']:
            source='// a comment mentioning var rule must not be rewritten\n'+declaration+' rule='+json.dumps(self.rule)+';\n// final comment'
            key=self.install(source='declaration-'+declaration,rule=source)
            self.assertEqual(self.call(key,'home',True)['class'][0]['type_id'],'films')

    def test_15_six_concurrent_searches_all_finish(self):
        results={};errors=[]
        def search(number):
            try:
                key=self.install(source='concurrent-'+str(number))
                results[number]=self.call(key,'search','concurrent-'+str(number),False,1)['list'][0]['vod_name']
            except Exception as error:errors.append(str(error))
        threads=[threading.Thread(target=search,args=(i,)) for i in range(6)]
        for thread in threads:thread.start()
        for thread in threads:thread.join(10)
        self.assertEqual(errors,[])
        self.assertEqual(results,{i:'concurrent-'+str(i) for i in range(6)})

    def test_16_client_disconnect_stops_unshared_worker(self):
        rule={**self.rule,'预处理':'js:setItem("starts",String(Number(getItem("starts","0"))+1));',
            '二级':'js:if(input.endsWith("/slow"))request(input,{timeout:15000});VOD={vod_name:getItem("starts"),vod_play_from:"",vod_play_url:""};'}
        key=self.install(rule,'disconnect',requestTimeoutMs=15000)
        self.call(key,'home',True)
        endpoint=urllib.parse.urlparse(self.base)
        connection=http.client.HTTPConnection(endpoint.hostname,endpoint.port,timeout=5)
        before=sum(p=='/slow' for p,_ in self.servers[0].requests)
        connection.request('POST',endpoint.path+'/'+key+'/api/drpy',
            json.dumps({'version':1,'method':'detail','args':[self.origin+'/slow']}),{'Content-Type':'application/json'})
        until=time.monotonic()+3
        while sum(p=='/slow' for p,_ in self.servers[0].requests)==before and time.monotonic()<until:time.sleep(.01)
        self.assertGreater(sum(p=='/slow' for p,_ in self.servers[0].requests),before)
        connection.close()
        time.sleep(.15)
        self.assertEqual(self.call(key,'detail',self.origin+'/detail/42')['list'][0]['vod_name'],'2')


if __name__=='__main__':unittest.main()
