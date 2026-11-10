from pathlib import Path
import os, subprocess
root=Path(__file__).resolve().parents[2]
jdk=Path(os.environ.get('MARCOMOVIE_JDK',os.environ.get('JAVA_HOME','missing-jdk')))
suffix='.exe' if os.name=='nt' else ''
out=root/'android/build/update-checks';out.mkdir(parents=True,exist_ok=True)
sources=[root/'android/src/main/java/com/pilipala/marcomovie'/name for name in ['UpdatePolicy.java','TvLayoutPolicy.java']]
subprocess.run([str(jdk/('bin/javac'+suffix)),'-encoding','UTF-8','-d',str(out),*map(str,sources),str(root/'android/tests/UpdateLayoutChecks.java')],check=True)
subprocess.run([str(jdk/('bin/java'+suffix)),'-cp',str(out),'com.pilipala.marcomovie.UpdateLayoutChecks'],check=True)
jar=root/'android/tests/lib/json-20240303.jar'
subprocess.run([str(jdk/('bin/javac'+suffix)),'-encoding','UTF-8','-source','8','-target','8','-Xlint:-options','-cp',str(out)+os.pathsep+str(jar),'-d',str(out),str(root/'android/src/main/java/com/pilipala/marcomovie/UpdateRelease.java'),str(root/'android/tests/UpdateEditionChecks.java')],check=True)
subprocess.run([str(jdk/('bin/java'+suffix)),'-cp',str(out)+os.pathsep+str(jar),'com.pilipala.marcomovie.UpdateEditionChecks'],check=True)
