"""Pinned compile-only inputs for standalone script-host JVM checks.

These checks must work in a fresh checkout, without a prior Android app build.
Native engines are not loaded by this helper or by the pure-JVM checks.
"""
from pathlib import Path
import hashlib
import io
import json
import os
import sys
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[2]


def verified_file(path, url, digest):
    if path.exists():
        data = path.read_bytes()
    else:
        with urllib.request.urlopen(url, timeout=30) as response:
            data = response.read()
    if hashlib.sha256(data).hexdigest() != digest:
        raise RuntimeError('Script test dependency digest mismatch: ' + path.name)
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    return data


def prepare():
    parser = ROOT / 'android/tests/lib/json-20240303.jar'
    verified_file(parser,
                  'https://repo.maven.apache.org/maven2/org/json/json/20240303/json-20240303.jar',
                  '3cf6cd6892e32e2b4c1c39e0f52f5248a2f5b37646fdfbb79a66b46b618414ed')
    android_override = os.environ.get('MARCOMOVIE_ANDROID_JAR')
    if android_override:
        android = Path(android_override)
        if not android.is_file():
            raise RuntimeError('Configured Android compile library is unavailable')
    else:
        sys.path.insert(0, str(ROOT / 'scripts'))
        from prepare_android_platform import prepare as prepare_android
        android = prepare_android()
    result = [parser, android]
    manifest = json.loads((ROOT / 'android/dependencies.json').read_text(encoding='utf-8'))
    for name in ('wrapper-android', 'wrapper-java', 'jsoup'):
        matches = [item for item in manifest if item['name'] == name]
        if len(matches) != 1:
            raise RuntimeError('Expected one pinned script dependency: ' + name)
        item = matches[0]
        package = ROOT / 'tools/java-dependencies' / item['url'].rsplit('/', 1)[1]
        data = verified_file(package, item['url'], item['sha256'])
        if package.suffix == '.aar':
            classes = ROOT / 'android/build/script-test-deps' / package.stem / 'classes.jar'
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                payload = archive.read('classes.jar')
            classes.parent.mkdir(parents=True, exist_ok=True)
            # Re-derive from the verified AAR, never trust a previous app build.
            classes.write_bytes(payload)
            result.append(classes)
        else:
            result.append(package)
    return result
