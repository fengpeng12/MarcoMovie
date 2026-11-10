"""Build the small app-owned JNI bridge and package pinned Node libraries."""
from pathlib import Path
import hashlib
import json
import os
import platform
import shutil
import subprocess
from prepare_catpaw_runtime import ROOT, prepare, ASSETS
from native_elf import inspect_elf
from native.build_catpaw_node import NDK_VERSION


def runtime_capability(files, verified):
    """Opt in only exact 64-bit Node/bridge/C++ bytes from a verified runtime build."""
    if verified is None:
        return None
    abis = {}
    for abi, machine in [('arm64-v8a', 183), ('x86_64', 62)]:
        names = ['libnode.so', 'libmarco_node.so', 'libc++_shared.so']
        keys = ['lib/' + abi + '/' + name for name in names]
        if not any(key in files for key in keys):
            continue
        if not all(key in files for key in keys):
            raise ValueError('Incomplete 64-bit CatPaw runtime: ' + abi)
        hashes = {}
        for name, key in zip(names, keys):
            data = files[key]
            elf = inspect_elf(data)
            if elf['bits'] != 64 or elf['machine'] != machine or not elf['compatible_16kb']:
                raise ValueError('Invalid 16 KB CatPaw library: ' + key)
            digest = hashlib.sha256(data).hexdigest()
            if name != 'libmarco_node.so' and digest != verified['abis'][abi][name]['sha256']:
                raise ValueError('CatPaw runtime changed after verification: ' + key)
            hashes[name] = digest
        abis[abi] = hashes
    if not abis:
        return None
    return {'version': 1, 'maxPageSize': 16384, 'abis': abis}


def assets_for_package(source, native_files, destination):
    """Filter runtime evidence to the actual APK's complete native ABI sets."""
    source, destination = Path(source), Path(destination)
    shutil.copytree(source, destination, dirs_exist_ok=True)
    source_capability = source / 'catpaw/runtime-capabilities.json'
    output_capability = destination / 'catpaw/runtime-capabilities.json'
    abis = {}
    if source_capability.is_file():
        capability = json.loads(source_capability.read_text(encoding='utf-8'))
        for abi, hashes in capability['abis'].items():
            prefix = 'lib/' + abi + '/'
            if prefix + 'libnode.so' not in native_files:
                continue
            for name, expected in hashes.items():
                data = native_files.get(prefix + name)
                if data is None or hashlib.sha256(data).hexdigest() != expected:
                    raise ValueError('APK native bytes differ from runtime capability: ' + prefix + name)
            abis[abi] = hashes
        capability['abis'] = abis
        if abis:
            output_capability.write_text(json.dumps(capability, sort_keys=True, indent=2)+'\n', encoding='utf-8')
    if not abis and output_capability.is_file():
        output_capability.unlink()
    return destination


def toolchain():
    custom=os.environ.get('MARCOMOVIE_NDK_TOOLCHAIN')
    if custom:return Path(custom)
    ndk=os.environ.get('ANDROID_NDK_HOME') or os.environ.get('ANDROID_NDK_LATEST_HOME')
    if not ndk:
        sdk=os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT')
        choices=sorted((Path(sdk)/'ndk').glob('*')) if sdk else []
        if choices:ndk=str(choices[-1])
    if not ndk:raise RuntimeError('CatPaw native build requires an Android NDK toolchain')
    host={'Windows':'windows-x86_64','Darwin':'darwin-x86_64','Linux':'linux-x86_64'}[platform.system()]
    return Path(ndk)/'toolchains/llvm/prebuilt'/host


def build():
    ndk=toolchain()
    clang=ndk/'bin'/('clang.exe' if os.name=='nt' else 'clang')
    unpack=ROOT/'tools/catpaw/android'
    verified = prepare('android',unpack)
    if verified is not None:
        properties = ndk.parents[3] / 'source.properties'
        revision = None
        if properties.is_file():
            for line in properties.read_text().splitlines():
                key, separator, value = line.partition('=')
                if separator and key.strip() == 'Pkg.Revision':
                    revision = value.strip()
        if revision != NDK_VERSION:
            raise ValueError('Verified Android runtime requires its pinned NDK ' + NDK_VERSION)
    files={}
    for abi,target,triple in [('armeabi-v7a','armv7a-linux-androideabi23','arm-linux-androideabi'),
                              ('arm64-v8a','aarch64-linux-android23','aarch64-linux-android')]:
        library=unpack/'bin'/abi/'libnode.so'
        out=ROOT/'android/build/catpaw'/abi/'libmarco_node.so'
        out.parent.mkdir(parents=True,exist_ok=True)
        subprocess.run(list(map(str,[clang,'--target='+target,'--sysroot='+str(ndk/'sysroot'),
            '-shared','-fPIC','-fno-stack-protector','-fno-builtin','-nostdlib','-O2',
            '-Wl,--no-undefined','-Wl,-z,max-page-size=16384','-Wl,-soname,libmarco_node.so',
            ROOT/'shared/catpaw/node_bridge.c',library,'-o',out])),check=True)
        # A source-built runtime must ship the matching C++ library from the same artifact.
        # Never replace it with whichever NDK happens to be installed on the build machine.
        cpp=(unpack/'bin'/abi/'libc++_shared.so' if verified is not None
             else ndk/'sysroot/usr/lib'/triple/'libc++_shared.so')
        for name,file in [('libnode.so',library),('libmarco_node.so',out),('libc++_shared.so',cpp)]:
            data = file.read_bytes()
            if verified is not None:
                elf = inspect_elf(data)
                reference = verified['abis'][abi]['libnode.so']
                if (elf['bits'], elf['machine']) != (reference['bits'], reference['machine']):
                    raise ValueError('CatPaw library architecture changed: ' + abi + '/' + name)
                if name != 'libmarco_node.so' and hashlib.sha256(data).hexdigest() != verified['abis'][abi][name]['sha256']:
                    raise ValueError('CatPaw runtime changed after extraction: ' + abi + '/' + name)
            files['lib/'+abi+'/'+name]=data
    assets=ROOT/'android/build/catpaw/assets/catpaw'
    assets.mkdir(parents=True,exist_ok=True)
    capability = runtime_capability(files, verified)
    capability_path = assets/'runtime-capabilities.json'
    if capability is None:
        if capability_path.is_file():
            capability_path.unlink()
        evidence = assets.parent.parent/'runtime-build-evidence.json'
        if evidence.is_file():
            evidence.unlink()
    else:
        capability_path.write_text(json.dumps(capability, sort_keys=True, indent=2)+'\n', encoding='utf-8')
        (assets.parent.parent/'runtime-build-evidence.json').write_text(json.dumps({
            'source': verified['source'], 'commit': verified['commit'], 'ndk': verified['ndk'],
            'api': verified['api'], 'buildRuns': verified['buildRuns'],
            'runtimeArchiveSha256': os.environ.get('MARCOMOVIE_ANDROID_RUNTIME_SHA256') or ASSETS['android'][1],
            'bridgeSourceSha256': hashlib.sha256((ROOT/'shared/catpaw/node_bridge.c').read_bytes()).hexdigest(),
            'libraries': {name: {'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data), **inspect_elf(data)}
                          for name, data in sorted(files.items())},
            'capability': capability,
            'scope': 'Exact bundled Node/JNI/C++ only; other APK native dependencies need separate validation.',
        }, sort_keys=True, indent=2)+'\n', encoding='utf-8')
    for name in ['host.cjs','fetch.cjs','fetch-LICENSE.txt','node-mobile-LICENSE.txt']:
        shutil.copy2(ROOT/'shared/catpaw'/name,assets/name)
    if verified is not None:
        shutil.copy2(unpack/'LICENSE', assets/'node-mobile-LICENSE.txt')
        # Ship the matching NDK runtime notices with the C++ binary as well.
        shutil.copy2(ndk.parents[3]/'NOTICE.toolchain', assets/'android-ndk-NOTICE.txt')
    listing = json.loads((ROOT/'shared/catpaw/drpy-assets.json').read_text(encoding='utf-8'))
    for entry in listing['files']:
        name = entry['name']
        if '/' in name or '\\' in name or not name.startswith('drpy-'):
            raise ValueError('Invalid DRPY asset path')
        source = ROOT/'shared/catpaw'/name
        if source.stat().st_size != entry['bytes'] or hashlib.sha256(source.read_bytes()).hexdigest() != entry['sha256']:
            raise ValueError('DRPY asset manifest is stale: '+name)
        shutil.copy2(source,assets/name)
    shutil.copy2(ROOT/'shared/catpaw/drpy-assets.json',assets/'drpy-assets.json')
    return files,assets.parent


if __name__=='__main__':build()
