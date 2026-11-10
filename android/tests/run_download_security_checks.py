from pathlib import Path
import os,subprocess,json,tempfile
root=Path(__file__).resolve().parents[2]
build=root/'android/build/download-security-check'
stubs={
'android/content/Context.java':'''package android.content; public abstract class Context {public abstract Context getApplicationContext();public abstract java.io.File getFilesDir();public abstract java.io.File getExternalFilesDir(String type);}''',
'android/os/Environment.java':'''package android.os; public final class Environment {public static final String DIRECTORY_MOVIES="Movies";}''',
'android/os/SystemClock.java':'''package android.os; public final class SystemClock {public static long elapsedRealtime(){return System.nanoTime()/1000000;}}''',
'com/pilipala/marcomovie/MainActivity.java':'''package com.pilipala.marcomovie; final class MainActivity {static MainActivity activeActivity;Cms.Config config;SourceEngine engine(Cms.Site site){throw new UnsupportedOperationException("unused plugin resolver");}}''',
'com/pilipala/marcomovie/SourceController.java':'''package com.pilipala.marcomovie; final class SourceController {static String message(Exception e){return e.toString();}}''',
'com/pilipala/marcomovie/LocalProxy.java':'''package com.pilipala.marcomovie; final class LocalProxy {static String rewrite(String value){return ProxyAddress.rewrite(value,ProxyAddress.port,ProxyAddress.token);}}'''
}
for name,content in stubs.items():
 p=build/'stubs'/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(content,encoding='utf8')
jdk=Path(os.environ.get('MARCOMOVIE_JDK', os.environ.get('JAVA_HOME', 'missing-jdk')))
jar=root/'android/tests/lib/json-20240303.jar'
sources=[root/'android/src/main/java/com/pilipala/marcomovie'/name for name in ['DownloadManager.java','Cms.java','RequestScope.java','SourceEngine.java','MediaOptions.java','ProxyAddress.java','AppLog.java']]
sources += [root/'shared/java/com/pilipala/source/MediaRequestHeaders.java', root/'shared/java/com/pilipala/source/Warehouse.java',root/'android/tests/NativeDownloadProbe.java',*(build/'stubs').rglob('*.java')]
classes=build/'classes';classes.mkdir(parents=True,exist_ok=True)
suffix = '.exe' if os.name == 'nt' else ''
subprocess.run([str(jdk/'bin'/('javac'+suffix)),'-encoding','UTF-8','-cp',str(jar),'-d',str(classes),*map(str,sources)],check=True)
with tempfile.TemporaryDirectory(prefix='fixture-',dir=build) as data, (build/'result.log').open('w',encoding='utf8') as log:
 p=subprocess.run([str(jdk/'bin'/('java'+suffix)),'-cp',str(classes)+os.pathsep+str(jar),'com.pilipala.marcomovie.NativeDownloadProbe',data],stdout=log,stderr=subprocess.STDOUT)
print(json.dumps({'probe_exit_code':p.returncode,'production_java_files':8,'android_environment_stubs':6}))

if p.returncode:
 print((build/'result.log').read_text(encoding='utf8'))
 raise SystemExit(p.returncode)
