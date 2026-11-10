"""Build isolated API 23 UI/source-host fixtures after build_android.py.

The app keeps production bytecode/resources but only includes pinned x86
QuickJS JNI. No ARM decoder/Node claims and no files are written to dist/.
"""

from pathlib import Path
import argparse
import hashlib
import json
import os
import wave
import zipfile

from build_android import ROOT, BUILD, JDK, SDK, ANDROID, run, exe
from build_quickjs_deadline import build as build_quickjs_deadline


OUT = BUILD / "api23-probes"
PROBES = ("SubtitleProbe", "HomeProbe", "SourceHostProbe")


def sign(source, name):
    aligned = OUT / (name + "-aligned.apk")
    output = OUT / (name + ".apk")
    run(exe(SDK, "zipalign"), "-f", "4", source, aligned)
    run(
        exe(JDK / "bin", "java"), "-jar", SDK / "lib/apksigner.jar", "sign",
        "--ks", Path(os.environ.get("MARCOMOVIE_SIGNING_KEY", str(ROOT / "android/private/development.p12"))),
        "--ks-key-alias", "marcomovie", "--ks-pass", "env:MARCOMOVIE_KEY_PASSWORD", "--out", output, aligned,
    )
    return output


def build_live_plugin(app_classes):
    # Deliberately separate DEX: exercise DexClassLoader, not a class on the app path.
    fixture = OUT / 'live-plugin'
    for name in ('classes', 'dex'):
        (fixture/name).mkdir(parents=True, exist_ok=True)
        for old in (fixture/name).rglob('*.class' if name == 'classes' else '*.dex'):
            if not old.resolve().is_relative_to(fixture.resolve()):
                raise RuntimeError('Plugin fixture output leaves its build directory')
            old.unlink()
    run(exe(JDK/'bin', 'javac'), '-encoding', 'UTF-8', '-source', '8', '-target', '8', '-Xlint:-options',
        '-classpath', str(ANDROID)+os.pathsep+str(app_classes), '-d', fixture/'classes',
        *sorted((ROOT/'android/tests/device/plugin').glob('*.java')))
    with zipfile.ZipFile(fixture/'classes.jar', 'w') as jar:
        for compiled in (fixture/'classes').rglob('*.class'):
            jar.write(compiled, compiled.relative_to(fixture/'classes').as_posix())
    run(exe(JDK/'bin', 'java'), '-cp', SDK/'lib/d8.jar', 'com.android.tools.r8.D8', '--min-api', '23',
        '--lib', ANDROID, '--classpath', app_classes, '--output', fixture/'dex', fixture/'classes.jar')
    with zipfile.ZipFile(OUT/'assets/live-fixture.jar', 'w') as jar:
        for dex in (fixture/'dex').glob('*.dex'):
            jar.write(dex, dex.name)


def main(phone=False):
    global OUT, PROBES
    OUT = BUILD / ('phone-source-probe' if phone else 'api23-probes')
    PROBES = ('SourceHostProbe',) if phone else ('SubtitleProbe', 'HomeProbe', 'SourceHostProbe')
    abi = 'x86_64' if phone else 'x86'
    source = BUILD / ('unsigned-mobile.apk' if phone else 'unsigned.apk')
    app_classes = BUILD / "classes.jar"
    if not source.exists() or not app_classes.exists():
        raise RuntimeError("Run build_android.py first; this script never builds the production app")
    for name in ("classes", "dex", "assets"):
        folder = OUT / name
        folder.mkdir(parents=True, exist_ok=True)
        for old in folder.rglob("*.class" if name == "classes" else "*.dex" if name == "dex" else "*.wav"):
            if not old.resolve().is_relative_to(OUT.resolve()):
                raise RuntimeError("Fixture cleanup leaves output directory")
            old.unlink()
    manifest = OUT / "AndroidManifest.xml"
    entries = "".join(
        '<instrumentation android:name="com.pilipala.marcomovie.' + name
        + '" android:targetPackage="com.pilipala.marcomovie"/>' for name in PROBES
    )
    manifest.write_text(
        '<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.pilipala.marcomovie.test">'
        '<uses-sdk android:minSdkVersion="23" android:targetSdkVersion="28"/>'
        '<application android:label="Local source regression"/>' + entries + '</manifest>', encoding="utf-8",
    )
    with wave.open(str(OUT / "assets/timeline.wav"), "wb") as audio:
        audio.setparams((1, 2, 8000, 0, "NONE", "not compressed"))
        audio.writeframes(b"\x00\x00" * 8000 * 60)
    build_live_plugin(app_classes)
    run(exe(SDK, "aapt2"), "link", "-o", OUT / "resources.apk", "--manifest", manifest,
        "-I", ANDROID, "-A", OUT / "assets")
    run(exe(JDK / "bin", "javac"), "-encoding", "UTF-8", "-source", "8", "-target", "8", "-Xlint:-options",
        "-classpath", str(ANDROID) + os.pathsep + str(app_classes), "-d", OUT / "classes",
        *(ROOT / ("android/tests/device/" + name + ".java") for name in PROBES),
        ROOT / "android/tests/device/HttpT4Checks.java")
    with zipfile.ZipFile(OUT / "classes.jar", "w") as jar:
        for compiled in (OUT / "classes").rglob("*.class"):
            jar.write(compiled, compiled.relative_to(OUT / "classes").as_posix())
    run(exe(JDK / "bin", "java"), "-cp", SDK / "lib/d8.jar", "com.android.tools.r8.D8", "--min-api", "23",
        "--lib", ANDROID, "--classpath", app_classes, "--output", OUT / "dex", OUT / "classes.jar")
    with zipfile.ZipFile(OUT / "resources.apk") as resources, zipfile.ZipFile(OUT / "probe-unsigned.apk", "w") as apk:
        for entry in resources.infolist():
            apk.writestr(entry, resources.read(entry.filename))
        for dex in (OUT / "dex").glob("*.dex"):
            apk.write(dex, dex.name)
    sign(OUT / "probe-unsigned.apk", "probe")

    wrapper_name = "wrapper-android-3.2.3.aar"
    dependency = next(item for item in json.loads((ROOT / "android/dependencies.json").read_text(encoding="utf-8"))
                      if item["url"].endswith("/" + wrapper_name))
    wrapper = ROOT / "tools/java-dependencies" / wrapper_name
    if hashlib.sha256(wrapper.read_bytes()).hexdigest() != dependency["sha256"]:
        raise RuntimeError("Pinned QuickJS JNI digest mismatch")
    deadline_files = build_quickjs_deadline()
    with zipfile.ZipFile(source) as production, zipfile.ZipFile(wrapper) as jni, zipfile.ZipFile(OUT / "fixture-unsigned.apk", "w") as apk:
        for entry in production.infolist():
            if not entry.filename.startswith("lib/"):
                apk.writestr(entry, production.read(entry.filename))
        apk.writestr('lib/'+abi+'/libquickjs-android-wrapper.so', jni.read('jni/'+abi+'/libquickjs-android-wrapper.so'))
        apk.writestr('lib/'+abi+'/libmovie-quickjs-deadline.so', deadline_files['lib/'+abi+'/libmovie-quickjs-deadline.so'])
    fixture = sign(OUT / "fixture-unsigned.apk", "fixture")
    (OUT / "scope.json").write_text(json.dumps({
        "scope": ("API 36 phone QuickJS/Python JNI and local source requests only. " if phone else
                  "API 23 TV UI, local system-player subtitles, synthetic home/history and QuickJS/Python JNI only. ")
                 + "No ARM decoder or CatPaw Node acceptance. Not distributable.",
        "production_unsigned_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "production_classes_sha256": hashlib.sha256(app_classes.read_bytes()).hexdigest(),
        "fixture_sha256": hashlib.sha256(fixture.read_bytes()).hexdigest(),
        "live_plugin_sha256": hashlib.sha256((OUT/'assets/live-fixture.jar').read_bytes()).hexdigest(),
        "probes": list(PROBES),
        "fixture_abi": abi,
        "fixture_edition": 'mobile' if phone else 'tv',
    }, indent=2) + "\n", encoding="utf-8")
    print(OUT)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--phone', action='store_true', help='Build API 36 phone SourceHostProbe with x86_64 JNI')
    main(parser.parse_args().phone)
