from pathlib import Path
import os,subprocess
ROOT=Path(__file__).resolve().parents[2]
JDK=Path(os.environ.get('MARCOMOVIE_JDK',os.environ.get('JAVA_HOME', 'missing-jdk')))
folder=ROOT/'android/build/compat-check';folder.mkdir(exist_ok=True,parents=True)
jar=ROOT/'android/tests/lib/json-20240303.jar'
sources=[ROOT/'android/src/main/java/com/pilipala/marcomovie'/name for name in ['Cms.java','RequestScope.java','ProxyAddress.java','MediaOptions.java','DanmakuData.java','PhoneticSearchIndex.java','WatchHistory.java','HomeKeyTracker.java']]
subprocess.run([str(JDK/'bin'/('javac.exe' if os.name=='nt' else 'javac')),'-encoding','UTF-8','-cp',str(jar),'-d',str(folder),str(ROOT/'shared/java/com/pilipala/source/Warehouse.java'),*map(str,sources),str(ROOT/'android/tests/CompatChecks.java')],check=True)
result=subprocess.run([str(JDK/'bin'/('java.exe' if os.name=='nt' else 'java')),'-Dfile.encoding=UTF-8','-cp',str(folder)+os.pathsep+str(jar),'com.pilipala.marcomovie.CompatChecks',str(ROOT)],check=True,capture_output=True,text=True,encoding='utf8')
print(result.stdout);(ROOT/'android/tests/compat-results.txt').write_text(result.stdout,encoding='utf8')
