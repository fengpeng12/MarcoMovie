"""Exercise the real Node host with synthetic, locally owned subscription bundles."""
from pathlib import Path
import hashlib
import http.cookiejar
import json
import os
import shlex
import shutil
import subprocess
import tempfile
import time
import unittest
import urllib.request
import urllib.error

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = r'''
const http = require('node:http');
exports.start = async () => {
  const server = catServerFactory(async (req,res) => {
    const base = 'http://127.0.0.1:' + server.address().port;
    if (req.url === '/t4') {
      res.setHeader('Content-Type','application/json');
      res.end(JSON.stringify({sites:[{key:'demo',name:'Demo',type:4,api:base+'/api/demo'}]}));
    } else if (req.url === '/api/demo?playlist') {
      res.setHeader('Content-Type','application/vnd.apple.mpegurl');
      res.end('#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="/api/key"\n../api/segment.ts\n');
    } else if (req.url === '/api/segment.ts') {
      res.setHeader('Content-Type','video/mp2t'); res.end(Buffer.from([0,1,255,42]));
    } else if (req.url === '/website') {
      res.setHeader('Content-Type','text/html'); res.end('<title>Local settings</title>');
    } else if (req.url === '/api/network') {
      const response = await fetch(base+'/api/segment.ts');
      res.end(Buffer.from(await response.arrayBuffer()));
    } else if (req.url === '/api/redirect') {
      res.writeHead(302,{Location:'/api/segment.ts'});res.end();
    } else if (req.url === '/api/demo?play=fixture') {
      res.setHeader('Content-Type','application/json');
      res.end(JSON.stringify({parse:0,url:base+'/spider/demo/3/proxy/token/hls/index.m3u8?sig=fixture'}));
    } else if (req.url === '/spider/demo/3/proxy/token/hls/index.m3u8?sig=fixture') {
      res.setHeader('Content-Type','application/vnd.apple.mpegurl');
      res.end('#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="../key?sig=fixture"\n../segment.ts?sig=fixture\n');
    } else if (/^\/spider\/demo\/3\/proxy\/token\/(key|segment\.ts)\?sig=fixture$/.test(req.url)) {
      res.setHeader('Content-Type','application/octet-stream');res.end(Buffer.from([0,1,255,42]));
    } else if (req.url === '/api/demo?headers') {
      res.setHeader('Content-Type','application/json');res.end(JSON.stringify(req.headers));
    } else {res.statusCode=404;res.end();}
  });
  await new Promise(resolve => server.listen(9321,'0.0.0.0',resolve));
};
'''


class HostChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.node = os.environ.get('MARCOMOVIE_NODE') or shutil.which('node')
        if not cls.node:
            raise RuntimeError('Node is required for host regression checks')
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name)
        cls.hash = cls.install(FIXTURE)
        cls.ready = cls.root/'ready.json'
        cls.process = subprocess.Popen([cls.node, *shlex.split(os.environ.get('MARCOMOVIE_NODE_FLAGS','')), str(ROOT/'shared/catpaw/host.cjs'),
                                        str(cls.root), str(cls.ready)], stdin=subprocess.PIPE,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        deadline = time.monotonic()+8
        while not cls.ready.exists():
            if cls.process.poll() is not None or time.monotonic()>deadline:
                raise AssertionError('Node did not start')
            time.sleep(.02)
        state = json.loads(cls.ready.read_text())
        cls.origin = f'http://127.0.0.1:{state["port"]}'
        cls.base = cls.origin+'/'+state['secret']

    @classmethod
    def install(cls, source):
        data = source.encode()
        key = hashlib.sha256(data).hexdigest()
        folder = cls.root/key
        folder.mkdir(exist_ok=True)
        (folder/'index.cjs').write_bytes(data)
        return key

    @classmethod
    def tearDownClass(cls):
        cls.process.stdin.close()
        cls.process.wait(timeout=8)
        cls.process.stderr.close()
        cls.temp.cleanup()

    def get(self, path, **headers):
        return urllib.request.urlopen(urllib.request.Request(self.base+path, headers=headers), timeout=8)

    def test_01_import_rewrites_ephemeral_backend(self):
        with self.get('/'+self.hash+'/t4') as response:
            row = json.load(response)['sites'][0]
        self.assertEqual(row['api'], self.base+'/'+self.hash+'/api/demo')

    def test_02_rejects_missing_capability_and_browser_origin(self):
        for address,headers in [(self.origin+'/health',{}),(self.base+'/health',{'Origin':'https://example.test'})]:
            with self.assertRaises(urllib.error.HTTPError) as failure:
                urllib.request.urlopen(urllib.request.Request(address,headers=headers))
            self.assertEqual(failure.exception.code,403)

    def test_03_playlist_keys_and_segments_keep_subscription(self):
        with self.get('/'+self.hash+'/api/demo?playlist') as response:
            body=response.read().decode()
        self.assertIn(self.base+'/'+self.hash+'/api/key',body)
        self.assertIn(self.base+'/'+self.hash+'/api/segment.ts',body)

    def test_04_binary_and_relative_redirect(self):
        with self.get('/'+self.hash+'/api/redirect') as response:
            self.assertEqual(response.read(),bytes([0,1,255,42]))

    def test_05_no_ambient_credentials_or_admin_routes(self):
        with self.get('/'+self.hash+'/api/demo?headers',Authorization='secret',Cookie='secret') as response:
            headers=json.load(response)
        self.assertNotIn('authorization',headers)
        self.assertNotIn('cookie',headers)
        with self.assertRaises(urllib.error.HTTPError) as failure:
            self.get('/'+self.hash+'/website/subscriptions')
        self.assertEqual(failure.exception.code,403)

    def test_06_verified_file_and_worker_failure(self):
        key=self.install('exports.start=()=>{throw Error("private details")};')
        with self.assertRaises(urllib.error.HTTPError) as failure:
            self.get('/'+key+'/t4')
        self.assertEqual(failure.exception.code,503)
        self.assertNotIn(b'private details',failure.exception.read())
        key=self.install('original')
        (self.root/key/'index.cjs').write_text('modified')
        with self.assertRaises(urllib.error.HTTPError):self.get('/'+key+'/t4')

    def test_07_two_bundles_release_and_reload(self):
        key=self.install(FIXTURE+'\n// another subscription')
        with self.get('/'+key+'/t4') as response:
            self.assertIn('/'+key+'/api/demo',json.load(response)['sites'][0]['api'])
        request=urllib.request.Request(self.base+'/'+key+'/_release',data=b'',method='POST')
        with urllib.request.urlopen(request,timeout=8) as response:self.assertTrue(json.load(response)['released'])
        with self.get('/'+key+'/t4') as response:self.assertEqual(response.status,200)

    def test_08_network_fetch_without_jit_or_wasm(self):
        with self.get('/'+self.hash+'/api/network') as response:
            self.assertEqual(response.read(),bytes([0,1,255,42]))

    def test_signed_spider_proxy_keeps_playlist_segments_and_blocks_admin(self):
        with self.get('/'+self.hash+'/api/demo?play=fixture') as response:
            play=json.load(response)['url']
        with urllib.request.urlopen(play,timeout=8) as response:
            text=response.read().decode()
        stem=self.base+'/'+self.hash+'/spider/demo/3/proxy/token/'
        self.assertIn(stem+'key?sig=fixture',text)
        self.assertIn(stem+'segment.ts?sig=fixture',text)
        with urllib.request.urlopen(stem+'segment.ts?sig=fixture',timeout=8) as response:
            self.assertEqual(response.read(),bytes([0,1,255,42]))
        for suffix in ['/spider/demo/3/website','/spider/demo/3/proxy/../../website',
                       '/spider/demo/3/proxy/%2e%2e/%2e%2e/website',
                       '/spider/demo/3/proxy/%2f..%2fwebsite']:
            with self.assertRaises(urllib.error.HTTPError) as failure:
                self.get('/'+self.hash+suffix)
            self.assertEqual(failure.exception.code,403)
        with self.assertRaises(urllib.error.HTTPError) as failure:
            urllib.request.urlopen(urllib.request.Request(play,data=b'',method='POST'),timeout=8)
        self.assertEqual(failure.exception.code,403)

    def test_09_settings_requires_ticket_and_rejects_foreign_origin(self):
        request=urllib.request.Request(self.base+'/'+self.hash+'/_manage',data=b'',method='POST')
        with urllib.request.urlopen(request,timeout=8) as response:url=json.load(response)['url']
        origin=url.split('/authorize/')[0]
        with self.assertRaises(urllib.error.HTTPError):urllib.request.urlopen(origin+'/website')
        cookies=http.cookiejar.CookieJar()
        browser=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cookies))
        with browser.open(url) as response:self.assertIn(b'Local settings',response.read())
        with self.assertRaises(urllib.error.HTTPError):urllib.request.urlopen(url)
        foreign=urllib.request.Request(origin+'/website',data=b'',headers={'Origin':'https://example.test'})
        with self.assertRaises(urllib.error.HTTPError) as failure:browser.open(foreign)
        self.assertEqual(failure.exception.code,403)
        with browser.open(origin+'/website') as response:self.assertEqual(response.status,200)


if __name__=='__main__': unittest.main()
