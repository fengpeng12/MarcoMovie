"""Verify candidate APK Node bytes against a pinned runtime ZIP; report all other ELF limits."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile

from native.catpaw_runtime_bundle import ABIS, verify_bundle
from native_elf import inspect_apk, inspect_elf

ROOT = Path(__file__).resolve().parents[1]
LIBRARIES = ('libnode.so', 'libmarco_node.so', 'libc++_shared.so')


def digest(data):
    return hashlib.sha256(data).hexdigest()


def verify_apk(path, runtime, build):
    rows = inspect_apk(path)
    by_path = {row['path']: row for row in rows}
    node_abis = {row['path'].split('/')[1] for row in rows if row['path'].endswith('/libnode.so')}
    if not node_abis or not node_abis.issubset(ABIS):
        raise ValueError('APK has missing or unexpected Node ABI')
    hashes = {}
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError('APK contains duplicate archive entries')
        capability_name = 'assets/catpaw/runtime-capabilities.json'
        capability = json.loads(archive.read(capability_name)) if capability_name in names else None
        expected_capability = {}
        for abi in sorted(node_abis):
            abi_hashes = {}
            for name in LIBRARIES:
                key = 'lib/' + abi + '/' + name
                if key not in by_path:
                    raise ValueError('APK missing Node dependency: ' + key)
                data = archive.read(key)
                sha = digest(data)
                elf = inspect_elf(data)
                if (elf['bits'], elf['machine']) != ABIS[abi]:
                    raise ValueError('APK Node architecture mismatch: ' + key)
                built = build['libraries'].get(key)
                if not built or built.get('sha256') != sha or built.get('bytes') != len(data):
                    raise ValueError('APK native library differs from build evidence: ' + key)
                if name != 'libmarco_node.so' and runtime['abis'][abi][name]['sha256'] != sha:
                    raise ValueError('APK runtime differs from original artifact: ' + key)
                if elf['bits'] == 64 and not (elf['compatible_16kb'] and by_path[key]['zip_16kb_aligned']):
                    raise ValueError('APK Node library failed 16 KB ELF/ZIP alignment: ' + key)
                abi_hashes[name] = sha
            hashes[abi] = abi_hashes
            if ABIS[abi][0] == 64:
                expected_capability[abi] = abi_hashes
        if expected_capability:
            expected = {'version': 1, 'maxPageSize': 16384, 'abis': expected_capability}
            if capability != expected:
                raise ValueError('APK capability does not match its exact three-library ABI sets')
        elif capability is not None:
            raise ValueError('32-bit-only APK must not carry a 16 KB runtime capability')
    noncompatible = [row['path'] for row in rows if row['bits'] == 64
                     and not (row['compatible_16kb'] and row['zip_16kb_aligned'])]
    has_64bit = any(row['bits'] == 64 for row in rows)
    return {'apk': Path(path).name, 'sha256': digest(Path(path).read_bytes()),
            'node_packaging_verified': True, 'node_abis': sorted(node_abis),
            'node_library_sha256': hashes, 'capability': capability,
            'has_64bit_libraries': has_64bit,
            'whole_apk_16kb': has_64bit and not noncompatible,
            'other_native_blockers': noncompatible, 'all_native_elf': rows,
            'scope': 'Packaging evidence only. No device execution, codec or playback acceptance.'}


def main(args):
    expected = args.runtime_sha256_file.read_text(encoding='utf-8').split()[0]
    runtime = verify_bundle(args.runtime_archive, expected)
    build = json.loads(args.runtime_build_evidence.read_text(encoding='utf-8'))
    if (build.get('runtimeArchiveSha256') != expected or build.get('source') != runtime['source']
            or build.get('commit') != runtime['commit'] or build.get('ndk') != runtime['ndk']
            or build.get('api') != runtime['api'] or build.get('buildRuns') != runtime['buildRuns']
            or build.get('bridgeSourceSha256') != digest((ROOT / 'shared/catpaw/node_bridge.c').read_bytes())):
        raise ValueError('Native build evidence does not match this candidate and bridge source')
    outputs = json.loads(args.build_report.read_text(encoding='utf-8'))
    reports = []
    for field in ('apk', 'mobile_apk'):
        name = outputs[field]
        if not isinstance(name, str) or Path(name).name != name or not name.endswith('.apk'):
            raise ValueError('Invalid APK filename in build report')
        path = args.dist / name
        expected_apk = outputs['sha256' if field == 'apk' else 'mobile_sha256']
        if digest(path.read_bytes()) != expected_apk:
            raise ValueError('APK changed after the Android build: ' + name)
        report = verify_apk(path, runtime, build)
        expected_abis = {'armeabi-v7a'} if field == 'apk' else {'armeabi-v7a', 'arm64-v8a'}
        if set(report['node_abis']) != expected_abis:
            raise ValueError('Candidate lost a required Android ABI: ' + name)
        reports.append(report)
    result = {'runtime_archive': args.runtime_archive.name, 'runtime_sha256': expected,
              'source_commit': runtime['commit'], 'build_runs': runtime['buildRuns'],
              'node_packaging_verified': True, 'apks': reports,
              'device_install_tested': False, 'device_playback_tested': False}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + '\n', encoding='utf-8')
    print(json.dumps({report['apk']: {'node_packaging_verified': True,
                                    'whole_apk_16kb': report['whole_apk_16kb'],
                                    'other_native_blockers': report['other_native_blockers']}
                      for report in reports}, indent=2))
    if args.require_whole_apk and any(report['has_64bit_libraries'] and not report['whole_apk_16kb'] for report in reports):
        raise SystemExit('Other APK native dependencies still block complete 16 KB support; see report')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--runtime-archive', type=Path, required=True)
    parser.add_argument('--runtime-sha256-file', type=Path, required=True)
    parser.add_argument('--runtime-build-evidence', type=Path, default=ROOT / 'android/build/catpaw/runtime-build-evidence.json')
    parser.add_argument('--build-report', type=Path, default=ROOT / 'android/build/build-validation.json')
    parser.add_argument('--dist', type=Path, default=ROOT / 'dist')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--require-whole-apk', action='store_true')
    args = parser.parse_args()
    try:
        main(args)
    except Exception as error:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps({'node_packaging_verified': False, 'error': str(error),
                                          'device_install_tested': False, 'device_playback_tested': False}, indent=2) + '\n', encoding='utf-8')
        raise
