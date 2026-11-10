"""Offline keyboard and bounded-search behavior checks; no TV or real content request."""
from pathlib import Path
import os, subprocess
ROOT=Path(__file__).resolve().parents[2]
JDK=Path(os.environ.get('MARCOMOVIE_JDK',os.environ.get('JAVA_HOME', 'missing-jdk')))
out=ROOT/'android/tests/global-search-classes';out.mkdir(exist_ok=True)
jar=ROOT/'android/tests/lib/json-20240303.jar'
sources=[ROOT/'android/src/main/java/com/pilipala/marcomovie'/name for name in ('Cms.java','RequestScope.java','SourceEngine.java','HttpT4Engine.java','PinyinKeyboardModel.java','SearchCoordinator.java','SearchVariants.java')]
subprocess.run([str(JDK/'bin'/('javac.exe' if os.name=='nt' else 'javac')),'-encoding','UTF-8','-source','8','-target','8','-Xlint:-options','-cp',str(jar),'-d',str(out),str(ROOT/'shared/java/com/pilipala/source/Warehouse.java'),*map(str,sources),str(ROOT/'android/tests/GlobalSearchChecks.java'),str(ROOT/'android/tests/SearchVariantsChecks.java')],check=True)
result=subprocess.run([str(JDK/'bin'/('java.exe' if os.name=='nt' else 'java')),'-cp',str(out)+os.pathsep+str(jar),'com.pilipala.marcomovie.GlobalSearchChecks',str(ROOT)],check=True,text=True,encoding='utf8',capture_output=True)
print(result.stdout);(ROOT/'android/tests/global-search-results.txt').write_text(result.stdout,encoding='utf8')

subprocess.run([str(JDK/'bin'/('java.exe' if os.name=='nt' else 'java')),'-cp',str(out)+os.pathsep+str(jar),'com.pilipala.marcomovie.SearchVariantsChecks'],check=True)
