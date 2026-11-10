"""Compile the actual native importer/guard caller; HTTP peers and Node boot are test fixtures."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
JDK = Path(os.environ.get('MARCOMOVIE_JDK', os.environ.get('JAVA_HOME', 'missing-jdk')))
PARSER = ROOT / 'android/tests/lib/json-20240303.jar'
ANDROID = Path(os.environ.get('MARCOMOVIE_ANDROID_JAR', ROOT / 'tools/android-35/android.jar'))
PRODUCTION = ROOT / 'android/build/classes.jar'
SRC = ROOT / 'android/src/main/java/com/pilipala/marcomovie'

with tempfile.TemporaryDirectory(prefix='guard-native-check-') as folder:
    work = Path(folder)
    shims = {
        'android/content/Context.java': '''package android.content;
public class Context { public static final int MODE_PRIVATE=0; private final java.io.File files,assets;
public Context(java.io.File f,java.io.File a){files=f;assets=a;}
public Context getApplicationContext(){return this;} public java.io.File getFilesDir(){return files;}
public android.content.res.AssetManager getAssets(){return new android.content.res.AssetManager(assets);} }''',
        'android/content/res/AssetManager.java': '''package android.content.res;
public class AssetManager { private final java.io.File root; public AssetManager(java.io.File r){root=r;}
public java.io.InputStream open(String name)throws java.io.IOException{return new java.io.FileInputStream(new java.io.File(root,name));} }''',
        'com/pilipala/catpaw/NodeRuntime.java': '''package com.pilipala.catpaw;
public final class NodeRuntime {
public static final class RuntimeUnavailableException extends java.io.IOException { public RuntimeUnavailableException(){super("fixture unavailable");} }
public static void start(android.content.Context c,String a,String b,String d)throws java.io.IOException {throw new RuntimeUnavailableException();} }''',
    }
    sources = []
    for relative, text in shims.items():
        file = work / relative
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text, encoding='utf-8')
        sources.append(file)
    assets = work / 'assets/catpaw'
    assets.mkdir(parents=True)
    for file in (ROOT / 'shared/catpaw').iterdir():
        if file.is_file():
            shutil.copy2(file, assets / file.name)
    classes = work / 'classes'
    classes.mkdir()
    dependencies = os.pathsep.join(map(str, (PARSER, ANDROID, PRODUCTION)))
    subprocess.run([JDK / 'bin/javac', '-encoding', 'UTF-8', '-source', '8', '-target', '8', '-Xlint:-options',
                    '-cp', dependencies, '-d', classes, *sources,
                    ROOT / 'shared/java/com/pilipala/source/Warehouse.java',
                    ROOT / 'shared/java/com/pilipala/catpaw/CatPawHost.java',
                    *(SRC / name for name in ('Cms.java', 'RequestScope.java', 'SourceEngine.java', 'CspEngine.java',
                                               'GuardEngine.java', 'DrpyEngine.java', 'MediaOptions.java', 'ProxyAddress.java')),
                    ROOT / 'android/tests/GuardChecks.java'], check=True)
    subprocess.run([JDK / 'bin/java', '-Dfile.encoding=UTF-8', '-cp', str(classes) + os.pathsep + dependencies,
                    'com.pilipala.marcomovie.GuardChecks', work], check=True)
