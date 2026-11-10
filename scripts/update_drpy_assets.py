"""Refresh the checked asset list after changing shared DRPY runtime files."""
from pathlib import Path
import hashlib
import json
import sys

ROOT = Path(__file__).resolve().parents[1] / 'shared/catpaw'
NAMES = ['drpy-worker.cjs', 'drpy-http.cjs', 'drpy-schema.cjs', 'drpy-core.js',
         'drpy-dependencies.js', 'drpy-LICENSE.txt', 'drpy-dependencies-LICENSE.txt',
         'drpy-provenance.json', 'drpy-guard-extractor.cjs', 'drpy-dm84-adapter.cjs',
         'drpy-bootstrap-worker.cjs', 'drpy-auete-adapter.cjs', 'drpy-bttwoo-adapter.cjs',
         'drpy-appgz-adapter.cjs', 'drpy-rsa.cjs',
         'drpy-t4-extractor.cjs', 'drpy-t4-adapter.cjs',
         'drpy-fy-extractor.cjs', 'drpy-fy-adapter.cjs']


def update(check=False):
    files = []
    for name in NAMES:
        path = ROOT / name
        raw = path.read_bytes()
        # Git/source archives use LF. Hash the same bytes on every build host,
        # including files newly written with Windows CRLF before their first add.
        data = raw.replace(b'\r\n', b'\n').replace(b'\r', b'\n')
        if data != raw:
            if check:
                raise ValueError('DRPY asset must use LF before hashing: ' + name)
            path.write_bytes(data)
        files.append({'name': name, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
    manifest = (json.dumps({'version': 1,
        'runtime': 'drpy2-ca23ffdb-1', 'files': files}, indent=2) + '\n').encode('utf-8')
    target = ROOT / 'drpy-assets.json'
    if check:
        if target.read_bytes() != manifest:
            raise ValueError('DRPY asset manifest is stale; run scripts/update_drpy_assets.py')
    else:
        target.write_bytes(manifest)


if __name__ == '__main__':
    update(check='--check' in sys.argv[1:])
