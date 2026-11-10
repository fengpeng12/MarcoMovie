"""Assemble and verify immutable Android Node artifacts; never rewrite native binaries."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from native_elf import inspect_elf
from native.build_catpaw_node import SOURCE_COMMIT, NDK_VERSION

SOURCE = 'https://github.com/nodejs-mobile/nodejs-mobile'
PATCH = 'e2b3e182bcade38f99e26ebb2bd9c3086d48dcd0b1fbec3fb59ea8f08ffca40c'
ABIS = {'armeabi-v7a': (32, 40), 'arm64-v8a': (64, 183), 'x86_64': (64, 62)}
LIBRARIES = ('libnode.so', 'libc++_shared.so')
MANIFEST = 'marco-android-runtime.json'


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def verify_provenance(provenance, abi, read):
    if (provenance.get('source') != SOURCE or provenance.get('commit') != SOURCE_COMMIT
            or provenance.get('ndk') != NDK_VERSION or provenance.get('api') != 23
            or provenance.get('abi') != abi or provenance.get('v8_char16_patch_sha256') != PATCH
            or provenance.get('libuv_android_pre24_barrier_fallback') is not True):
        raise ValueError('Unexpected Android Node provenance: ' + abi)
    rows = provenance.get('libraries')
    if not isinstance(rows, list) or len(rows) != 2 or {row.get('name') for row in rows} != set(LIBRARIES):
        raise ValueError('Incomplete Android Node artifact: ' + abi)
    verified = {}
    for row in rows:
        name = row['name']
        data = read('bin/' + abi + '/' + name)
        if not 0 < len(data) <= 160 * 1024 * 1024 or sha256(data) != row.get('sha256'):
            raise ValueError('Android runtime digest or size mismatch: ' + abi + '/' + name)
        elf = inspect_elf(data)
        if (elf['bits'], elf['machine']) != ABIS[abi]:
            raise ValueError('Wrong Android runtime architecture: ' + abi + '/' + name)
        if elf['bits'] == 64 and not elf['compatible_16kb']:
            raise ValueError('Android 64-bit runtime LOAD alignment failed: ' + abi + '/' + name)
        # Record the parser's findings, rather than trusting declared ELF evidence.
        verified[name] = {'sha256': sha256(data), 'bytes': len(data), **elf}
    return verified


def bundle(inputs, runs, output):
    if set(inputs) != set(ABIS) or set(runs) != set(ABIS):
        raise ValueError('A runtime release needs all three ABI artifacts and build run IDs')
    members = {}
    records = {}
    for abi, path in inputs.items():
        if not str(runs[abi]).isdigit():
            raise ValueError('Invalid build run ID')
        path = Path(path)
        provenance_path = 'provenance-' + abi + '.json'
        raw = (path / provenance_path).read_bytes()
        provenance = json.loads(raw)
        records[abi] = verify_provenance(provenance, abi, lambda name: (path / name).read_bytes())
        members[provenance_path] = raw
        license_text = (path / 'LICENSE').read_bytes()
        if not license_text or len(license_text) > 1024 * 1024:
            raise ValueError('Invalid runtime license')
        if 'LICENSE' in members and members['LICENSE'] != license_text:
            raise ValueError('ABI artifacts have different upstream license text')
        members['LICENSE'] = license_text
        for name in LIBRARIES:
            members['bin/' + abi + '/' + name] = (path / 'bin' / abi / name).read_bytes()
    manifest = {'version': 1, 'kind': 'marco-android-node', 'source': SOURCE,
                'commit': SOURCE_COMMIT, 'ndk': NDK_VERSION, 'api': 23,
                'buildRuns': {abi: str(runs[abi]) for abi in sorted(runs)},
                'abis': records,
                'files': {name: {'sha256': sha256(data), 'bytes': len(data)}
                          for name, data in sorted(members.items())}}
    members[MANIFEST] = (json.dumps(manifest, sort_keys=True, indent=2) + '\n').encode()
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(members.items()):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            archive.writestr(info, data, compresslevel=9)
    expected = sha256(output.read_bytes())
    verify_bundle(output, expected)
    output.with_suffix(output.suffix + '.sha256').write_text(expected + '  ' + output.name + '\n', encoding='utf-8')
    print(json.dumps({'archive': str(output), 'sha256': expected, 'buildRuns': manifest['buildRuns']}, indent=2))


def verify_bundle(path, expected):
    path = Path(path)
    if len(expected) != 64 or any(c not in '0123456789abcdef' for c in expected):
        raise ValueError('An explicit SHA-256 pin is required')
    if sha256(path.read_bytes()) != expected:
        raise ValueError('Android runtime archive checksum mismatch')
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        required = {MANIFEST, 'LICENSE'} | {'provenance-' + abi + '.json' for abi in ABIS} | {
            'bin/' + abi + '/' + name for abi in ABIS for name in LIBRARIES}
        if len(names) != len(required) or set(names) != required:
            raise ValueError('Unexpected or duplicate Android runtime archive paths')
        if archive.getinfo(MANIFEST).file_size > 128 * 1024:
            raise ValueError('Android runtime manifest is too large')
        manifest = json.loads(archive.read(MANIFEST))
        if (manifest.get('version') != 1 or manifest.get('kind') != 'marco-android-node'
                or manifest.get('source') != SOURCE or manifest.get('commit') != SOURCE_COMMIT
                or manifest.get('ndk') != NDK_VERSION or manifest.get('api') != 23
                or set(manifest.get('abis', {})) != set(ABIS)
                or set(manifest.get('files', {})) != required - {MANIFEST}
                or set(manifest.get('buildRuns', {})) != set(ABIS)
                or not all(str(run).isdigit() for run in manifest['buildRuns'].values())):
            raise ValueError('Unexpected Android runtime manifest')
        for name, row in manifest['files'].items():
            info = archive.getinfo(name)
            limit = 160 * 1024 * 1024 if name.endswith('.so') else 1024 * 1024
            if not 0 < info.file_size <= limit or info.file_size != row.get('bytes'):
                raise ValueError('Android runtime member size mismatch: ' + name)
            if sha256(archive.read(name)) != row.get('sha256'):
                raise ValueError('Android runtime member checksum mismatch: ' + name)
        for abi in ABIS:
            provenance = json.loads(archive.read('provenance-' + abi + '.json'))
            findings = verify_provenance(provenance, abi, archive.read)
            if findings != manifest['abis'][abi]:
                raise ValueError('Android runtime binary evidence mismatch: ' + abi)
        return manifest


def assignments(values):
    result = {}
    for value in values:
        key, separator, item = value.partition('=')
        if not separator or key not in ABIS or key in result or not item:
            raise ValueError('Use one ABI=value for each supported ABI')
        result[key] = item
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--input', action='append', required=True, help='ABI=artifact directory')
    parser.add_argument('--run', action='append', required=True, help='ABI=GitHub build run ID')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    bundle(assignments(args.input), assignments(args.run), args.output)
