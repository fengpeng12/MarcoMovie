"""Prepare pinned compile dependencies for JS normalization checks on a clean host."""
from pathlib import Path
import hashlib, json, urllib.request, zipfile
from prepare_android_platform import prepare

ROOT = Path(__file__).resolve().parents[1]
prepare()
names = {'wrapper-android-3.2.3.aar', 'wrapper-java-3.2.3.jar', 'jsoup-1.18.3.jar'}
for item in json.loads((ROOT/'android/dependencies.json').read_text(encoding='utf-8')):
    name = item['url'].rsplit('/', 1)[1]
    if name not in names:
        continue
    target = ROOT/'tools/java-dependencies'/name
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.exists():
        target.write_bytes(urllib.request.urlopen(item['url'], timeout=60).read())
    if hashlib.sha256(target.read_bytes()).hexdigest() != item['sha256']:
        raise RuntimeError('Dependency checksum mismatch: '+name)
    if target.suffix == '.aar':
        output = ROOT/'android/build/aar'/target.stem/'classes.jar'
        output.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(target) as archive:
            output.write_bytes(archive.read('classes.jar'))
    names.remove(name)
if names:
    raise RuntimeError('Missing dependency declarations: '+', '.join(sorted(names)))
print('Pinned JS test compile dependencies ready')
