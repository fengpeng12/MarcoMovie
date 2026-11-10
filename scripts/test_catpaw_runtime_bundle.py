"""Synthetic ELF/ZIP fixtures verify packaging gates, not native runtime behavior."""
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import prepare_catpaw_runtime as prepare
import build_catpaw_android as android
from build_catpaw_android import runtime_capability
from native import catpaw_runtime_bundle as runtime
from native_elf import inspect_elf
from verify_android_runtime_package import verify_apk


def elf(bits, machine, align=16384):
    ident = b'\x7fELF' + bytes([bits // 32, 1, 1]) + bytes(9)
    if bits == 64:
        return (struct.pack('<16sHHIQQQIHHHHHH', ident, 3, machine, 1, 0, 64, 0, 0, 64, 56, 1, 0, 0, 0)
                + struct.pack('<IIQQQQQQ', 1, 5, 0, 0, 0, 120, 120, align))
    return (struct.pack('<16sHHIIIIIHHHHHH', ident, 3, machine, 1, 0, 52, 0, 0, 52, 32, 1, 0, 0, 0)
            + struct.pack('<IIIIIIII', 1, 0, 0, 0, 84, 84, 5, align))


class BundleChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='runtime-bundle-check-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.inputs = {}
        self.runs = {}
        for abi, (bits, machine) in runtime.ABIS.items():
            folder = self.root / abi
            (folder / 'bin' / abi).mkdir(parents=True)
            rows = []
            for name in runtime.LIBRARIES:
                data = elf(bits, machine, 4096 if bits == 32 else 16384)
                (folder / 'bin' / abi / name).write_bytes(data)
                rows.append({'name': name, 'sha256': runtime.sha256(data), **inspect_elf(data)})
            provenance = {'source': runtime.SOURCE, 'commit': runtime.SOURCE_COMMIT, 'ndk': runtime.NDK_VERSION,
                          'api': 23, 'abi': abi, 'v8_char16_patch_sha256': runtime.PATCH,
                          'libuv_android_pre24_barrier_fallback': True, 'libraries': rows}
            (folder / ('provenance-' + abi + '.json')).write_text(json.dumps(provenance), encoding='utf-8')
            (folder / 'LICENSE').write_text('Synthetic fixture, no upstream binary.', encoding='utf-8')
            self.inputs[abi] = folder
            self.runs[abi] = '123456789'

    def make(self, name='runtime.zip'):
        output = self.root / name
        with contextlib.redirect_stdout(io.StringIO()):
            runtime.bundle(self.inputs, self.runs, output)
        digest = runtime.sha256(output.read_bytes())
        return output, digest, runtime.verify_bundle(output, digest)

    def test_deterministic_complete_archive(self):
        first, digest, manifest = self.make()
        second, other, _ = self.make('second.zip')
        self.assertEqual(first.read_bytes(), second.read_bytes())
        self.assertEqual(digest, other)
        self.assertEqual(set(manifest['abis']), set(runtime.ABIS))
        self.assertFalse(manifest['abis']['armeabi-v7a']['libc++_shared.so']['compatible_16kb'])

    def test_pin_and_missing_abi_fail_closed(self):
        output, digest, _ = self.make()
        with self.assertRaises(ValueError):
            runtime.verify_bundle(output, '0' * 64)
        with self.assertRaises(ValueError):
            runtime.verify_bundle(output, '')
        self.inputs.pop('armeabi-v7a')
        with self.assertRaises(ValueError):
            runtime.bundle(self.inputs, self.runs, self.root / 'incomplete.zip')

    def test_exact_members_and_inner_hashes(self):
        output, _, _ = self.make()
        with zipfile.ZipFile(output) as archive:
            members = {name: archive.read(name) for name in archive.namelist()}
        for name, replacement in [('bin/arm64-v8a/libnode.so', b'tampered'), ('../escape', b'bad')]:
            target = self.root / 'changed.zip'
            with zipfile.ZipFile(target, 'w') as archive:
                for key, value in members.items():
                    archive.writestr(key, replacement if key == name else value)
                if name not in members:
                    archive.writestr(name, replacement)
            with self.assertRaises(ValueError):
                runtime.verify_bundle(target, runtime.sha256(target.read_bytes()))

    def test_wrong_provenance_and_architecture(self):
        abi = 'arm64-v8a'
        folder = self.inputs[abi]
        path = folder / ('provenance-' + abi + '.json')
        original = json.loads(path.read_text())
        for key, value in [('ndk', 'old'), ('api', 24), ('libuv_android_pre24_barrier_fallback', False)]:
            path.write_text(json.dumps(dict(original, **{key: value})))
            with self.assertRaises(ValueError):
                self.make()
        path.write_text(json.dumps(original))
        for machine, align in [(62, 16384), (183, 4096)]:
            changed = elf(64, machine, align)
            (folder / 'bin' / abi / 'libnode.so').write_bytes(changed)
            original['libraries'][0]['sha256'] = runtime.sha256(changed)
            path.write_text(json.dumps(original))
            with self.assertRaises(ValueError):
                self.make()

    def test_override_requires_independent_sha(self):
        output, digest, _ = self.make()
        with patch.dict(os.environ, {'MARCOMOVIE_ANDROID_RUNTIME_ARCHIVE': str(output)}, clear=True):
            with self.assertRaises(ValueError):
                prepare.archive('android')
        with patch.dict(os.environ, {'MARCOMOVIE_ANDROID_RUNTIME_ARCHIVE': str(output), 'MARCOMOVIE_ANDROID_RUNTIME_SHA256': digest}, clear=True):
            with contextlib.redirect_stdout(io.StringIO()):
                manifest = prepare.prepare('android', self.root / 'unpacked')
            self.assertEqual(manifest['commit'], runtime.SOURCE_COMMIT)
            self.assertTrue((self.root / 'unpacked/bin/armeabi-v7a/libc++_shared.so').is_file())

    def test_legacy_cache_cannot_retain_new_evidence(self):
        output = self.root / 'legacy.zip'
        with zipfile.ZipFile(output, 'w') as archive:
            archive.writestr('bin/arm64-v8a/libnode.so', elf(64, 183, 4096))
        destination = self.root / 'old'
        destination.mkdir()
        (destination / runtime.MANIFEST).write_text('stale')
        with patch.object(prepare, 'archive', return_value=output), contextlib.redirect_stdout(io.StringIO()):
            self.assertIsNone(prepare.prepare('android', destination))
        self.assertFalse((destination / runtime.MANIFEST).exists())

    def test_default_download_uses_pin_and_validates_manifest(self):
        output, digest, _ = self.make()
        with patch.dict(os.environ, {'MARCOMOVIE_RUNTIME_CACHE': str(self.root/'download')}, clear=True), \
                patch.dict(prepare.ASSETS, {'android': ('https://fixture.invalid/runtime.zip', digest)}), \
                patch.object(prepare.urllib.request, 'urlopen', return_value=io.BytesIO(output.read_bytes())) as download, \
                contextlib.redirect_stdout(io.StringIO()):
            manifest = prepare.prepare('android', self.root/'default')
            self.assertEqual(manifest['commit'], runtime.SOURCE_COMMIT)
            download.assert_called_once_with('https://fixture.invalid/runtime.zip', timeout=60)
            cached = self.root/'download/runtime.zip'
            cached.write_bytes(cached.read_bytes() + b'changed')
            with self.assertRaises(ValueError): prepare.archive('android')

    def test_capability_only_exact_three_64bit_libraries(self):
        _, _, manifest = self.make()
        files = {'lib/arm64-v8a/' + name: elf(64, 183) for name in ('libnode.so', 'libmarco_node.so', 'libc++_shared.so')}
        files.update({'lib/armeabi-v7a/' + name: elf(32, 40, 4096) for name in ('libnode.so', 'libmarco_node.so', 'libc++_shared.so')})
        capability = runtime_capability(files, manifest)
        self.assertEqual(set(capability['abis']), {'arm64-v8a'})
        self.assertEqual(len(capability['abis']['arm64-v8a']), 3)
        self.assertIsNone(runtime_capability(files, None))
        for key, value in [('lib/arm64-v8a/libnode.so', elf(64, 183) + b'changed'), ('lib/arm64-v8a/libmarco_node.so', elf(64, 183, 4096))]:
            with self.assertRaises(ValueError):
                runtime_capability(dict(files, **{key: value}), manifest)
        files.pop('lib/arm64-v8a/libmarco_node.so')
        with self.assertRaises(ValueError):
            runtime_capability(files, manifest)

    def test_build_uses_bundled_cpp_and_clears_legacy_capability(self):
        _, _, manifest = self.make()
        project = self.root / 'project'
        unpack = project / 'tools/catpaw/android'
        unpack.mkdir(parents=True)
        (unpack / 'LICENSE').write_text('verified artifact license')
        for abi, folder in self.inputs.items():
            (unpack / 'bin' / abi).mkdir(parents=True)
            for name in runtime.LIBRARIES:
                (unpack / 'bin' / abi / name).write_bytes((folder / 'bin' / abi / name).read_bytes())
        ndk_root = self.root / 'ndk'
        ndk = ndk_root / 'toolchains/llvm/prebuilt/linux-x86_64'
        ndk.mkdir(parents=True)
        properties = ndk_root / 'source.properties'
        properties.write_text('Pkg.Revision = ' + runtime.NDK_VERSION + '\n')
        (properties.parent/'NOTICE.toolchain').write_text('matching NDK runtime notices')
        for triple, bits, machine in [('arm-linux-androideabi', 32, 40), ('aarch64-linux-android', 64, 183)]:
            local = ndk / 'sysroot/usr/lib' / triple
            local.mkdir(parents=True)
            (local / 'libc++_shared.so').write_bytes(elf(bits, machine) + b'local NDK must not replace verified artifact')
        shared = project / 'shared/catpaw'
        shared.mkdir(parents=True)
        for name in ('host.cjs', 'fetch.cjs', 'fetch-LICENSE.txt', 'node-mobile-LICENSE.txt', 'node_bridge.c'):
            (shared / name).write_text('build fixture')
        (shared / 'drpy-assets.json').write_text('{"files":[]}')

        def compile_bridge(command, **kwargs):
            bits, machine = (64, 183) if '--target=aarch64-linux-android23' in command else (32, 40)
            Path(command[-1]).write_bytes(elf(bits, machine))

        with patch.object(android, 'ROOT', project), patch.object(android, 'toolchain', return_value=ndk), \
                patch.object(android, 'prepare', return_value=manifest) as load, \
                patch.object(android.subprocess, 'run', side_effect=compile_bridge) as compiler:
            files, assets = android.build()
            self.assertEqual(files['lib/arm64-v8a/libc++_shared.so'], elf(64, 183))
            self.assertEqual((assets / 'catpaw/node-mobile-LICENSE.txt').read_text(), 'verified artifact license')
            self.assertEqual((assets / 'catpaw/android-ndk-NOTICE.txt').read_text(), 'matching NDK runtime notices')
            capability = assets / 'catpaw/runtime-capabilities.json'
            evidence = project / 'android/build/catpaw/runtime-build-evidence.json'
            self.assertTrue(capability.is_file() and evidence.is_file())
            self.assertEqual(set(json.loads(capability.read_text())['abis']), {'arm64-v8a'})
            for revision in ('27.0.0', runtime.NDK_VERSION + '0'):
                properties.write_text('Pkg.Revision = ' + revision + '\n')
                before = compiler.call_count
                with self.assertRaises(ValueError):
                    android.build()
                self.assertEqual(compiler.call_count, before)
            load.return_value = None
            android.build()
            self.assertFalse(capability.exists())
            self.assertFalse(evidence.exists())

    def test_apk_capability_matches_packaged_abis_only(self):
        _, _, manifest = self.make()
        files = {'lib/arm64-v8a/' + name: elf(64, 183) for name in ('libnode.so', 'libmarco_node.so', 'libc++_shared.so')}
        source = self.root / 'source-assets'
        (source / 'catpaw').mkdir(parents=True)
        capability = runtime_capability(files, manifest)
        (source / 'catpaw/runtime-capabilities.json').write_text(json.dumps(capability))
        destination = self.root / 'apk-assets'
        android.assets_for_package(source, files, destination)
        output = destination / 'catpaw/runtime-capabilities.json'
        self.assertTrue(output.exists())
        android.assets_for_package(source, {'lib/armeabi-v7a/libnode.so': elf(32, 40, 4096)}, destination)
        self.assertFalse(output.exists())
        changed = dict(files, **{'lib/arm64-v8a/libmarco_node.so': elf(64, 183) + b'changed'})
        with self.assertRaises(ValueError):
            android.assets_for_package(source, changed, destination)

    def test_final_apk_verifier_checks_bytes_and_reports_other_libraries(self):
        _, _, manifest = self.make()
        files = {'lib/arm64-v8a/' + name: elf(64, 183) for name in ('libnode.so', 'libmarco_node.so', 'libc++_shared.so')}
        capability = runtime_capability(files, manifest)
        build = {'libraries': {name: {'sha256': runtime.sha256(data), 'bytes': len(data)} for name, data in files.items()}}
        path = self.root / 'candidate.apk'

        def apk(items, cap):
            with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as archive:
                for name, data in items.items():
                    archive.writestr(name, data)
                if cap is not None:
                    archive.writestr('assets/catpaw/runtime-capabilities.json', json.dumps(cap))

        apk(files, capability)
        self.assertTrue(verify_apk(path, manifest, build)['whole_apk_16kb'])
        with_other = dict(files, **{'lib/arm64-v8a/libother.so': elf(64, 183, 4096)})
        apk(with_other, capability)
        report = verify_apk(path, manifest, build)
        self.assertTrue(report['node_packaging_verified'])
        self.assertFalse(report['whole_apk_16kb'])
        self.assertEqual(report['other_native_blockers'], ['lib/arm64-v8a/libother.so'])
        apk(files, None)
        with self.assertRaises(ValueError):
            verify_apk(path, manifest, build)
        changed = dict(files, **{'lib/arm64-v8a/libc++_shared.so': elf(64, 183) + b'other NDK'})
        apk(changed, capability)
        with self.assertRaises(ValueError):
            verify_apk(path, manifest, build)
        arm = {'lib/armeabi-v7a/' + name: elf(32, 40, 4096) for name in ('libnode.so', 'libmarco_node.so', 'libc++_shared.so')}
        build = {'libraries': {name: {'sha256': runtime.sha256(data), 'bytes': len(data)} for name, data in arm.items()}}
        apk(arm, None)
        self.assertFalse(verify_apk(path, manifest, build)['has_64bit_libraries'])
        apk(arm, capability)
        with self.assertRaises(ValueError):
            verify_apk(path, manifest, build)


if __name__ == '__main__':
    unittest.main()
