"""Build only the HTML dependency needed by Python, using the existing npm lock.

python scripts/prepare_python_html.py          # npm ci in an isolated build cache
python scripts/prepare_python_html.py --check  # offline asset/provenance verification
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'android/src/main/assets/python-host'
LOCK = ROOT / 'shared/catpaw/drpy-package-lock.json'
ENTRY = ROOT / 'scripts/python-html/entry.mjs'
MANIFEST = OUT / 'parser-provenance.json'
VERSION = '0.25.12'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def normalized(path):
    return path.read_bytes().replace(b'\r\n', b'\n').replace(b'\r', b'\n')


def verify():
    doc = json.loads(MANIFEST.read_bytes())
    if doc['lock_sha256'] != digest(normalized(LOCK)) or doc['entry_sha256'] != digest(normalized(ENTRY)):
        raise ValueError('Python HTML source recipe changed; rebuild the asset')
    packages = json.loads(LOCK.read_bytes())['packages']
    if doc['bundler'] != 'esbuild@' + VERSION or doc['packages'].get('node_modules/cheerio', {}).get('version') != '1.0.0-rc.12':
        raise ValueError('Unexpected Python HTML dependency versions')
    if set(doc['files']) != {'parser.js', 'parser-LICENSE.txt'}:
        raise ValueError('Unexpected Python HTML output list')
    for name, expected in doc['files'].items():
        data = normalized(OUT / name)
        if len(data) != expected['bytes'] or digest(data) != expected['sha256']:
            raise ValueError('Python HTML asset digest mismatch: ' + name)
    for name, record in doc['packages'].items():
        if any(packages[name].get(key) != value for key, value in record.items()):
            raise ValueError('Python HTML dependency differs from npm lock: ' + name)
    # Python HTML must not initialize unrelated template, crypto or JSONPath engines.
    forbidden = {'crypto-js', 'jsencrypt', 'nunjucks', 'jsonpath-plus', 'parse5'}
    if any(name.split('/')[-1] in forbidden for name in doc['packages']):
        raise ValueError('Unrelated runtime included in Python HTML bundle')
    print('PASS pinned Python HTML asset, recipe and dependency integrity')


def build(work):
    work.mkdir(parents=True, exist_ok=True)
    packages = json.loads(LOCK.read_bytes())['packages']
    manifest = {'private': True, 'dependencies': packages['']['dependencies']}
    (work / 'package.json').write_text(json.dumps(manifest), encoding='utf-8')
    (work / 'package-lock.json').write_bytes(normalized(LOCK))
    npm = shutil.which('npm.cmd' if os.name == 'nt' else 'npm')
    if not npm:
        raise RuntimeError('npm is required to reproduce the pinned HTML parser')
    subprocess.run([npm, 'ci', '--ignore-scripts', '--no-audit', '--no-fund'], cwd=work, check=True)
    (work / 'entry.mjs').write_bytes(normalized(ENTRY))
    binary = work / ('node_modules/@esbuild/win32-x64/esbuild.exe' if os.name == 'nt' else 'node_modules/.bin/esbuild')
    subprocess.run([str(binary), 'entry.mjs', '--bundle', '--platform=browser', '--format=iife',
                    '--global-name=MoviePythonHtml', '--target=es2020', '--charset=utf8',
                    '--outfile=parser.js', '--metafile=parser-meta.json'], cwd=work, check=True)
    meta = json.loads((work / 'parser-meta.json').read_bytes())
    used = set()
    for name in meta['inputs']:
        if not name.startswith('node_modules/'):
            if name != 'entry.mjs':
                raise ValueError('Unrecognized HTML input: ' + name)
            continue
        parts = name.split('/')
        used.add('/'.join(parts[:3 if parts[1].startswith('@') else 2]))
    files = {
        'parser.js': normalized(work / 'parser.js'),
        # Retain the already reviewed full npm notices, including boolbase's
        # supplemental ISC text absent from its upstream tarball.
        'parser-LICENSE.txt': normalized(ROOT / 'shared/catpaw/drpy-dependencies-LICENSE.txt'),
    }
    doc = {'version': 1, 'bundler': 'esbuild@' + VERSION,
           'lock_sha256': digest(normalized(LOCK)), 'entry_sha256': digest(normalized(ENTRY)),
           'packages': {name: {key: packages[name][key] for key in ('version', 'resolved', 'integrity', 'license')
                               if key in packages[name]} for name in sorted(used)},
           'files': {name: {'bytes': len(data), 'sha256': digest(data)} for name, data in files.items()}}
    for name, data in files.items():
        (OUT / name).write_bytes(data)
    MANIFEST.write_text(json.dumps(doc, indent=2) + '\n', encoding='utf-8', newline='\n')
    verify()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--work', type=Path, default=ROOT / 'tools/python-html-build')
    args = parser.parse_args()
    verify() if args.check else build(args.work.resolve())
