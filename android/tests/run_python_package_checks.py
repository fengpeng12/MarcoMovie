"""Validate the real Android package importer plus the shipped shared Python host.

This is a desktop JVM/Node integration test, not a JNI or Android-device test.
"""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
jdk = Path(os.environ.get('MARCOMOVIE_JDK') or os.environ['JAVA_HOME']) / 'bin'
node = os.environ.get('NODE', 'node')
src = root / 'android/src/main/java/com/pilipala/marcomovie'
parser = root / 'android/tests/lib/json-20240303.jar'
fixtures = root / 'scripts/fixtures'
with tempfile.TemporaryDirectory(prefix='python-package-native-') as temporary:
    work = Path(temporary)
    classes, imports = work / 'classes', work / 'imports'
    classes.mkdir()
    imports.mkdir()
    shim = work / 'android/util/Base64.java'
    shim.parent.mkdir(parents=True)
    shim.write_text('package android.util; public final class Base64 { public static final int DEFAULT=0; public static byte[] decode(String value,int flags){return java.util.Base64.getMimeDecoder().decode(value);} }', encoding='utf-8')
    subprocess.run([jdk / 'javac', '-encoding', 'UTF-8', '-source', '8', '-target', '8', '-Xlint:-options', '-cp', parser, '-d', classes,
                    root / 'shared/java/com/pilipala/source/Warehouse.java', src / 'Cms.java', src / 'LocalSourcePackage.java', src / 'RequestScope.java', src / 'LiveCatalog.java', src / 'ProxyAddress.java',
                    root / 'android/tests/PythonPackageChecks.java', shim], check=True)
    extracted = work / 'extracted.json'
    subprocess.run([jdk / 'java', '-Dfile.encoding=UTF-8', '-cp', str(classes) + os.pathsep + str(parser),
                    'com.pilipala.marcomovie.PythonPackageChecks', imports, fixtures / 'python_package_fixture.json', extracted], check=True)
    subprocess.run([node, '--jitless', root / 'android/tests/python_package_bridge.cjs', extracted, fixtures / 'python_package_expected.json'], check=True)
