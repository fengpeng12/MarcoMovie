"""Compile real native DRPY caller/staging/HTTP code; only Android context and Node boot are shims.

The local HTTP peer verifies the Java transport contract, not Node/JNI execution.
scripts/test_drpy_host.py separately executes the actual shared DRPY runtime.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
JDK = Path(os.environ.get('MARCOMOVIE_JDK', os.environ.get('JAVA_HOME', 'missing-jdk')))
PARSER = ROOT / 'android/tests/lib/json-20240303.jar'
SRC = ROOT / 'android/src/main/java/com/pilipala/marcomovie'

with tempfile.TemporaryDirectory(prefix='drpy-native-check-') as folder:
    work = Path(folder)
    shims = {
        'android/content/Context.java': '''package android.content;
public class Context { private final java.io.File files; private final android.content.res.AssetManager assets;
public Context(java.io.File f,java.io.File a){files=f;assets=new android.content.res.AssetManager(a);}
public Context getApplicationContext(){return this;} public java.io.File getFilesDir(){return files;}
public android.content.res.AssetManager getAssets(){return assets;} }''',
        'android/content/res/AssetManager.java': '''package android.content.res;
public class AssetManager { private final java.io.File root; public AssetManager(java.io.File r){root=r;}
public java.io.InputStream open(String name)throws java.io.IOException{return new java.io.FileInputStream(new java.io.File(root,name));} }''',
        'android/util/Base64.java': '''package android.util;
public final class Base64 { public static final int DEFAULT=0,NO_WRAP=2;
public static byte[] decode(String v,int f){return java.util.Base64.getMimeDecoder().decode(v);}
public static String encodeToString(byte[] v,int f){return java.util.Base64.getEncoder().encodeToString(v);} }''',
        'com/pilipala/catpaw/NodeRuntime.java': '''package com.pilipala.catpaw;
public final class NodeRuntime { public static void start(android.content.Context context,String a,String b,String c){throw new AssertionError("JVM check must not claim a native Node boot");} }''',
    }
    sources = []
    for relative, text in shims.items():
        file = work / relative
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text, encoding='utf-8')
        sources.append(file)
    assets = work / 'assets/catpaw'
    assets.mkdir(parents=True)
    for file in (ROOT / 'shared/catpaw').glob('drpy-*'):
        if file.is_file():
            shutil.copy2(file, assets / file.name)
    classes = work / 'classes'
    classes.mkdir()
    subprocess.run([JDK / 'bin/javac', '-encoding', 'UTF-8', '-source', '8', '-target', '8', '-Xlint:-options',
                    '-cp', PARSER, '-d', classes, *sources,
                    ROOT / 'shared/java/com/pilipala/source/Warehouse.java',
                    ROOT / 'shared/java/com/pilipala/catpaw/CatPawHost.java',
                    *(SRC / name for name in ('Cms.java', 'RequestScope.java', 'SourceEngine.java',
                                               'DrpyEngine.java', 'MediaOptions.java', 'ProxyAddress.java')),
                    ROOT / 'android/tests/DrpyChecks.java'], check=True)
    subprocess.run([JDK / 'bin/java', '-Dfile.encoding=UTF-8', '-cp', str(classes) + os.pathsep + str(PARSER),
                    'com.pilipala.marcomovie.DrpyChecks', work], check=True)
