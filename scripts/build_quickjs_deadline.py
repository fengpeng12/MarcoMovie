"""Build a small API23/16KB JNI deadline bridge against the pinned QuickJS ABI."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import subprocess
import urllib.request
import zipfile

from native_elf import inspect_elf

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'android/src/main/cpp/quickjs_deadline.c'
OUT = ROOT / 'android/build/quickjs-deadline'
WRAPPER_SHA = 'b1d0c550818f07e411b6e6f0eb21b28d83ed2e227d6129395be9e5a2167f4f0c'
JAVA_SHA = '2f795c28787ecf77b7081fdc9764ce75dc7f9d39402c56b09161625d3ce97de3'
NDK_VERSION = '28.2.13676358'
TARGETS = {'armeabi-v7a': ('armv7a-linux-androideabi23', 40),
           'arm64-v8a': ('aarch64-linux-android23', 183),
           'x86': ('i686-linux-android23', 3),
           'x86_64': ('x86_64-linux-android23', 62)}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def toolchain():
    explicit = os.environ.get('MARCOMOVIE_QUICKJS_TOOLCHAIN')
    if explicit:
        return Path(explicit).resolve()
    ndk = os.environ.get('ANDROID_NDK_HOME') or os.environ.get('ANDROID_NDK_ROOT')
    if not ndk:
        sdk = os.environ.get('ANDROID_SDK_ROOT') or os.environ.get('ANDROID_HOME')
        if sdk:
            ndk = str(Path(sdk) / 'ndk' / NDK_VERSION)
    if not ndk or not (Path(ndk) / 'source.properties').is_file():
        raise RuntimeError('Install NDK '+NDK_VERSION+' or set MARCOMOVIE_QUICKJS_TOOLCHAIN')
    if NDK_VERSION not in (Path(ndk) / 'source.properties').read_text():
        raise RuntimeError('QuickJS deadline build requires pinned NDK '+NDK_VERSION)
    host = 'windows-x86_64' if os.name == 'nt' else 'darwin-x86_64' if os.uname().sysname == 'Darwin' else 'linux-x86_64'
    return Path(ndk) / 'toolchains/llvm/prebuilt' / host


def build(output=OUT):
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    dependencies = json.loads((ROOT / 'android/dependencies.json').read_text(encoding='utf-8'))
    wrapper = next(x for x in dependencies if x['name'] == 'wrapper-android')
    java = next(x for x in dependencies if x['name'] == 'wrapper-java')
    if wrapper['version'] != '3.2.3' or wrapper['sha256'] != WRAPPER_SHA or java['version'] != '3.2.3' or java['sha256'] != JAVA_SHA:
        raise RuntimeError('QuickJS deadline JNI contract requires reviewed wrapper 3.2.3 hashes')
    archive = ROOT / 'tools/java-dependencies/wrapper-android-3.2.3.aar'
    if not archive.exists():
        archive.parent.mkdir(parents=True, exist_ok=True)
        archive.write_bytes(urllib.request.urlopen(wrapper['url'], timeout=60).read())
    if digest(archive.read_bytes()) != WRAPPER_SHA:
        raise RuntimeError('Pinned QuickJS wrapper archive hash mismatch')
    tc = toolchain()
    suffix = '.exe' if os.name == 'nt' else ''
    clang = tc / ('bin/clang'+suffix)
    nm = tc / ('bin/llvm-nm'+suffix)
    compiler = subprocess.check_output([clang, '--version'], text=True)
    if 'Android (13624864' not in compiler or 'clang version 19.0.1' not in compiler:
        raise RuntimeError('Unexpected QuickJS bridge compiler revision')
    files = {}
    report = {'version': 1, 'api': 23, 'ndk': NDK_VERSION, 'wrapper_version': '3.2.3',
              'wrapper_sha256': WRAPPER_SHA, 'java_sha256': JAVA_SHA,
              'source_sha256': digest(SOURCE.read_bytes()), 'compiler': compiler, 'libraries': {}}
    with zipfile.ZipFile(archive) as upstream:
        for abi, (target, machine) in TARGETS.items():
            folder = output / abi
            folder.mkdir(exist_ok=True)
            library = folder / 'libquickjs-android-wrapper.so'
            library.write_bytes(upstream.read('jni/'+abi+'/'+library.name))
            symbols = subprocess.check_output([nm, '-D', library], text=True)
            if not any(line.endswith(' T JS_SetInterruptHandler') for line in symbols.splitlines()):
                raise RuntimeError('Pinned wrapper does not export interrupt hook for '+abi)
            upstream_elf = inspect_elf(library.read_bytes())
            if upstream_elf['machine'] != machine or not upstream_elf['compatible_16kb']:
                raise RuntimeError('Pinned wrapper architecture/page alignment mismatch: '+abi)
            dest = folder / 'libmovie-quickjs-deadline.so'
            subprocess.run([clang, '--target='+target, '--sysroot='+str(tc/'sysroot'),
                            '-std=c11', '-D_POSIX_C_SOURCE=200809L', '-fPIC', '-shared', '-O2',
                            '-Wall', '-Wextra', '-Werror', '-Wl,--no-undefined',
                            '-Wl,-soname,'+dest.name, '-Wl,-z,max-page-size=16384',
                            '-Wl,-z,common-page-size=16384', str(SOURCE), '-L'+str(folder),
                            '-lquickjs-android-wrapper', '-o', str(dest)], check=True)
            data = dest.read_bytes()
            elf = inspect_elf(data)
            if elf['machine'] != machine or not elf['compatible_16kb']:
                raise RuntimeError('Deadline bridge architecture/page alignment mismatch: '+abi)
            key = 'lib/'+abi+'/'+dest.name
            files[key] = data
            report['libraries'][key] = {'sha256': digest(data), 'bytes': len(data), 'elf': elf,
                                        'wrapper_sha256': digest(library.read_bytes())}
    (output/'manifest.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    return files


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=OUT)
    args = parser.parse_args()
    print('Built', len(build(args.output)), 'API23/16KB QuickJS deadline libraries')
