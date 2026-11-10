from pathlib import Path
import os, subprocess
ROOT=Path(__file__).resolve().parents[2]
JDK=Path(os.environ.get('MARCOMOVIE_JDK',os.environ.get('JAVA_HOME','missing-jdk')))
out=ROOT/'android/build/tv-input-checks';out.mkdir(parents=True,exist_ok=True)
jar=ROOT/'android/tests/lib/json-20240303.jar'
sources=[ROOT/'android/src/main/java/com/pilipala/marcomovie'/name for name in ('ConfigTransferServer.java','LiveSession.java','LiveCatalog.java','ProxyAddress.java','Cms.java','RequestScope.java')]
suffix='.exe' if os.name=='nt' else ''
subprocess.run([str(JDK/'bin'/('javac'+suffix)),'-encoding','UTF-8','-cp',str(jar),'-d',str(out),str(ROOT/'shared/java/com/pilipala/source/Warehouse.java'),*map(str,sources),str(ROOT/'android/tests/TvInputChecks.java')],check=True)
subprocess.run([str(JDK/'bin'/('java'+suffix)),'-Dsun.net.http.allowRestrictedHeaders=true','-cp',str(out)+os.pathsep+str(jar),'com.pilipala.marcomovie.TvInputChecks'],check=True)
