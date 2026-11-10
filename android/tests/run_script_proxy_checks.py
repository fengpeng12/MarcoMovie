"""Real Android loopback router + shared Node helper. Does not claim Android JNI execution."""
from pathlib import Path
import os
import subprocess
import tempfile
from script_dependencies import prepare

root = Path(__file__).resolve().parents[2]
jdk = Path(os.environ.get('MARCOMOVIE_JDK') or os.environ['JAVA_HOME']) / 'bin'
node = os.environ.get('NODE', 'node')
src = root / 'android/src/main/java/com/pilipala/marcomovie'
dependencies = prepare()
classpath = os.pathsep.join(map(str, dependencies))
with tempfile.TemporaryDirectory(prefix='script-proxy-check-') as temporary:
    work = Path(temporary)
    classes = work / 'classes'
    classes.mkdir()
    shims = {
        'android/util/Base64.java': 'package android.util; public final class Base64 { public static final int DEFAULT=0,NO_WRAP=2; public static byte[] decode(String v,int f){return java.util.Base64.getMimeDecoder().decode(v);} public static String encodeToString(byte[] v,int f){return java.util.Base64.getEncoder().encodeToString(v);} }',
        'android/text/TextUtils.java': 'package android.text; public final class TextUtils { public static String join(CharSequence d,Iterable<?> values){StringBuilder s=new StringBuilder();for(Object v:values){if(s.length()>0)s.append(d);s.append(v);}return s.toString();} }',
        'com/pilipala/marcomovie/CspEngine.java': 'package com.pilipala.marcomovie; final class CspEngine {static Object[] proxy(android.app.Application app,Cms.Config config,java.util.Map<String,String> p){throw new AssertionError("script request reached JAR fallback");}}',
        'com/pilipala/marcomovie/AppLog.java': 'package com.pilipala.marcomovie; final class AppLog {static void w(String tag,String message,Throwable error){}}',
    }
    shim_files = []
    for relative, text in shims.items():
        file = work / relative
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text, encoding='utf-8')
        shim_files.append(file)
    sources = [src / name for name in ('Cms.java','RequestScope.java','SourceEngine.java','JsEngine.java','QuickJsDeadline.java',
                                      'LocalSourcePackage.java','LiveCatalog.java','ProxyAddress.java','LocalProxy.java')]
    subprocess.run([jdk / 'javac','-encoding','UTF-8','-source','8','-target','8','-Xlint:-options','-cp',classpath,'-d',classes,
                    *shim_files,root / 'shared/java/com/pilipala/source/Warehouse.java',*sources,
                    root / 'android/tests/ScriptProxyChecks.java'],check=True)
    subprocess.run([jdk / 'java','-Dfile.encoding=UTF-8','-cp',str(classes)+os.pathsep+classpath,
                    'com.pilipala.marcomovie.ScriptProxyChecks',node,root / 'android/tests/script_proxy_fixture.cjs'],check=True,timeout=90)
