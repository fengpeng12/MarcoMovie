"""Bounded data-only plugin bootstrap checks. Fixtures are synthetic, never user JARs."""
from pathlib import Path
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
import shutil
import struct
import subprocess
import tempfile
import time
import threading
import unittest
import warnings
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
NODE = os.environ.get('MARCOMOVIE_NODE') or shutil.which('node')

class AdapterFixture(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        self.server.requests.append(self.path)
        if self.path == '/' and getattr(self.server,'home_failure',False):
            body='<html>Unavailable</html>'
        elif self.path.startswith('/list-13'):
            body='<html>Filter service unavailable</html>'
        elif self.path.startswith('/list-'):
            body = '<ul class="list_filter"><li><div><a>全部</a><a>动作</a></div></li><li><div><a>全部</a><a>2025</a></div></li><li><div><a>按时间</a><a>按评分</a></div></li></ul>'
        elif self.path.startswith('/v/'):
            body = '<h1 class="v_title">Fixture</h1><ul class="tab_control"><li>Line</li></ul><ul class="play_list"><li><a href="/p/42">One</a></li></ul>'
        elif self.path.startswith('/p/'):
            modes = {'wrapper':self.server.origin+'/iframe?url=https%3A%2F%2Fexample.invalid%2Fvideo.m3u8',
                     'direct':'http://127.0.0.1:9/media.m3u8?token=fixture',
                     'query':'http://127.0.0.1:9/unknown?url=video.m3u8',
                     'foreign':self.server.origin.replace('127.0.0.1','127.0.0.1.example.invalid')+'/iframe?url=video.m3u8',
                     'userinfo':self.server.origin.replace('://','://fixture:secret@')+'/iframe',
                     'javascript':'javascript:void(0)', 'file':'file:///fixture.m3u8', 'ftp':'ftp://example.invalid/video.m3u8'}
            body = '<iframe src="'+modes.get(self.path.split('/')[-1], self.server.origin+'/iframe')+'"></iframe>'
        elif self.path.startswith('/iframe'):
            body = '<script>window.__HHJX_BOOTSTRAP__={"url":"fixture-token","t":42,"key":"fixture-key"};</script>'
        else:
            body = '<ul class="nav_row"><li><a href="/list-12.html">Fixture</a></li></ul><div class="item"><a class="title" href="/v/42">Fixture</a><a class="cover" data-bg="/poster.png"></a><span class="desc">Test</span></div>'
            if getattr(self.server,'partial_filter_failure',False):
                body=body.replace('</ul>','<li><a href="/list-13.html">Unavailable filters</a></li></ul>',1)
        data = body.encode()
        self.send_response(200); self.send_header('Content-Length', str(len(data))); self.send_header('Content-Type', 'text/html; charset=utf-8'); self.end_headers(); self.wfile.write(data)

    def do_POST(self):
        if self.headers.get('Transfer-Encoding') == 'chunked':
            chunks = []
            while True:
                size = int(self.rfile.readline().strip(), 16)
                if not size:
                    self.rfile.readline(); break
                chunks.append(self.rfile.read(size)); self.rfile.read(2)
            body = b''.join(chunks)
        else:
            body = self.rfile.read(int(self.headers['Content-Length']))
        self.server.payload = json.loads(body)
        self.server.parser_headers = dict(self.headers)
        data = json.dumps({'url': getattr(self.server,'media_url',self.server.origin+'/never-download.mp4')}).encode()
        self.send_response(200); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)

def uleb(value):
    result = bytearray()
    while True:
        byte = value & 127
        value >>= 7
        result.append(byte | (128 if value else 0))
        if not value:
            return result

def checksum(data):
    data[12:32] = hashlib.sha1(data[32:]).digest()
    struct.pack_into('<I', data, 8, zlib.adler32(data[12:]))
    return bytes(data)

def fixture_dex():
    strings = ['Lfixture/Source;', 'Ljava/lang/Object;', 'Ljava/lang/String;', 'V',
               '<init>', 'yq', 'SN', 'http://127.0.0.1:9', 'http://127.0.0.1:9/parse']
    offsets = {}; position = 112
    for name, count, size in [('strings', len(strings), 4), ('types', 4, 4), ('protos', 1, 12),
                              ('fields', 2, 8), ('methods', 2, 8), ('classes', 1, 32)]:
        offsets[name] = position
        position += count * size
    data = bytearray(position)
    for i, text in enumerate(strings):
        struct.pack_into('<I', data, offsets['strings']+i*4, len(data))
        data.extend(uleb(len(text)) + text.encode() + b'\0')
    while len(data) % 4:
        data.append(0)
    code = len(data)
    words = [0x1070, 0, 1, 0x001a, 7, 0x105b, 0, 0x001a, 8, 0x105b, 1, 0x000e]
    data.extend(struct.pack('<4H2I', 2, 1, 1, 0, 0, len(words)))
    data.extend(struct.pack('<'+'H'*len(words), *words))
    class_data = len(data)
    data.extend(bytes([0, 2, 1, 0, 0, 2, 1, 2, 1]) + uleb(0x10001) + uleb(code))
    data[:8] = b'dex\n035\0'
    struct.pack_into('<3I', data, 32, len(data), 112, 0x12345678)
    for header, key, count in [(56, 'strings', len(strings)), (64, 'types', 4), (72, 'protos', 1),
                               (80, 'fields', 2), (88, 'methods', 2), (96, 'classes', 1)]:
        struct.pack_into('<2I', data, header, count, offsets[key])
    struct.pack_into('<4I', data, offsets['types'], 0, 1, 2, 3)
    struct.pack_into('<3I', data, offsets['protos'], 3, 3, 0)
    struct.pack_into('<HHIHHI', data, offsets['fields'], 0, 2, 5, 0, 2, 6)
    struct.pack_into('<HHIHHI', data, offsets['methods'], 1, 0, 4, 0, 0, 4)
    struct.pack_into('<8I', data, offsets['classes'], 0, 1, 1, 0, 0xffffffff, 0, class_data, 0)
    return checksum(data), code

def archive(entries, compression=zipfile.ZIP_DEFLATED):
    out = io.BytesIO()
    with warnings.catch_warnings():
        warnings.simplefilter('ignore')
        with zipfile.ZipFile(out, 'w', compression=compression) as z:
            for name, body in entries:
                z.writestr(name, body)
    return out.getvalue()

class ReaderChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def run_reader(self, body, expression):
        file = self.root/'fixture.bin'
        file.write_bytes(body)
        js = "const fs=require('node:fs');const x=require(process.argv[1]);const b=fs.readFileSync(process.argv[2]);try {console.log(JSON.stringify({value:" + expression + "}));} catch(e){console.log(JSON.stringify({error:e.message}));}"
        out = subprocess.check_output([NODE, '--jitless', '-e', js, str(ROOT/'shared/catpaw/drpy-guard-extractor.cjs'), str(file)], stderr=subprocess.DEVNULL)
        return json.loads(out)

    def test_literal_constructor(self):
        data, _ = fixture_dex()
        self.assertEqual(self.run_reader(data, "new x.Dex(b).literalFields('Lfixture/Source;')")['value'],
                         {'yq': 'http://127.0.0.1:9', 'SN': 'http://127.0.0.1:9/parse'})

    def test_unknown_constructor_opcode(self):
        data, code = fixture_dex(); data = bytearray(data); data[code+16] = 0x28
        self.assertIn('error', self.run_reader(checksum(data), "new x.Dex(b).literalFields('Lfixture/Source;')"))

    def test_unknown_class(self):
        self.assertIn('error', self.run_reader(fixture_dex()[0], "new x.Dex(b).literalFields('Lmissing/Class;')"))

    def test_dex_checksum_and_offset(self):
        data = bytearray(fixture_dex()[0]); data[-1] ^= 1
        self.assertIn('error', self.run_reader(data, 'new x.Dex(b)'))
        data = bytearray(fixture_dex()[0]); struct.pack_into('<I', data, 60, 0xffffffff)
        self.assertIn('error', self.run_reader(checksum(data), 'new x.Dex(b)'))

    def test_zip_deflate_and_stored(self):
        for compression in (zipfile.ZIP_DEFLATED, zipfile.ZIP_STORED):
            self.assertEqual(self.run_reader(archive([('payload', b'fixture')], compression), "x.zipMember(b,'payload').toString()")['value'], 'fixture')

    def test_zip_duplicate_missing_and_traversal(self):
        for entries in [[('payload', b'a'), ('payload', b'b')], [('other', b'a')], [('../bad', b'a'), ('payload', b'b')]]:
            self.assertIn('error', self.run_reader(archive(entries), "x.zipMember(b,'payload')"))

    def test_zip_crc_and_overlap(self):
        data = bytearray(archive([('payload', b'fixture')], zipfile.ZIP_STORED)); data[37] ^= 1
        self.assertIn('error', self.run_reader(data, "x.zipMember(b,'payload')"))
        data = bytearray(archive([('payload', b'fixture')], zipfile.ZIP_STORED)); cd = data.index(b'PK\x01\x02'); struct.pack_into('<I', data, cd+42, cd)
        self.assertIn('error', self.run_reader(data, "x.zipMember(b,'payload')"))

    def test_guard_transform_and_unknown_version(self):
        self.assertTrue(self.run_reader(bytes(range(256)), 'x.unwrapGuard(x.unwrapGuard(b)).equals(b)')['value'])
        self.assertEqual(self.run_reader(archive([('classes.dex', fixture_dex()[0])]), 'x.extractKnownPlugin(b)')['error'], 'guard_artifact_unsupported')

class HostChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(); cls.root = Path(cls.temp.name)
        (cls.root/'imports').mkdir()
        cls.ready = cls.root/'ready.json'
        cls.process = subprocess.Popen([NODE, '--jitless', str(ROOT/'shared/catpaw/host.cjs'), str(cls.root), str(cls.ready)], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        until = time.monotonic()+8
        while not cls.ready.exists():
            if cls.process.poll() is not None or time.monotonic() > until:
                raise AssertionError('Host startup failed')
            time.sleep(.02)
        cls.state = json.loads(cls.ready.read_text())

    @classmethod
    def tearDownClass(cls):
        cls.process.stdin.close(); cls.process.wait(timeout=8); cls.temp.cleanup()

    def request(self, body, headers=None, path=None):
        connection = http.client.HTTPConnection('127.0.0.1', self.state['port'], timeout=8)
        connection.request('POST', path or '/'+self.state['secret']+'/_port-bootstrap', json.dumps(body).encode(), headers or {'Content-Type':'application/json'})
        response = connection.getresponse(); status, result = response.status, json.loads(response.read()); connection.close()
        time.sleep(.03)  # Host releases the worker before a subsequent independent test.
        return status, result

    def payload(self, hash_value):
        return {'version':1, 'adapter':'dm84-v1', 'artifactHash':hash_value}

    def test_unknown_artifact_is_distinct(self):
        value = b'synthetic unknown artifact'; digest = hashlib.sha256(value).hexdigest()
        (self.root/'imports'/(digest+'.jar')).write_bytes(value)
        self.assertEqual(self.request(self.payload(digest)), (422, {'error':'guard_artifact_unsupported'}))

    def test_digest_mismatch_and_missing(self):
        (self.root/'imports'/('b'*64+'.jar')).write_bytes(b'tampered')
        self.assertEqual(self.request(self.payload('b'*64)), (422, {'error':'guard_artifact_integrity'}))
        self.assertEqual(self.request(self.payload('c'*64)), (422, {'error':'guard_artifact_invalid'}))

    def test_exact_schema(self):
        for body in [None, [], self.payload('../bad'), self.payload('a'*64)|{'path':'other'}, self.payload('a'*64)|{'adapter':'other'}]:
            self.assertEqual(self.request(body), (400, {'error':'bootstrap_request'}))

    def test_t4_extension_contract(self):
        value = b'synthetic unknown T4 artifact'; digest = hashlib.sha256(value).hexdigest()
        (self.root/'imports'/(digest+'.jar')).write_bytes(value)
        body = self.payload(digest) | {'adapter':'t4-v1'}
        self.assertEqual(self.request(body), (400, {'error':'bootstrap_request'}))
        for extension in [None, {}, '', ' ', 'x'*16385, '\u6d4b'*5462]:
            self.assertEqual(self.request(body | {'extension':extension}), (400, {'error':'bootstrap_request'}))
        # A valid bounded extension reaches the data-only artifact verifier.
        self.assertEqual(self.request(body | {'extension':'YQ=='}), (422, {'error':'guard_artifact_unsupported'}))
        self.assertEqual(self.request(self.payload(digest) | {'extension':'YQ=='}), (400, {'error':'bootstrap_request'}))

    def test_fy_exact_artifact_contract(self):
        value = b'synthetic unknown FY artifact'; digest = hashlib.sha256(value).hexdigest()
        (self.root/'imports'/(digest+'.jar')).write_bytes(value)
        body = self.payload(digest) | {'adapter':'fy-v1'}
        self.assertEqual(self.request(body), (422, {'error':'guard_artifact_unsupported'}))
        self.assertEqual(self.request(body | {'extension':'unexpected'}), (400, {'error':'bootstrap_request'}))

    def test_capability_origin_and_body_limit(self):
        self.assertEqual(self.request({}, path='/wrong/_port-bootstrap')[0], 403)
        self.assertEqual(self.request({}, headers={'Origin':'http://127.0.0.1:9'})[0], 403)
        self.assertEqual(self.request({'large':'x'*(18*1024)}), (400, {'error':'bootstrap_request'}))

    def test_busy_and_disconnect_release(self):
        pending = http.client.HTTPConnection('127.0.0.1', self.state['port'], timeout=8)
        pending.putrequest('POST', '/'+self.state['secret']+'/_port-bootstrap')
        pending.putheader('Content-Length', '100'); pending.endheaders(); pending.send(b'{')
        time.sleep(.05)
        self.assertEqual(self.request({}), (429, {'error':'bootstrap_busy'}))
        pending.close(); time.sleep(.1)
        self.assertEqual(self.request({}), (400, {'error':'bootstrap_request'}))

    def test_incomplete_body_deadline(self):
        pending = http.client.HTTPConnection('127.0.0.1', self.state['port'], timeout=8)
        pending.putrequest('POST', '/'+self.state['secret']+'/_port-bootstrap')
        pending.putheader('Content-Length', '100'); pending.endheaders(); pending.send(b'{')
        response = pending.getresponse()
        self.assertEqual((response.status, json.loads(response.read())), (504, {'error':'bootstrap_timeout'}))
        pending.close()

    def test_parameterized_adapter_real_drpy_router(self):
        fixture = ThreadingHTTPServer(('127.0.0.1', 0), AdapterFixture)
        fixture.daemon_threads = True
        fixture.requests = []
        fixture.origin = 'http://127.0.0.1:'+str(fixture.server_port)
        threading.Thread(target=fixture.serve_forever, daemon=True).start()
        try:
            config = {'origin':fixture.origin, 'parser':fixture.origin+'/parse', 'parserOrigin':fixture.origin, 'userAgent':'Fixture-UA'}
            js = "console.log(JSON.stringify(require(process.argv[1])(JSON.parse(process.argv[2]))))"
            rule = json.loads(subprocess.check_output([NODE, '--jitless', '-e', js, str(ROOT/'shared/catpaw/drpy-dm84-adapter.cjs'), json.dumps(config)], stderr=subprocess.DEVNULL))
            manifest = {'kind':'drpy','version':1,'runtime':'drpy2-ca23ffdb-1', 'sourceId':'a'*64,
                        'origin':fixture.origin+'/rule.js','rule':rule,'headers':{},'requestTimeoutMs':2000}
            data = json.dumps(manifest).encode(); digest = hashlib.sha256(data).hexdigest()
            (self.root/digest).mkdir(); (self.root/digest/'drpy.json').write_bytes(data)
            path = '/'+self.state['secret']+'/'+digest+'/api/drpy'
            def call(method, args):
                status, value = self.request({'version':1,'method':method,'args':args}, path=path)
                self.assertEqual(status, 200, value)
                return value
            home = call('home', [True]); self.assertEqual(home['class'][0]['type_id'], '12')
            self.assertEqual(len(home['filters']['12']), 3)
            self.assertEqual(call('homeVod', [])['list'][0]['vod_name'], 'Fixture')
            category = call('category', ['12',1,True,{'by':'score','year':'2025','type':''}])
            self.assertEqual(category['list'][0]['vod_name'], 'Fixture')
            self.assertEqual(call('search', ['Fixture',False,1])['list'][0]['vod_name'], 'Fixture')
            detail = call('detail', [category['list'][0]['vod_id']])['list'][0]
            self.assertEqual(detail['vod_play_from'], 'Line')
            play = call('play', ['Line',detail['vod_play_url'].split('$',1)[1],[]])
            self.assertEqual(play['parse'], 0); self.assertEqual(play['url'], fixture.origin+'/never-download.mp4')
            self.assertEqual(fixture.payload, {'url':'fixture-token','t':42,'key':'fixture-key','client_fallback':False})
            self.assertEqual({k.lower():v for k,v in fixture.parser_headers.items()}['origin'], fixture.origin)
            wrapper = call('play', ['Line',fixture.origin+'/p/wrapper',[]])
            self.assertEqual(wrapper['parse'],0)
            self.assertEqual(wrapper['url'],fixture.origin+'/never-download.mp4')
            self.assertTrue(any(path.startswith('/iframe?url=') for path in fixture.requests))
            direct = call('play', ['Line',fixture.origin+'/p/direct',[]])
            self.assertEqual(direct['parse'],0)
            self.assertEqual(direct['url'],'http://127.0.0.1:9/media.m3u8?token=fixture')
            for mode in ('query','foreign','userinfo','javascript','file','ftp'):
                status,value = self.request({'version':1,'method':'play','args':['Line',fixture.origin+'/p/'+mode,[]]},path=path)
                self.assertEqual(status,422,(mode,value))
                self.assertEqual(value['error'],'drpy_media_unresolved' if mode in ('query','foreign') else 'drpy_media_protocol')
                self.assertNotIn('secret',json.dumps(value))
            for unsafe in ['file:///fixture.mp4',fixture.origin.replace('://','://fixture:secret@')+'/media.mp4']:
                fixture.media_url=unsafe
                status,value=self.request({'version':1,'method':'play','args':['Line',fixture.origin+'/p/42',[]]},path=path)
                self.assertEqual((status,value),(422,{'error':'drpy_media_protocol'}))
        finally:
            fixture.shutdown(); fixture.server_close()

    def test_partial_filter_failure_preserves_catalog(self):
        fixture=ThreadingHTTPServer(('127.0.0.1',0),AdapterFixture)
        fixture.daemon_threads=True;fixture.origin='http://127.0.0.1:'+str(fixture.server_port)
        fixture.requests=[];fixture.partial_filter_failure=True
        threading.Thread(target=fixture.serve_forever,daemon=True).start()
        try:
            config={'origin':fixture.origin,'parser':fixture.origin+'/parse','parserOrigin':fixture.origin,'userAgent':'Fixture'}
            js="console.log(JSON.stringify(require(process.argv[1])(JSON.parse(process.argv[2]))))"
            rule=json.loads(subprocess.check_output([NODE,'--jitless','-e',js,str(ROOT/'shared/catpaw/drpy-dm84-adapter.cjs'),json.dumps(config)],stderr=subprocess.DEVNULL))
            def install(source_id):
                manifest={'kind':'drpy','version':1,'runtime':'drpy2-ca23ffdb-1','sourceId':source_id,
                          'origin':fixture.origin+'/rule.js','rule':rule,'headers':{},'requestTimeoutMs':2000}
                data=json.dumps(manifest).encode();digest=hashlib.sha256(data).hexdigest()
                (self.root/digest).mkdir();(self.root/digest/'drpy.json').write_bytes(data)
                return '/'+self.state['secret']+'/'+digest+'/api/drpy'
            api=install('f'*64)
            status,home=self.request({'version':1,'method':'home','args':[True]},path=api)
            self.assertEqual(status,200);self.assertEqual(len(home['class']),2)
            self.assertEqual(len(home['filters']['12']),3);self.assertEqual(home['filters']['13'],[])
            status,recommendations=self.request({'version':1,'method':'homeVod','args':[]},path=api)
            self.assertEqual(status,200);self.assertEqual(recommendations['list'][0]['vod_name'],'Fixture')
            status,category=self.request({'version':1,'method':'category','args':['13',1,True,{}]},path=api)
            self.assertEqual(status,200);self.assertTrue(category['list'])
            fixture.home_failure=True
            failed_api=install('0'*64)
            self.assertEqual(self.request({'version':1,'method':'home','args':[True]},path=failed_api),
                             (422,{'error':'drpy_source_unavailable'}))
        finally:
            fixture.shutdown();fixture.server_close()

class WorkerBoundaryChecks(unittest.TestCase):
    """Fault injection changes only the worker, exercising the real host boundary."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.root = Path(self.temp.name)
        (self.root/'imports').mkdir()
        shutil.copyfile(ROOT/'shared/catpaw/host.cjs', self.root/'host.cjs')
        (self.root/'drpy-bootstrap-worker.cjs').write_text("const {workerData}=require('node:worker_threads');require('node:fs').writeFileSync(workerData.file+'.started','1');while(true){}", encoding='utf-8')
        self.ready = self.root/'ready.json'
        self.process = subprocess.Popen([NODE,'--jitless',str(self.root/'host.cjs'),str(self.root),str(self.ready)],stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        until = time.monotonic()+8
        while not self.ready.exists():
            if self.process.poll() is not None or time.monotonic() > until:
                raise AssertionError('Fault-injection host startup failed')
            time.sleep(.02)
        self.state = json.loads(self.ready.read_text())

    def tearDown(self):
        self.process.stdin.close(); self.process.wait(timeout=8); self.temp.cleanup()

    def start_call(self):
        connection = http.client.HTTPConnection('127.0.0.1',self.state['port'],timeout=8)
        body = {'version':1,'adapter':'dm84-v1','artifactHash':'d'*64}
        connection.request('POST','/'+self.state['secret']+'/_port-bootstrap',json.dumps(body))
        until = time.monotonic()+2
        while not (self.root/'imports'/('d'*64+'.jar.started')).exists():
            if time.monotonic() > until:
                raise AssertionError('Worker did not start')
            time.sleep(.01)
        return connection

    def test_cpu_deadline_and_responsive_router(self):
        start = time.monotonic(); connection = self.start_call()
        health = http.client.HTTPConnection('127.0.0.1',self.state['port'],timeout=1)
        health.request('GET','/'+self.state['secret']+'/health')
        response = health.getresponse(); self.assertEqual(response.status,200); response.read(); health.close()
        response = connection.getresponse()
        self.assertEqual((response.status,json.loads(response.read())),(504,{'error':'bootstrap_timeout'}))
        self.assertLess(time.monotonic()-start,5); connection.close()

    def test_disconnect_terminates_busy_worker(self):
        connection = self.start_call(); connection.close(); time.sleep(.15)
        check = http.client.HTTPConnection('127.0.0.1',self.state['port'],timeout=2)
        check.request('POST','/'+self.state['secret']+'/_port-bootstrap','{}')
        response = check.getresponse()
        self.assertEqual((response.status,json.loads(response.read())),(400,{'error':'bootstrap_request'}))
        check.close()

if __name__ == '__main__':
    unittest.main(verbosity=2)
