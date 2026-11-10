from pathlib import Path
import os, subprocess, tempfile
from script_dependencies import prepare
ROOT=Path(__file__).resolve().parents[2]
JDK=Path(os.environ.get('MARCOMOVIE_JDK',os.environ.get('JAVA_HOME', 'missing-jdk')))
test=ROOT/'android/tests';out=test/'js-player-classes';out.mkdir(exist_ok=True)
deps=prepare()
classpath=os.pathsep.join(map(str,deps))
sources=[ROOT/'android/src/main/java/com/pilipala/marcomovie'/f for f in ('Cms.java','RequestScope.java','SourceEngine.java','JsEngine.java','QuickJsDeadline.java','LocalSourcePackage.java','LiveCatalog.java','ProxyAddress.java')]
with tempfile.TemporaryDirectory(prefix='js-http-shims-') as tmp:
    shim=Path(tmp)
    base64=shim/'android/util/Base64.java';base64.parent.mkdir(parents=True)
    base64.write_text('package android.util; public final class Base64 { public static final int DEFAULT=0,NO_WRAP=2; public static byte[] decode(String v,int f){return java.util.Base64.getMimeDecoder().decode(v);} public static String encodeToString(byte[] v,int f){return java.util.Base64.getEncoder().encodeToString(v);} }',encoding='utf-8')
    text=shim/'android/text/TextUtils.java';text.parent.mkdir(parents=True)
    text.write_text('package android.text; public final class TextUtils { public static String join(CharSequence d,Iterable<?> values){StringBuilder s=new StringBuilder();for(Object v:values){if(s.length()>0)s.append(d);s.append(v);}return s.toString();} }',encoding='utf-8')
    subprocess.run([str(JDK/'bin'/('javac.exe' if os.name=='nt' else 'javac')),'-encoding','UTF-8','-source','8','-target','8','-Xlint:-options','-cp',classpath,'-d',str(out),str(base64),str(text),str(ROOT/'shared/java/com/pilipala/source/Warehouse.java'),*map(str,sources),str(test/'JsPlayerChecks.java'),str(test/'JsHttpChecks.java')],check=True)
results=[]
for check in ('JsPlayerChecks','JsHttpChecks'):
    result=subprocess.run([str(JDK/'bin'/('java.exe' if os.name=='nt' else 'java')),'-Dfile.encoding=UTF-8','-cp',str(out)+os.pathsep+classpath,'com.pilipala.marcomovie.'+check,str(ROOT)],capture_output=True,text=True,encoding='utf-8')
    print(result.stdout);results.append(result.stdout)
    if result.returncode:
        print(result.stderr)
        result.check_returncode()
(test/'js-player-results.txt').write_text('\n'.join(results),encoding='utf-8')
