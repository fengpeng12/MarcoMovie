from pathlib import Path
import os,shutil,subprocess
ROOT=Path(__file__).resolve().parents[2]
JDK=os.environ.get('MARCOMOVIE_JDK') or os.environ.get('JAVA_HOME')
def tool(name):
    if JDK:return str(Path(JDK)/'bin'/(name+'.exe' if os.name=='nt' else name))
    return shutil.which(name) or name
out=ROOT/'android/build/seek-check';out.mkdir(parents=True,exist_ok=True)
subprocess.run([tool('javac'),'-encoding','UTF-8','-source','8','-target','8','-Xlint:-options','-d',str(out),str(ROOT/'android/src/main/java/com/pilipala/marcomovie/SeekGesture.java'),str(ROOT/'android/tests/SeekGestureChecks.java')],check=True)
subprocess.run([tool('java'),'-cp',str(out),'com.pilipala.marcomovie.SeekGestureChecks'],check=True)
