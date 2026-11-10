"""Original Appgz synthetic encrypted-protocol checks; no private endpoints/artifacts."""
from pathlib import Path
import hashlib
import json
import subprocess
import urllib.request
import unittest
import test_guard_bootstrap as guard

ROOT, NODE = guard.ROOT, guard.NODE

class AppgzChecks(unittest.TestCase):
    setUpClass = classmethod(guard.HostChecks.setUpClass.__func__)
    tearDownClass = classmethod(guard.HostChecks.tearDownClass.__func__)
    request = guard.HostChecks.request

    def test_protocol_lifecycle_and_failures(self):
        fixture=subprocess.Popen([NODE,'--jitless',str(ROOT/'scripts/fixtures/appgz_server.cjs')],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,encoding='utf-8')
        try:
            config=json.loads(fixture.stdout.readline())
            def control(mode='normal'):
                with urllib.request.urlopen(config['origin']+'/control?mode='+mode,timeout=3) as result:return json.load(result)
            rule=json.loads(subprocess.check_output([NODE,'--jitless','-e','console.log(JSON.stringify(require(process.argv[1])(JSON.parse(process.argv[2]))))',str(ROOT/'shared/catpaw/drpy-appgz-adapter.cjs'),json.dumps(config)],stderr=subprocess.DEVNULL))
            manifest={'kind':'drpy','version':1,'runtime':'drpy2-ca23ffdb-1','sourceId':'e'*64,'origin':config['origin']+'/rule.js','rule':rule,'headers':{},'requestTimeoutMs':2000}
            data=json.dumps(manifest).encode();digest=hashlib.sha256(data).hexdigest()
            (self.root/digest).mkdir();(self.root/digest/'drpy.json').write_bytes(data)
            api='/'+self.state['secret']+'/'+digest+'/api/drpy'
            def call(method,args):
                status,result=self.request({'version':1,'method':method,'args':args},path=api)
                self.assertEqual(status,200,result);return result
            def fails(method,args,code):
                self.assertEqual(self.request({'version':1,'method':method,'args':args},path=api),(422,{'error':code}))
            home=call('home',[True]);self.assertEqual(len(home['class']),4)
            self.assertEqual(home['filters']['1'][0]['key'],'area');self.assertEqual(control()['records'],[])
            self.assertEqual(call('homeVod',[])['list'][0]['vod_name'],'中文 Fixture')
            control('upstream')
            fails('category',['1',1,True,{}],'drpy_source_unavailable')
            # The failed first registration is not repeated; next call uses the
            # same device identity and signs in, then issues the catalog request.
            control()
            self.assertEqual(call('category',['1',2,True,{'area':'中国大陆','year':'2026'}])['list'][0]['vod_id'],'42')
            self.assertEqual(call('search',['中文',False,1])['list'][0]['vod_name'],'中文 Fixture')
            self.assertEqual(len(call('search',['中文',False,1])['list']),1)
            self.assertEqual(call('search',['中文',False,2])['list'],[])
            detail=call('detail',['42'])['list'][0]
            self.assertEqual(detail['vod_year'],'2026');self.assertEqual(detail['vod_play_from'],'专线播放')
            episode=detail['vod_play_url'].split('$',1)[1]
            play=call('play',['专线播放',episode,[]]);self.assertEqual(play['url'],config['origin']+'/media.m3u8')
            self.assertEqual(play['header'],{'User-Agent':'Lavf/57.83.100'})
            with urllib.request.urlopen(play['url'],timeout=3) as media:self.assertTrue(media.read(32).startswith(b'#EXTM3U'))
            records=control()['records']
            auth=[r for r in records if '/Device/' in r['path']]
            self.assertEqual(len(auth),2);self.assertTrue(auth[0]['path'].endswith('signUp'));self.assertTrue(auth[1]['path'].endswith('signIn'))
            self.assertEqual(auth[0]['payload']['new_key'],auth[1]['payload']['new_key']);self.assertEqual(auth[0]['payload']['old_key'],auth[1]['payload']['old_key'])
            catalog=next(r for r in records if r['path'].endswith('/indexList'))
            self.assertEqual(catalog['payload'],{'area':'中国大陆','sub':'5','year':'2026','pageSize':'30','sort':'d_id','page':'2','tid':'1'})
            for key in ['type','class','unknown']:
                fails('category',['1',1,True,{key:'动作'}],'drpy_filter_not_supported')
            fails('category',['1',1,True,{'year':'1800'}],'drpy_filter_not_supported')
            for mode,code in [('upstream','drpy_source_unavailable'),('rsa','drpy_source_response'),('aes','drpy_source_response'),('redirect','drpy_source_unavailable')]:
                control(mode);fails('search',['中文',False,1],code)
            for mode in ['scheme','userinfo']:
                control(mode);fails('play',['专线播放',episode,[]],'drpy_media_protocol')
            control('antileech');fails('play',['专线播放',episode,[]],'drpy_authentication_required')
            control('empty');self.assertEqual(call('category',['1',1,True,{}])['list'],[]);self.assertEqual(call('search',['中文',False,1])['list'],[])
            control()
            self.assertEqual(self.request({},path='/'+self.state['secret']+'/'+digest+'/_release'),(200,{'released':True}))
            call('category',['1',1,True,{}])
            self.assertEqual(len([r for r in control()['records'] if '/Device/' in r['path']]),2)
        finally:
            fixture.terminate();fixture.wait(timeout=5);fixture.stdout.close()

    def test_unknown_artifact_and_no_endpoint_fallback(self):
        data=b'synthetic unknown Appgz';digest=hashlib.sha256(data).hexdigest()
        (self.root/'imports'/(digest+'.jar')).write_bytes(data)
        self.assertEqual(self.request({'version':1,'adapter':'appgz-v1','artifactHash':digest}),(422,{'error':'guard_artifact_unsupported'}))

class RsaChecks(unittest.TestCase):
    def test_bounded_crypto_and_padding(self):
        script=r"""
const assert=require('node:assert/strict'),crypto=require('node:crypto'),rsa=require(process.argv[1]);
const pair=crypto.generateKeyPairSync('rsa',{modulusLength:1024});
const pub=pair.publicKey.export({type:'spki',format:'der'}).toString('base64');
const priv=pair.privateKey.export({type:'pkcs8',format:'der'}).toString('base64');
const message=Buffer.from('Chinese 中文 AES key/iv fixture');
const result=rsa('encrypt',pub,message.toString('base64'));
assert.equal(Buffer.from(rsa('decrypt',priv,result),'base64').toString(),message.toString());
const legacy=crypto.generateKeyPairSync('rsa',{modulusLength:1023});
const legacyPub=legacy.publicKey.export({type:'spki',format:'der'}).toString('base64'),legacyPriv=legacy.privateKey.export({type:'pkcs8',format:'der'}).toString('base64');
assert.equal(Buffer.from(rsa('decrypt',legacyPriv,rsa('encrypt',legacyPub,message.toString('base64'))),'base64').toString(),message.toString());
for(const args of [['unknown',pub,'YQ=='],['encrypt',priv,'YQ=='],['decrypt',pub,result],['encrypt',pub,Buffer.alloc(118).toString('base64')],['decrypt',priv,'AA=='],['decrypt',priv,result+'\n'],['decrypt',priv,'A'.repeat(3000)]])assert.throws(()=>rsa(...args),/^Error: drpy_crypto_invalid$/);
for(const end of [2,9,127]){const block=Buffer.alloc(128,1);block[0]=0;block[1]=2;block[end]=0;const ciphertext=crypto.publicEncrypt({key:pair.publicKey,padding:crypto.constants.RSA_NO_PADDING},block).toString('base64');assert.throws(()=>rsa('decrypt',priv,ciphertext),/^Error: drpy_crypto_invalid$/);}
const huge=crypto.generateKeyPairSync('rsa',{modulusLength:2048}).publicKey.export({type:'spki',format:'der'}).toString('base64');assert.throws(()=>rsa('encrypt',huge,'YQ=='),/^Error: drpy_crypto_invalid$/);
console.log('bounded RSA and malformed blocks passed');
"""
        subprocess.run([NODE,'--jitless','-e',script,str(ROOT/'shared/catpaw/drpy-rsa.cjs')],check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)

if __name__=='__main__':unittest.main()
