from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from pathlib import Path
import subprocess,os,threading,time
ROOT=Path(__file__).resolve().parents[2]
JDK=Path(os.environ.get('MARCOMOVIE_JDK',os.environ.get('JAVA_HOME', 'missing-jdk')))
class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def do_GET(self):
        if self.path=='/cross':self.send_response(302);self.send_header('Location',f'http://localhost:{self.server.server_port}/headers');self.end_headers()
        elif self.path=='/headers' and (self.headers.get('Authorization') or self.headers.get('Cookie')):self.send_response(403);self.end_headers()
        elif self.path=='/slow':time.sleep(6);self.send_response(503);self.end_headers()
        elif self.path=='/redirect':self.send_response(302);self.send_header('Location','lists/index.m3u');self.end_headers()
        elif self.path=='/failure':self.send_response(503);self.end_headers()
        elif self.path=='/loop':self.send_response(302);self.send_header('Location','loop');self.end_headers()
        elif self.path.split('?',1)[0]=='/list.php':self.send_response(200);self.send_header('Content-Type','text/plain');self.end_headers();self.wfile.write(('\ufeff#EXTM3U\n#EXTINF:-1,中文频道\nmedia/video.m3u8\n').encode('utf-16le'))
        else:self.send_response(200);self.send_header('Content-Type','audio/x-mpegurl; charset=utf-8');self.end_headers();self.wfile.write(b'#EXTM3U\n#EXTINF:-1,Local test\n../media/test.m3u8\n')
server=ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start()
out=ROOT/'android/tests/live-classes';out.mkdir(exist_ok=True)
jar=ROOT/'android/tests/lib/json-20240303.jar'
try:
    subprocess.run([str(JDK/'bin'/('javac.exe' if os.name=='nt' else 'javac')),'-encoding','UTF-8','-source','8','-target','8','-Xlint:-options','-cp',str(jar),'-d',str(out),str(ROOT/'shared/java/com/pilipala/source/Warehouse.java'),str(ROOT/'android/src/main/java/com/pilipala/marcomovie/Cms.java'),str(ROOT/'android/src/main/java/com/pilipala/marcomovie/RequestScope.java'),str(ROOT/'android/src/main/java/com/pilipala/marcomovie/LiveCatalog.java'),str(ROOT/'android/src/main/java/com/pilipala/marcomovie/ProxyAddress.java'),str(ROOT/'android/tests/LiveCatalogChecks.java')],check=True)
    result=subprocess.run([str(JDK/'bin'/('java.exe' if os.name=='nt' else 'java')),'-cp',str(out)+os.pathsep+str(jar),'LiveCatalogChecks',str(ROOT),f'http://127.0.0.1:{server.server_port}/'],check=True,text=True,encoding='utf-8',capture_output=True)
    print(result.stdout);(ROOT/'android/tests/live-results.txt').write_text(result.stdout,encoding='utf-8')
    subprocess.run([str(JDK/'bin'/('javac.exe' if os.name=='nt' else 'javac')),'-encoding','UTF-8','-cp',str(out)+os.pathsep+str(jar),'-d',str(out),str(ROOT/'android/tests/LiveNetworkChecks.java'),str(ROOT/'android/tests/PrivacyPinChecks.java'),str(ROOT/'android/src/main/java/com/pilipala/marcomovie/PrivacyPin.java')],check=True)
    for name,extra in [('LiveNetworkChecks',[f'http://127.0.0.1:{server.server_port}/']),('PrivacyPinChecks',[])]:
        subprocess.run([str(JDK/'bin'/('java.exe' if os.name=='nt' else 'java')),'-cp',str(out)+os.pathsep+str(jar),'com.pilipala.marcomovie.'+name,*extra],check=True)
finally:server.shutdown()
