"""Build production-code update fixtures; candidate APKs are parsed but never installed."""
import hashlib
import json
import os
from pathlib import Path
import xml.etree.ElementTree as ET
import zipfile

from build_android import ROOT, BUILD, SDK, JDK, ANDROID, exe, run
from sync_movie_mirror import apk_identity

OUT = BUILD / 'update-isolation'


def sign(source, destination, wrong=False):
    key = OUT / 'wrong.p12' if wrong else Path(os.environ.get('MARCOMOVIE_SIGNING_KEY', ROOT / 'android/private/development.p12'))
    if wrong and not key.exists():
        run(exe(JDK / 'bin', 'keytool'), '-genkeypair', '-alias', 'marcomovie', '-keystore', key,
            '-storepass', 'fixture', '-keypass', 'fixture', '-dname', 'CN=Isolated fixture', '-keyalg', 'RSA', '-validity', '30')
    run(exe(JDK / 'bin', 'java'), '-jar', SDK / 'lib/apksigner.jar', 'sign', '--ks', key,
        '--ks-key-alias', 'marcomovie', '--ks-pass', 'pass:fixture' if wrong else 'env:MARCOMOVIE_KEY_PASSWORD',
        '--out', destination, source)


def main():
    (OUT / 'assets').mkdir(parents=True, exist_ok=True)
    (OUT / 'classes').mkdir(exist_ok=True)
    (OUT / 'dex').mkdir(exist_ok=True)
    attrs = ET.parse(ROOT / 'android/src/main/AndroidManifest.xml').getroot().attrib
    ns = '{http://schemas.android.com/apk/res/android}'
    parts = attrs[ns + 'versionName'].split('.')
    version = '.'.join(parts[:2] + [str(int(parts[2]) + 1)])
    code = int(attrs[ns + 'versionCode']) + 1
    for name, edition in [('tv', 'tv'), ('mobile', 'mobile'), ('missing', None), ('unknown', 'unknown')]:
        metadata = '' if edition is None else f'<meta-data android:name="com.pilipala.marcomovie.EDITION" android:value="{edition}"/>'
        manifest = OUT / (name + '.xml')
        manifest.write_text(f'<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.pilipala.marcomovie" android:versionCode="{code}" android:versionName="{version}"><uses-sdk android:minSdkVersion="23" android:targetSdkVersion="28"/><application android:label="Never install">{metadata}</application></manifest>', encoding='utf-8')
        unsigned = OUT / (name + '-unsigned.apk')
        run(exe(SDK, 'aapt2'), 'link', '-o', unsigned, '--manifest', manifest, '-I', ANDROID)
        sign(unsigned, OUT / 'assets' / (name + '.apk'))
        if name in ('tv', 'mobile'):
            sign(unsigned, OUT / 'assets' / ('wrong-signer-' + name + '.apk'), wrong=True)
    # Verify the mirror's binary manifest reader against real aapt2 output too.
    for edition in ('tv', 'mobile'):
        identity = apk_identity((OUT / 'assets' / (edition + '.apk')).read_bytes())
        assert identity['edition'] == edition and identity['versionCode'] == code and identity['versionName'] == version
    manifest = OUT / 'AndroidManifest.xml'
    manifest.write_text('<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.pilipala.marcomovie.test"><uses-sdk android:minSdkVersion="23" android:targetSdkVersion="28"/><application/><instrumentation android:name="com.pilipala.marcomovie.UpdateIsolationProbe" android:targetPackage="com.pilipala.marcomovie"/></manifest>', encoding='utf-8')
    run(exe(SDK, 'aapt2'), 'link', '-o', OUT / 'probe-resources.apk', '--manifest', manifest, '-I', ANDROID, '-A', OUT / 'assets')
    run(exe(JDK / 'bin', 'javac'), '-encoding', 'UTF-8', '-source', '8', '-target', '8', '-Xlint:-options',
        '-classpath', str(ANDROID) + os.pathsep + str(BUILD / 'classes.jar'), '-d', OUT / 'classes', ROOT / 'android/tests/device/UpdateIsolationProbe.java')
    with zipfile.ZipFile(OUT / 'classes.jar', 'w') as jar:
        for file in (OUT / 'classes').rglob('*.class'): jar.write(file, file.relative_to(OUT / 'classes').as_posix())
    run(exe(JDK / 'bin', 'java'), '-cp', SDK / 'lib/d8.jar', 'com.android.tools.r8.D8', '--min-api', '23', '--lib', ANDROID, '--classpath', BUILD / 'classes.jar', '--output', OUT / 'dex', OUT / 'classes.jar')
    with zipfile.ZipFile(OUT / 'probe-resources.apk') as src, zipfile.ZipFile(OUT / 'probe-unsigned.apk', 'w', zipfile.ZIP_DEFLATED) as dst:
        for entry in src.infolist(): dst.writestr(entry, src.read(entry.filename))
        dst.write(OUT / 'dex/classes.dex', 'classes.dex')
    sign(OUT / 'probe-unsigned.apk', OUT / 'probe.apk')
    hashes = {}
    for edition, name in [('tv', 'unsigned.apk'), ('mobile', 'unsigned-mobile.apk')]:
        with zipfile.ZipFile(BUILD / name) as src, zipfile.ZipFile(OUT / (edition + '-unsigned.apk'), 'w', zipfile.ZIP_DEFLATED) as dst:
            for entry in src.infolist():
                if not entry.filename.startswith('lib/'): dst.writestr(entry, src.read(entry.filename))
        sign(OUT / (edition + '-unsigned.apk'), OUT / (edition + '.apk'))
        hashes[edition] = hashlib.sha256((OUT / (edition + '.apk')).read_bytes()).hexdigest()
    (OUT / 'scope.json').write_text(json.dumps(dict(scope='Production updater and Android package parser only. Native media libraries omitted; no source/decoder/device acceptance. Candidate updates never installed.', production_classes_sha256=hashlib.sha256((BUILD / 'classes.jar').read_bytes()).hexdigest(), fixture_sha256=hashes), indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__': main()
