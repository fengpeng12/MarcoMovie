"""Bttwoo protocol/short-array bootstrap checks, using only synthetic fixtures."""
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import base64
import hashlib
import hmac
import json
import struct
import subprocess
import threading
import unittest
import urllib.parse
import test_guard_bootstrap as guard

ROOT, NODE = guard.ROOT, guard.NODE
PLAY_KEY = 'fixture-encoding-key'
USERLINK = 'fixture-user-link'

class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_): pass

    def do_GET(self):
        self.server.paths.append(self.path)
        self.server.headers_seen.append(dict(self.headers))
        parsed = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        origin = self.server.origin
        if parsed.path == '/video/play':
            stamp = query.get('t', [''])[0]
            expected = hmac.new(b'fixture-video', ('42:'+stamp+':fixture-video').encode(), hashlib.sha256).hexdigest()[:32]
            expected_key = base64.urlsafe_b64encode(bytes(v ^ PLAY_KEY.encode()[i % len(PLAY_KEY)] for i, v in enumerate(USERLINK.encode()))).decode()
            valid = query.get('p') == ['42'] and query.get('v') == ['fixture-video'] and query.get('q') == ['1080'] and query.get('s') == [expected] and query.get('k') == [expected_key] and stamp.isdigit()
            self.server.signature_valid.append(valid)
            modes = {'direct': origin+'/media.m3u8?fixture=one', 'scheme':'file:///fixture.mp4',
                     'userinfo':origin.replace('://','://fixture:secret@')+'/media.mp4','empty':''}
            body = json.dumps({'data': {'quality_urls': [{'url': modes[self.server.mode]}]}}) if valid else '{}'
        elif parsed.path.startswith('/play/'):
            body = ('<nav id="navbar" x-data="{userlink:\''+USERLINK+'\', active:false}"></nav><h1>Fixture</h1>'
                    '<p class="text-xs text-text-secondary leading-relaxed">Fixture plot</p>'
                    '<div style="display:block"><a href="/play/fixture-video" @click.prevent="handleEpisodeClick(event, \'42\', false)">'
                    '<span x-show="active">Episode 1</span></a></div>')
        elif query.get('q') == ['challenge']:
            body = '<html><body>Verify you are human</body></html>'
        elif query.get('q') in [['empty'],['failure']] or query.get('classify') == ['9']:
            body = '<html><body></body></html>'
        else:
            title = query.get('q', ['Fixture'])[0]
            name = 'fixture-next' if query.get('page') == ['2'] else 'fixture-video'
            def card(vip=False):
                return ('<div data-vod-id="1" class="group relative">'+('<span>VIP</span>' if vip else '')+
                        '<a href="/play/'+name+'"><img class="object-cover" data-src="/poster.png" alt="'+title+'"></a>'+
                        '<span class="text-right">HD</span><span class="text-text-muted">2026</span></div>')
            body = '<div class="4xl:grid-cols-8">'+card()+card(True)+'</div>'
        data = body.encode()
        self.send_response(503 if query.get('q')==['failure'] else 200); self.send_header('Content-Type','text/html; charset=utf-8')
        self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)

class BttwooChecks(unittest.TestCase):
    setUpClass = classmethod(guard.HostChecks.setUpClass.__func__)
    tearDownClass = classmethod(guard.HostChecks.tearDownClass.__func__)
    request = guard.HostChecks.request

    def test_six_methods_signature_empty_results_and_errors(self):
        fixture = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
        fixture.daemon_threads=True; fixture.origin='http://127.0.0.1:'+str(fixture.server_port)
        fixture.paths=[];fixture.headers_seen=[];fixture.signature_valid=[];fixture.mode='direct'
        threading.Thread(target=fixture.serve_forever,daemon=True).start()
        try:
            config={'origin':fixture.origin+'/','userAgent':'Fixture-UA','playKey':PLAY_KEY}
            js="console.log(JSON.stringify(require(process.argv[1])(JSON.parse(process.argv[2]))))"
            rule=json.loads(subprocess.check_output([NODE,'--jitless','-e',js,str(ROOT/'shared/catpaw/drpy-bttwoo-adapter.cjs'),json.dumps(config)],stderr=subprocess.DEVNULL))
            manifest={'kind':'drpy','version':1,'runtime':'drpy2-ca23ffdb-1','sourceId':'b'*64,
                      'origin':fixture.origin+'/rule.js','rule':rule,'headers':{},'requestTimeoutMs':2000}
            data=json.dumps(manifest).encode();digest=hashlib.sha256(data).hexdigest()
            (self.root/digest).mkdir();(self.root/digest/'drpy.json').write_bytes(data)
            api='/'+self.state['secret']+'/'+digest+'/api/drpy'
            def call(method,args):
                status,value=self.request({'version':1,'method':method,'args':args},path=api)
                self.assertEqual(status,200,value);return value
            self.assertEqual(len(call('home',[True])['class']),3)
            home=call('homeVod',[])['list'];self.assertEqual(len(home),1);self.assertEqual(home[0]['vod_remarks'],'HD')
            category=call('category',['1',1,True,{}])['list'];self.assertEqual(len(category),1);self.assertEqual(category[0]['vod_remarks'],'2026')
            page2=call('category',['1',2,True,{}])['list'];self.assertNotEqual(category[0]['vod_id'],page2[0]['vod_id'])
            self.assertEqual(call('search',['中文搜索',False,1])['list'][0]['vod_name'],'中文搜索')
            self.assertEqual(call('search',['empty',False,1])['list'],[])
            status,error=self.request({'version':1,'method':'search','args':['failure',False,1]},path=api)
            self.assertEqual((status,error),(422,{'error':'drpy_source_unavailable'}))
            empty=call('category',['9',1,True,{}]);self.assertEqual(empty['list'],[]);self.assertEqual(empty['total'],0)
            call('category',['1',1,True,{'class':'全部','area':'','year':''}])
            for field in ['class','type','area','year']:
                status,error=self.request({'version':1,'method':'category','args':['1',1,True,{field:'unsupported'}]},path=api)
                self.assertEqual((status,error),(422,{'error':'drpy_filter_not_supported'}))
            status,error=self.request({'version':1,'method':'search','args':['challenge',False,1]},path=api)
            self.assertEqual((status,error),(422,{'error':'drpy_verification_required'}))
            detail=call('detail',[category[0]['vod_id']])['list'][0]
            self.assertEqual(detail['vod_name'],'Fixture');self.assertEqual(detail['vod_play_from'],'自动')
            episode=detail['vod_play_url'].split('$',1)[1]
            play=call('play',['自动',episode,[]]);self.assertEqual(play['parse'],0);self.assertEqual(play['url'],fixture.origin+'/media.m3u8?fixture=one')
            self.assertEqual(fixture.signature_valid,[True])
            self.assertTrue(all({k.lower():v for k,v in h.items()}.get('user-agent')=='Fixture-UA' for h in fixture.headers_seen))
            for mode in ['scheme','userinfo','empty']:
                fixture.mode=mode
                status,error=self.request({'version':1,'method':'play','args':['自动',episode,[]]},path=api)
                self.assertEqual((status,error),(422,{'error':'drpy_media_protocol'}))
                self.assertNotIn('secret',json.dumps(error))
            status,error=self.request({'version':1,'method':'detail','args':['https://different.invalid/play/fixture']},path=api)
            self.assertEqual((status,error),(422,{'error':'drpy_source_origin'}))
        finally:
            fixture.shutdown();fixture.server_close()

    def test_unknown_bttwoo_artifact_explicit(self):
        data=b'synthetic unknown Bttwoo';digest=hashlib.sha256(data).hexdigest()
        (self.root/'imports'/(digest+'.jar')).write_bytes(data)
        self.assertEqual(self.request({'version':1,'adapter':'bttwoo-v1','artifactHash':digest}),
                         (422,{'error':'guard_artifact_unsupported'}))

def array_dex():
    strings=['Lfixture/Array;','Ljava/lang/Object;','[S','V','<clinit>','short']
    offsets={};position=112
    for name,count,size in [('strings',len(strings),4),('types',4,4),('protos',1,12),
                            ('fields',1,8),('methods',1,8),('classes',1,32)]:
        offsets[name]=position;position+=count*size
    data=bytearray(position)
    for i,text in enumerate(strings):
        struct.pack_into('<I',data,offsets['strings']+i*4,len(data))
        data.extend(guard.uleb(len(text))+text.encode()+b'\0')
    while len(data)%4:data.append(0)
    code=len(data)
    words=[0x13,3,0x23,2,0x26,6,0,0x69,0,0xe,0x300,2,3,0,11,22,33]
    data.extend(struct.pack('<4H2I',1,0,0,0,0,len(words)))
    data.extend(struct.pack('<'+'H'*len(words),*words))
    class_data=len(data);data.extend(bytes([1,0,1,0,0,8,0])+guard.uleb(0x10008)+guard.uleb(code))
    data[:8]=b'dex\n035\0';struct.pack_into('<3I',data,32,len(data),112,0x12345678)
    for header,key,count in [(56,'strings',len(strings)),(64,'types',4),(72,'protos',1),(80,'fields',1),(88,'methods',1),(96,'classes',1)]:
        struct.pack_into('<2I',data,header,count,offsets[key])
    struct.pack_into('<4I',data,offsets['types'],0,1,2,3)
    struct.pack_into('<3I',data,offsets['protos'],3,3,0)
    struct.pack_into('<HHI',data,offsets['fields'],0,2,5)
    struct.pack_into('<HHI',data,offsets['methods'],0,0,4)
    struct.pack_into('<8I',data,offsets['classes'],0,1,1,0,0xffffffff,0,class_data,0)
    return guard.checksum(data),code

class ShortArrayChecks(unittest.TestCase):
    setUp=guard.ReaderChecks.setUp
    tearDown=guard.ReaderChecks.tearDown
    run_reader=guard.ReaderChecks.run_reader

    def expression(self,data,code):
        size=int.from_bytes(data[code+12:code+16],'little')
        digest=hashlib.sha256(data[code:code+16+size*2]).hexdigest()
        return "new x.Dex(b).reviewedShortArray('Lfixture/Array;','"+digest+"','short',10,3)"

    def test_exact_short_array_and_shape_validation(self):
        data,code=array_dex();expression=self.expression(data,code)
        self.assertEqual(self.run_reader(data,expression)['value'],[11,22,33])
        for unit,value in [(4,0x28),(5,7),(7,0x68),(11,1),(12,4)]:
            changed=bytearray(data);struct.pack_into('<H',changed,code+16+unit*2,value);changed=guard.checksum(changed)
            # Even a caller-supplied matching hash cannot override structural checks.
            self.assertIn('error',self.run_reader(changed,self.expression(changed,code)))
        self.assertIn('error',self.run_reader(data,expression.replace("'short'","'other'")))
        self.assertIn('error',self.run_reader(data,expression.replace(",10,3",",10,4097")))
        changed=bytearray(data);changed[code+16+14*2]^=1
        self.assertIn('error',self.run_reader(guard.checksum(changed),expression))

if __name__=='__main__':unittest.main(verbosity=2)
