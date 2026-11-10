from pathlib import Path
import os, subprocess, tempfile

root = Path(__file__).resolve().parents[2]
jdk = Path(os.environ.get('MARCOMOVIE_JDK') or os.environ['JAVA_HOME']) / 'bin'
jar = root / 'android/tests/lib/json-20240303.jar'
names = ('Cms.java', 'RequestScope.java', 'VideoFilters.java', 'SourceEngine.java',
         'JsonCmsEngine.java', 'QueuedSourceEngine.java', 'SourceGate.java')
with tempfile.TemporaryDirectory() as output:
    files = [root / 'shared/java/com/pilipala/source/Warehouse.java',
             *[root / 'android/src/main/java/com/pilipala/marcomovie' / n for n in names],
             root / 'android/tests/VideoFilterChecks.java']
    subprocess.run([jdk / 'javac', '-encoding', 'UTF-8', '-cp', jar, '-d', output, *files], check=True)
    subprocess.run([jdk / 'java', '-cp', output + os.pathsep + str(jar),
                    'com.pilipala.marcomovie.VideoFilterChecks'], check=True)
