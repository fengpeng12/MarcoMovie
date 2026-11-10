from pathlib import Path
import os,subprocess
ROOT=Path(__file__).resolve().parents[2]
JDK=Path(os.environ.get('MARCOMOVIE_JDK',os.environ.get('JAVA_HOME', 'missing-jdk')))
folder=ROOT/'android/build/scheduling-check';folder.mkdir(parents=True,exist_ok=True)
sources=[ROOT/'android/src/main/java/com/pilipala/marcomovie'/n for n in ('DetailCache.java','SourceGate.java','RequestScope.java','MotionSpring.java')]
subprocess.run([str(JDK/'bin'/('javac.exe' if os.name=='nt' else 'javac')),'-encoding','UTF-8','-d',str(folder),*map(str,sources),str(ROOT/'android/tests/SchedulingChecks.java')],check=True)
r=subprocess.run([str(JDK/'bin'/('java.exe' if os.name=='nt' else 'java')),'-cp',str(folder),'com.pilipala.marcomovie.SchedulingChecks'],check=True,text=True,capture_output=True)
print(r.stdout)
