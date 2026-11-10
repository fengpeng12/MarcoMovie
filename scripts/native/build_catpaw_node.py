"""Rebuild pinned nodejs-mobile for Android; no prebuilt binary header patching."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from native_elf import inspect_elf

SOURCE_COMMIT = 'd9552e0e01ed5bdbe12a31d1ce6c0877a4f39580'
NDK_VERSION = '28.2.13676358'
ABIS = {'arm': ('armeabi-v7a', 'arm-linux-androideabi'),
        'arm64': ('arm64-v8a', 'aarch64-linux-android'),
        'x86_64': ('x86_64', 'x86_64-linux-android')}


def patch_libuv_android_barriers(source):
    """Use libuv's mutex/condition barrier on Android versions lacking pthread barriers.

    Bionic exposes the serial-thread macro and type even for API 23, while its
    barrier functions are only available from API 24. Both the public type and
    implementation must choose libuv's existing fallback with identical guards.
    """
    guard = '#if defined(_AIX) || \\\n    defined(__OpenBSD__) || \\\n    !defined(PTHREAD_BARRIER_SERIAL_THREAD)'
    replacement = guard.replace('    !defined(PTHREAD_BARRIER_SERIAL_THREAD)',
        '    (defined(__ANDROID__) && __ANDROID_API__ < 24) || \\\n    !defined(PTHREAD_BARRIER_SERIAL_THREAD)')
    changes = []
    for relative in ('deps/uv/include/uv/unix.h', 'deps/uv/src/unix/thread.c'):
        path = source / relative
        text = path.read_text()
        if text.count(guard) != 1:
            raise ValueError('Upstream libuv barrier patch context changed: ' + relative)
        changes.append((path, text.replace(guard, replacement)))
    for path, text in changes:
        path.write_text(text)


def build(source, ndk, output, arch):
    source, ndk, output = source.resolve(), ndk.resolve(), output.resolve()
    if subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=source, text=True).strip() != SOURCE_COMMIT:
        raise ValueError('Unexpected Node source revision')
    if NDK_VERSION not in (ndk/'source.properties').read_text():
        raise ValueError('Unexpected NDK revision')
    toolchain = ndk/'toolchains/llvm/prebuilt/linux-x86_64'
    # Keep target and host compilers independent. The upstream configurator
    # overwrites host CC/CXX with GCC; use the pinned NDK host compiler instead.
    config = source/'android_configure.py'
    text = config.read_text()
    for key, command in [('CC_host', 'gcc'), ('CXX_host', 'g++')]:
        old = f"os.environ['{key}'] = os.popen('command -v {command}').read().strip()"
        if text.count(old) != 1:
            raise ValueError('Upstream host compiler patch context changed')
        text = text.replace(old, f"os.environ.setdefault('{key}', os.popen('command -v {command}').read().strip())")
    # The application still supports API 23. Compile against that API so newer
    # Android imports fail at link time instead of failing on an older phone.
    old = 'if int(sys.argv[2]) < 24:'
    if text.count(old) != 1:
        raise ValueError('Upstream minimum API patch context changed')
    text = text.replace(old, 'if int(sys.argv[2]) < 23:')
    config.write_text(text)
    # c-ares ships a generated Android feature table for newer APIs. These
    # optional probes must match the actual sysroot; its existing fallback
    # paths handle interface enumeration and random bytes on older systems.
    cares = source/'deps/cares/config/android/ares_config.h'
    features = cares.read_text()
    for feature, api in [('HAVE_GETIFADDRS', 24), ('HAVE_GETRANDOM', 28)]:
        old = '#define '+feature+'\n'
        if features.count(old) != 1:
            raise ValueError('Upstream c-ares feature patch context changed: '+feature)
        features = features.replace(old, f'#if __ANDROID_API__ >= {api}\n{old}#endif\n')
    cares.write_text(features)
    patch_libuv_android_barriers(source)
    # V8's inspector used basic_string<uint16_t>, which libc++ 19 no longer
    # supports. Backport the upstream char16_t fix rather than changing the NDK
    # or weakening the 16 KB checks. The FreeBSD Node 18 backport preserves the
    # uint16_t protocol boundaries with explicit compatibility overloads.
    patch = Path(__file__).with_name('v8-char16-libcxx19.patch')
    patch_sha = hashlib.sha256(patch.read_bytes()).hexdigest()
    if patch_sha != 'e2b3e182bcade38f99e26ebb2bd9c3086d48dcd0b1fbec3fb59ea8f08ffca40c':
        raise ValueError('Unexpected V8 compatibility patch')
    subprocess.run(['git', 'apply', '--check', '-p0', str(patch)], cwd=source, check=True)
    subprocess.run(['git', 'apply', '-p0', str(patch)], cwd=source, check=True)
    env = dict(os.environ, CC_host=str(toolchain/'bin/clang'), CXX_host=str(toolchain/'bin/clang++'),
               LDFLAGS='-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384',
               PATH=str(toolchain/'bin')+os.pathsep+os.environ['PATH'])
    subprocess.run(['./android-configure', str(ndk), '23', arch], cwd=source, env=env, check=True)
    subprocess.run(['make', '-j2'], cwd=source, env=env, check=True)
    abi, triple = ABIS[arch]
    library = next((source/p for p in ('out/Release/lib.target/libnode.so', 'out/Release/obj.target/libnode.so') if (source/p).is_file()), None)
    if library is None:
        raise ValueError('Node shared library was not built')
    target = output/'bin'/abi
    target.mkdir(parents=True, exist_ok=True)
    records = []
    for name, path in [('libnode.so', library), ('libc++_shared.so', toolchain/'sysroot/usr/lib'/triple/'libc++_shared.so')]:
        data = path.read_bytes()
        evidence = inspect_elf(data)
        # Android's large-page ABI applies only to 64-bit processes. The pinned
        # NDK's ARMv7 C++ runtime uses 4 KB pages and must retain its original bytes.
        if evidence['bits'] == 64 and not evidence['compatible_16kb']:
            raise ValueError('Built library is not 16 KB aligned: '+name)
        shutil.copy2(path, target/name)
        records.append({'name': name, 'sha256': hashlib.sha256(data).hexdigest(), **evidence})
    shutil.copy2(source/'LICENSE', output/'LICENSE')
    (output/f'provenance-{abi}.json').write_text(json.dumps({'source': 'https://github.com/nodejs-mobile/nodejs-mobile', 'commit': SOURCE_COMMIT, 'ndk': NDK_VERSION, 'api': 23, 'abi': abi, 'v8_char16_patch_sha256': patch_sha, 'libuv_android_pre24_barrier_fallback': True, 'libraries': records}, indent=2)+'\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--ndk', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--arch', choices=ABIS, required=True)
    args = parser.parse_args()
    build(args.source, args.ndk, args.output, args.arch)
