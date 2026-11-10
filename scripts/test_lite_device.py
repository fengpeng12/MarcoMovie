"""Run isolated synthetic tests only on the API14 emulator. Never selects a TV."""
import subprocess,os,zipfile,json,threading,sys,ssl
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
from build_lite import ROOT,BUILD,API14,JDK,SDK,run,exe
sys.path.insert(0,str(ROOT/'tools/lite-test'))
ADB=os.environ.get('MARCOMOVIE_ADB','adb')
def adb(*args):return subprocess.check_output([ADB,'-s','emulator-5580',*map(str,args)],timeout=120).decode('utf8',errors='replace')
class Fixture(BaseHTTPRequestHandler):
 def do_GET(self):
  path=self.path.split('?')[0]
  if path=='/video.mp4':data=(ROOT/'verification/private/lite/baseline.mp4').read_bytes();mime='video/mp4'
  elif path=='/stream.m3u8' or (path.startswith('/segment') and path.endswith('.ts') and path[8:-3].isdigit()):
   data=(ROOT/'verification/private/lite'/path[1:]).read_bytes();mime='application/vnd.apple.mpegurl' if path.endswith('m3u8') else 'video/mp2t'
  else:
   mime='application/json'
   if path=='/config':obj={'sites':[{'name':'合成测试','api':'http://10.0.2.2:8773/cms','type':1},{'name':'插件兼容提示','api':'csp_example','type':3}]}
   elif path=='/cms':obj={'pagecount':1,'list':[{'vod_id':'demo','vod_name':'合成测试','vod_content':'仅用于兼容验证','vod_play_from':'测试线路','vod_play_url':'第一集$http://10.0.2.2:8773/video.mp4'}]}
   else:obj={}
   data=json.dumps(obj,ensure_ascii=False).encode('utf8')
  size=len(data);start=0;end=size-1;partial=self.headers.get('Range','')
  if partial.startswith('bytes='):
   bounds=partial[6:].split('-',1);start=int(bounds[0]);end=min(int(bounds[1]),end) if bounds[1] else end
   if start>=size:self.send_error(416);return
   data=data[start:end+1]
  self.send_response(206 if partial else 200);self.send_header('Content-Type',mime);self.send_header('Accept-Ranges','bytes')
  if partial:self.send_header('Content-Range',f'bytes {start}-{end}/{size}')
  self.send_header('Content-Length',str(len(data)));self.end_headers()
  try:self.wfile.write(data)
  except (BrokenPipeError,ConnectionResetError):pass
 def log_message(self,*a):pass
def main():
 global BUILD
 candidate='--candidate' in sys.argv
 if candidate:BUILD=ROOT/'android/build/lite-candidate'
 assert adb('shell','-x','getprop','ro.build.version.sdk').strip()=='14'
 fixture=ROOT/'verification/private/lite/baseline.mp4';fixture.parent.mkdir(parents=True,exist_ok=True)
 if not fixture.exists():subprocess.run(['ffmpeg','-v','error','-f','lavfi','-i','testsrc2=size=480x270:rate=24','-f','lavfi','-i','sine=frequency=440:sample_rate=44100','-t','40','-c:v','libx264','-profile:v','baseline','-pix_fmt','yuv420p','-c:a','aac','-ac','2','-movflags','+faststart',str(fixture)],check=True)
 if not fixture.with_name('stream.m3u8').exists():subprocess.run(['ffmpeg','-v','error','-i',str(fixture),'-c:v','libx264','-profile:v','baseline','-g','48','-c:a','copy','-hls_time','2','-hls_list_size','0','-hls_segment_filename',str(fixture.with_name('segment%d.ts')),str(fixture.with_name('stream.m3u8'))],check=True)
 out=BUILD/'probe'
 for d in ('classes','dex'):(out/d).mkdir(parents=True,exist_ok=True)
 manifest=out/'manifest.xml';manifest.write_text('<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.pilipala.marcomovie.lite.test"><uses-sdk android:minSdkVersion="14" android:targetSdkVersion="28"/><application/><instrumentation android:name="com.pilipala.marcomovie.lite.LiteProbe" android:targetPackage="com.pilipala.marcomovie.lite"/></manifest>')
 assets=out/'assets';assets.mkdir(exist_ok=True)
 if candidate:
  from cryptography import x509
  from cryptography.hazmat.primitives import hashes,serialization
  from cryptography.hazmat.primitives.asymmetric import rsa
  from cryptography.x509.oid import NameOID
  import datetime,ipaddress
  key=rsa.generate_private_key(public_exponent=65537,key_size=2048);name=x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,'10.0.2.2')]);now=datetime.datetime.now(datetime.timezone.utc)
  cert=x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key()).serial_number(x509.random_serial_number()).not_valid_before(now-datetime.timedelta(days=1)).not_valid_after(now+datetime.timedelta(days=2)).add_extension(x509.BasicConstraints(ca=True,path_length=None),critical=True).add_extension(x509.SubjectAlternativeName([x509.IPAddress(ipaddress.ip_address('10.0.2.2')),x509.DNSName('10.0.2.2')]),critical=False).sign(key,hashes.SHA256())
  (assets/'test-ca.pem').write_bytes(cert.public_bytes(serialization.Encoding.PEM));(out/'test-key.pem').write_bytes(key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()))
 run(exe(SDK,'aapt2'),'link','-o',out/'res.apk','--manifest',manifest,'-I',API14,'-A',assets)
 run(exe(JDK/'bin','javac'),'-encoding','UTF-8','-source','8','-target','8','-bootclasspath',API14,'-classpath',BUILD/'classes.jar','-d',out/'classes',ROOT/'lite/tests/LiteProbe.java')
 with zipfile.ZipFile(out/'classes.jar','w') as z:
  for p in (out/'classes').rglob('*.class'):z.write(p,p.relative_to(out/'classes').as_posix())
 run(exe(JDK/'bin','java'),'-cp',SDK/'lib/d8.jar','com.android.tools.r8.D8','--min-api','14','--lib',API14,'--classpath',BUILD/'classes.jar','--output',out/'dex',out/'classes.jar')
 with zipfile.ZipFile(out/'res.apk') as src,zipfile.ZipFile(out/'unsigned.apk','w') as dst:
  for n in src.namelist():dst.writestr(n,src.read(n))
  dst.write(out/'dex/classes.dex','classes.dex')
 run(exe(SDK,'zipalign'),'-f','4',out/'unsigned.apk',out/'aligned.apk')
 run(exe(JDK/'bin','java'),'-jar',SDK/'lib/apksigner.jar','sign','--min-sdk-version','14','--ks',ROOT/'android/private/development.p12','--ks-key-alias','marcomovie','--ks-pass','env:MARCOMOVIE_KEY_PASSWORD','--out',out/'probe.apk',out/'aligned.apk')
 print(adb('install','--no-streaming','-r',ROOT/('verification/private/lite-candidate' if candidate else 'dist/lite')/'MarcoMovie-Lite-0.1.1-alpha.apk'))
 print(adb('install','--no-streaming','-r',out/'probe.apk'))
 server=ThreadingHTTPServer(('127.0.0.1',8773),Fixture);threading.Thread(target=server.serve_forever,daemon=True).start()
 secure=None
 if candidate:
  secure=ThreadingHTTPServer(('127.0.0.1',8774),Fixture);ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.minimum_version=ctx.maximum_version=ssl.TLSVersion.TLSv1_2;ctx.load_cert_chain(assets/'test-ca.pem',out/'test-key.pem');secure.socket=ctx.wrap_socket(secure.socket,server_side=True);threading.Thread(target=secure.serve_forever,daemon=True).start()
 try:
  result=adb('shell','-x','am','instrument','-w','-e','candidate',str(candidate).lower(),'com.pilipala.marcomovie.lite.test/com.pilipala.marcomovie.lite.LiteProbe');(out/'result.txt').write_text(result,encoding='utf8');print(result);assert ('PASS 33 API14 checks' if candidate else 'PASS 28 API14 checks') in result
 finally:
  server.shutdown();server.server_close()
  if secure:secure.shutdown();secure.server_close()
  adb('uninstall','com.pilipala.marcomovie.lite.test')
if __name__=='__main__':main()
