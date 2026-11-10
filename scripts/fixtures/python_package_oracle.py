"""Regenerate self-authored package fixtures with the local CPython interpreter.

Run: python scripts/fixtures/python_package_oracle.py
No third-party source, network, or application host is involved.
"""
from pathlib import Path
import base64
import json
import os
import subprocess
import sys
import tempfile

directory = Path(__file__).resolve().parent
source = (directory / 'python_package_contract.py').read_text(encoding='utf-8')
helper = """import json
helper_location = __file__.replace('\\\\', '/').endswith('/bundle/helper.py')
with open(__file__.replace('\\\\', '/').rsplit('/', 1)[0] + '/data/metadata.json', encoding='utf-8') as file:
    title = json.load(file)['title']
"""
reader = """reader_location = __file__.replace('\\\\', '/').endswith('/bundle/tools/reader.py')
local = open(__file__.replace('\\\\', '/').rsplit('/', 1)[0] + '/local.txt', encoding='utf-8').read()
"""
modules = {'helper.py': helper, 'tools/__init__.py': '', 'tools/reader.py': reader}
files = {
    'bundle/main.py': source.encode('utf-8'),
    'bundle/data/metadata.json': json.dumps({'title': 'Package fixture 中文🎬', 'count': 2}, ensure_ascii=False).encode('utf-8'),
    'bundle/data/payload.bin': bytes([0, 255, 10, 128, 65, 10, 66]),
    'bundle/data/empty.bin': b'',
    'bundle/data/ascii.txt': b'first\r\nsecond\rlast\n',
    'bundle/data/lines.txt': '甲🎬\r\nbeta\rgamma\nlast'.encode('utf-8'),
    'bundle/data/utf8.txt': '甲🎬\n二\n'.encode('utf-8'),
    'bundle/data/bom.txt': b'\xef\xbb\xbf' + '甲\r\nlast'.encode('utf-8'),
    'bundle/data/invalid.bin': bytes([255]),
    'bundle/data/中文 空格.txt': '本地只读'.encode('utf-8'),
    'bundle/tools/local.txt': b'helper local bytes',
    'shared.txt': b'parent resource',
}
files.update({'bundle/' + name: text.encode('utf-8') for name, text in modules.items()})
fixture = {
    'version': 1, 'source': 'python_package_contract.py', 'modules': modules,
    'packageData': {'entry': 'bundle/main.py', 'files': {
        name: base64.b64encode(data).decode('ascii') for name, data in files.items()
    }},
}
with tempfile.TemporaryDirectory(prefix='python-package-oracle-') as temporary:
    root = Path(temporary)
    for name, data in files.items():
        file = root / name
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_bytes(data)
    completed = subprocess.run(
        [sys.executable, '-X', 'utf8', (root / 'bundle/main.py').as_posix()],
        cwd=root / 'bundle', capture_output=True, check=True,
        env={**os.environ, 'PYTHONIOENCODING': 'utf-8'},
    )
    expected = json.loads(completed.stdout)
for name, value in [('python_package_fixture.json', fixture), ('python_package_expected.json', expected)]:
    (directory / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8', newline='\n')
print('CPython ' + sys.version.split()[0] + ': ' + str(len(expected)) + ' package oracle cases')
