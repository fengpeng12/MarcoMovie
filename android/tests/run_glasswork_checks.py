from pathlib import Path
import os, subprocess, tempfile

root = Path(__file__).resolve().parents[2]
jdk = Path(os.environ.get('MARCOMOVIE_JDK') or os.environ['JAVA_HOME']) / 'bin'
with tempfile.TemporaryDirectory() as output:
    subprocess.run([jdk / 'javac', '-encoding', 'UTF-8', '-d', output,
                    root / 'shared/java/com/pilipala/glass/GlassworkMaterial.java',
                    root / 'android/tests/GlassworkChecks.java'], check=True)
    subprocess.run([jdk / 'java', '-cp', output, 'com.pilipala.glass.GlassworkChecks'], check=True)
