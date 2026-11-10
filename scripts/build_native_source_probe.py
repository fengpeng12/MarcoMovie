"""Build an isolated x86_64 Node/DRPY instrumented fixture from verified source-built libraries.

Production dex/resources/assets are retained. The derivative contains only the three
Node libraries; full APK decoder/QuickJS native compatibility remains a separate gate.
Never writes dist or edits production runtime pins.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import zipfile

from build_android import ROOT, BUILD, JDK, SDK, ANDROID, run, exe
from build_catpaw_android import toolchain
from native_elf import inspect_elf, inspect_apk
from native.build_catpaw_node import SOURCE_COMMIT, NDK_VERSION

OUT = BUILD / 'native-source-probe'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def sign(source, name):
    aligned = OUT / (name + '-aligned.apk')
    output = OUT / (name + '.apk')
    run(exe(SDK, 'zipalign'), '-f', '4', source, aligned)
    run(exe(JDK / 'bin', 'java'), '-jar', SDK / 'lib/apksigner.jar', 'sign',
        '--ks', Path(os.environ.get('MARCOMOVIE_SIGNING_KEY', str(ROOT / 'android/private/development.p12'))),
        '--ks-key-alias', 'marcomovie', '--ks-pass', 'env:MARCOMOVIE_KEY_PASSWORD', '--out', output, aligned)
    return output


def main(runtime):
    provenance = json.loads((runtime / 'provenance-x86_64.json').read_text(encoding='utf-8'))
    if (provenance.get('commit') != SOURCE_COMMIT or provenance.get('ndk') != NDK_VERSION
            or provenance.get('api') != 23 or provenance.get('abi') != 'x86_64'
            or provenance.get('libuv_android_pre24_barrier_fallback') is not True):
        raise ValueError('Unexpected source-built Node provenance')
    libraries = {}
    for name in ('libnode.so', 'libc++_shared.so'):
        data = (runtime / 'bin/x86_64' / name).read_bytes()
        record = next(row for row in provenance['libraries'] if row['name'] == name)
        evidence = inspect_elf(data)
        if digest(data) != record['sha256'] or evidence['machine'] != 62 or not evidence['compatible_16kb']:
            raise ValueError('Node artifact hash, architecture or LOAD alignment mismatch: ' + name)
        libraries[name] = data
    OUT.mkdir(parents=True, exist_ok=True)
    ndk = toolchain()
    if NDK_VERSION not in (ndk.parents[3] / 'source.properties').read_text():
        raise ValueError('Use the same pinned NDK as the verified Node artifact')
    bridge = OUT / 'libmarco_node.so'
    run(exe(ndk / 'bin', 'clang'), '--target=x86_64-linux-android23', '--sysroot=' + str(ndk / 'sysroot'),
        '-shared', '-fPIC', '-fno-stack-protector', '-fno-builtin', '-nostdlib', '-O2',
        '-Wl,--no-undefined', '-Wl,-z,max-page-size=16384', '-Wl,-soname,libmarco_node.so',
        ROOT / 'shared/catpaw/node_bridge.c', runtime / 'bin/x86_64/libnode.so', '-o', bridge)
    libraries['libmarco_node.so'] = bridge.read_bytes()
    for name, data in libraries.items():
        evidence = inspect_elf(data)
        if evidence['machine'] != 62 or not evidence['compatible_16kb']:
            raise ValueError('16 KB bridge/Node check failed: ' + name)
    capability = {'version': 1, 'maxPageSize': 16384,
                  'abis': {'x86_64': {name: digest(data) for name, data in libraries.items()}}}
    for folder in ('classes', 'dex'):
        destination = OUT / folder
        destination.mkdir(exist_ok=True)
        for old in destination.rglob('*'):
            if old.is_file():
                if not old.resolve().is_relative_to(OUT.resolve()):
                    raise ValueError('Probe cleanup path escapes output')
                old.unlink()
    manifest = OUT / 'AndroidManifest.xml'
    manifest.write_text('<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.pilipala.marcomovie.test">'
                        '<uses-sdk android:minSdkVersion="23" android:targetSdkVersion="28"/>'
                        '<application android:label="Native source regression"/>'
                        '<instrumentation android:name="com.pilipala.marcomovie.NativeSourceProbe" android:targetPackage="com.pilipala.marcomovie"/>'
                        '</manifest>', encoding='utf-8')
    run(exe(SDK, 'aapt2'), 'link', '-o', OUT / 'resources.apk', '--manifest', manifest, '-I', ANDROID)
    run(exe(JDK / 'bin', 'javac'), '-encoding', 'UTF-8', '-source', '8', '-target', '8', '-Xlint:-options',
        '-cp', str(ANDROID) + os.pathsep + str(BUILD / 'classes.jar'), '-d', OUT / 'classes',
        ROOT / 'android/tests/device/NativeSourceProbe.java')
    with zipfile.ZipFile(OUT / 'classes.jar', 'w') as jar:
        for file in (OUT / 'classes').rglob('*.class'):
            jar.write(file, file.relative_to(OUT / 'classes').as_posix())
    run(exe(JDK / 'bin', 'java'), '-cp', SDK / 'lib/d8.jar', 'com.android.tools.r8.D8', '--min-api', '23',
        '--lib', ANDROID, '--classpath', BUILD / 'classes.jar', '--output', OUT / 'dex', OUT / 'classes.jar')
    with zipfile.ZipFile(OUT / 'resources.apk') as source, zipfile.ZipFile(OUT / 'probe-unsigned.apk', 'w') as apk:
        for entry in source.infolist():
            apk.writestr(entry, source.read(entry.filename))
        for file in (OUT / 'dex').glob('*.dex'):
            apk.write(file, file.name)
    sign(OUT / 'probe-unsigned.apk', 'probe')
    app = BUILD / 'unsigned.apk'
    omitted = []
    with zipfile.ZipFile(app) as source, zipfile.ZipFile(OUT / 'fixture-unsigned.apk', 'w', zipfile.ZIP_DEFLATED) as apk:
        for entry in source.infolist():
            if entry.filename.startswith('lib/'):
                omitted.append(entry.filename)
            elif entry.filename != 'assets/catpaw/runtime-capabilities.json':
                apk.writestr(entry, source.read(entry.filename))
        for name, data in libraries.items():
            apk.writestr('lib/x86_64/' + name, data, compress_type=zipfile.ZIP_DEFLATED)
        apk.writestr('assets/catpaw/runtime-capabilities.json', json.dumps(capability).encode())
    fixture = sign(OUT / 'fixture-unsigned.apk', 'fixture')
    rows = inspect_apk(fixture)
    if len(rows) != 3 or any(not row['compatible_16kb'] or not row['zip_16kb_aligned'] for row in rows):
        raise ValueError('Final fixture native page alignment failed')
    (OUT / 'scope.json').write_text(json.dumps({
        'scope': 'Real Node/JNI, DRPY and CatPaw source behavior only. Native codec/QuickJS libraries omitted. Not a distributable APK or full Android 16 KB acceptance.',
        'production_unsigned_sha256': digest(app.read_bytes()),
        'production_classes_sha256': digest((BUILD / 'classes.jar').read_bytes()),
        'fixture_sha256': digest(fixture.read_bytes()), 'capability': capability,
        'runtime_provenance': provenance, 'native_elf': rows, 'omitted_production_libraries': omitted,
    }, indent=2) + '\n', encoding='utf-8')
    print(OUT)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--runtime-dir', type=Path, required=True)
    main(parser.parse_args().runtime_dir.resolve())
