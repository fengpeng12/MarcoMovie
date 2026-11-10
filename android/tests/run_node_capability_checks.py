"""Check production Node capability policy without loading native binaries."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
JDK = Path(os.environ.get('MARCOMOVIE_JDK', os.environ.get('JAVA_HOME', 'missing-jdk')))
PARSER = ROOT / 'android/tests/lib/json-20240303.jar'

with tempfile.TemporaryDirectory(prefix='node-capability-') as folder:
    work = Path(folder)
    shims = {
        'android/content/Context.java': '''package android.content;
public class Context { private final java.io.File root;
public Context(java.io.File r){root=r;} public android.content.res.AssetManager getAssets(){return new android.content.res.AssetManager(root);}
public android.content.pm.ApplicationInfo getApplicationInfo(){android.content.pm.ApplicationInfo a=new android.content.pm.ApplicationInfo();a.nativeLibraryDir=new java.io.File(root,"lib").getPath();a.sourceDir=new java.io.File(root,"app.apk").getPath();return a;} }''',
        'android/content/pm/ApplicationInfo.java': '''package android.content.pm; public class ApplicationInfo { public String nativeLibraryDir,sourceDir; }''',
        'android/content/res/AssetManager.java': '''package android.content.res;
public class AssetManager { private final java.io.File root; public AssetManager(java.io.File r){root=r;}
public java.io.InputStream open(String name)throws java.io.IOException{return new java.io.FileInputStream(new java.io.File(root,name));} }''',
        'android/os/Build.java': '''package android.os; public class Build { public static String[] SUPPORTED_ABIS={"x86_64","x86"}; }''',
        'android/system/OsConstants.java': '''package android.system; public class OsConstants { public static int _SC_PAGESIZE=1; }''',
        'android/system/Os.java': '''package android.system; public class Os { public static long sysconf(int name){return 16384;} }''',
    }
    sources = []
    for name, code in shims.items():
        file = work / name
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(code, encoding='utf-8')
        sources.append(file)
    out = work / 'classes'
    out.mkdir()
    subprocess.run([JDK / 'bin/javac', '-encoding', 'UTF-8', '-source', '8', '-target', '8', '-Xlint:-options',
                    '-cp', PARSER, '-d', out, *sources, ROOT / 'shared/java/com/pilipala/catpaw/NodeRuntime.java',
                    ROOT / 'android/tests/NodeCapabilityChecks.java'], check=True)
    subprocess.run([JDK / 'bin/java', '-cp', str(out) + os.pathsep + str(PARSER),
                    'com.pilipala.catpaw.NodeCapabilityChecks', work / 'fixture'], check=True)
