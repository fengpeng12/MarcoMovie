"""Reproduce fixed host libraries as portable JS; never compile user sources."""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'android/src/main/assets/python-host'
ASSET = OUT / 'compiled-modules.js'
MANIFEST = OUT / 'compiled-modules-provenance.json'
INPUTS = ['scripts/compile_python_modules.cjs', 'scripts/prepare_python_modules.py'] + [
    'android/src/main/assets/python-host/' + name for name in
    ('skulpt.min.js', 'skulpt-stdlib.js', 'html.js', 'regex.js', 'json.js', 'io.js', 'spider.js')]


def normalized(path):
    return path.read_bytes().replace(b'\r\n', b'\n').replace(b'\r', b'\n')


def digest(data):
    return hashlib.sha256(data).hexdigest()


def inputs():
    return {name: digest(normalized(ROOT / name)) for name in INPUTS}


def verify():
    report = json.loads(MANIFEST.read_bytes())
    if report.get('inputs') != inputs():
        raise ValueError('Python compiled module recipe changed; rebuild fixed libraries')
    data = normalized(ASSET)
    if report.get('bytes') != len(data) or report.get('sha256') != digest(data):
        raise ValueError('Python compiled module integrity mismatch')
    print('PASS reproducible compiled Python host libraries and unchanged compiler inputs')


def build():
    data = subprocess.check_output(['node', str(ROOT / 'scripts/compile_python_modules.cjs')], cwd=ROOT)
    ASSET.write_bytes(data)
    MANIFEST.write_text(json.dumps({'version': 1, 'inputs': inputs(), 'bytes': len(data),
                                   'sha256': digest(data)}, indent=2) + '\n', encoding='utf-8', newline='\n')
    verify()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    verify() if args.check else build()
