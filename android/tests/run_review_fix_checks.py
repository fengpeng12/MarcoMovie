from pathlib import Path
import os,shutil,subprocess
ROOT=Path(__file__).resolve().parents[2]
JDK=os.environ.get('MARCOMOVIE_JDK') or os.environ.get('JAVA_HOME')
def java_tool(name):
    if JDK:return str(Path(JDK)/'bin'/(name+'.exe' if os.name=='nt' else name))
    found=shutil.which(name)
    if not found:raise RuntimeError('Set JAVA_HOME or MARCOMOVIE_JDK to JDK 17')
    return found
folder=ROOT/'android/build/review-fix-check';folder.mkdir(parents=True,exist_ok=True)
sources=[ROOT/'android/src/main/java/com/pilipala/marcomovie'/n for n in ('SingleFlight.java','EpisodeSelection.java','ImageDecodePolicy.java','TvLayoutPolicy.java','Prefs.java','AppLog.java','ListingRoute.java')]
subprocess.run([java_tool('javac'),'-encoding','UTF-8','-source','8','-target','8','-Xlint:-options','-d',str(folder),*map(str,sources),str(ROOT/'android/tests/ReviewFixChecks.java')],check=True)
result=subprocess.run([java_tool('java'),'-cp',str(folder),'com.pilipala.marcomovie.ReviewFixChecks'],check=True,text=True,encoding='utf8',capture_output=True)
print(result.stdout)
