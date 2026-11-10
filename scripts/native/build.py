"""Build official Media3 software decoders on Linux, for Android API 23 ARMv7.

No application credentials or content are inputs. Every source is commit-pinned.
The resulting source archive accompanies distributed native binaries.
"""
from pathlib import Path
import hashlib, json, os, shutil, subprocess, tarfile, zipfile

ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / 'native-work'
OUT = ROOT / 'native-output'
SOURCES = json.loads(Path(__file__).with_name('sources.json').read_text())
NDK = Path(os.environ.get('ANDROID_NDK_HOME') or os.environ['ANDROID_HOME'] + '/ndk/26.1.10909125')
BIN = NDK / 'toolchains/llvm/prebuilt/linux-x86_64/bin'
CC = BIN / 'armv7a-linux-androideabi23-clang'
CXX = BIN / 'armv7a-linux-androideabi23-clang++'
JOBS = str(min(os.cpu_count() or 2, 4))

def run(*args, cwd=None, env=None):
    subprocess.run([str(x) for x in args], cwd=cwd or ROOT, env=env, check=True)

def checkout(name):
    target = WORK / name
    if not target.exists():
        target.mkdir(parents=True)
        run('git', 'init', target)
        run('git', 'fetch', '--depth=1', SOURCES[name]['url'], SOURCES[name]['commit'], cwd=target)
        run('git', 'checkout', '--detach', 'FETCH_HEAD', cwd=target)
    actual = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=target, text=True).strip()
    if actual != SOURCES[name]['commit']:
        raise RuntimeError('Unexpected source checkout: ' + name)
    return target

def cmake(jni, build):
    run('cmake', '-S', jni, '-B', build, '-G', 'Ninja',
        '-DCMAKE_TOOLCHAIN_FILE=' + str(NDK / 'build/cmake/android.toolchain.cmake'),
        '-DANDROID_ABI=armeabi-v7a', '-DANDROID_PLATFORM=android-23',
        '-DANDROID_STL=c++_static', '-DCMAKE_BUILD_TYPE=Release',
        '-DBUILD_TESTING=OFF', '-DLIBGAV1_ENABLE_TESTS=OFF', '-DLIBGAV1_ENABLE_EXAMPLES=OFF')
    run('cmake', '--build', build, '--parallel', JOBS)

def main():
    WORK.mkdir(exist_ok=True); OUT.mkdir(exist_ok=True)
    src = {name: checkout(name) for name in SOURCES}
    media = src['media'] / 'libraries'
    ff = src['ffmpeg']
    decoders = ['vorbis','opus','flac','alac','pcm_mulaw','pcm_alaw','mp3',
                'amrnb','amrwb','aac','ac3','eac3','dca','mlp','truehd']
    run(ff / 'configure', '--target-os=android', '--arch=arm', '--cpu=armv7-a',
        '--enable-cross-compile', '--cc=' + str(CC), '--cxx=' + str(CXX),
        '--ar=' + str(BIN / 'llvm-ar'), '--nm=' + str(BIN / 'llvm-nm'),
        '--ranlib=' + str(BIN / 'llvm-ranlib'), '--strip=' + str(BIN / 'llvm-strip'),
        '--enable-static', '--disable-shared', '--enable-pic', '--disable-doc',
        '--disable-programs', '--disable-everything', '--disable-avdevice',
        '--disable-avformat', '--disable-swscale', '--disable-postproc',
        '--disable-avfilter', '--disable-symver', '--disable-v4l2-m2m',
        '--disable-vulkan', '--enable-swresample',
        '--extra-cflags=-march=armv7-a -mfloat-abi=softfp',
        '--libdir=' + str(ff / 'android-libs/armeabi-v7a'),
        *['--enable-decoder=' + d for d in decoders], cwd=ff)
    run('make', '-j' + JOBS, cwd=ff); run('make', 'install-libs', cwd=ff)
    ffjni = media / 'decoder_ffmpeg/src/main/jni'
    from patch_ffmpeg import patch
    patch(ffjni / 'ffmpeg_jni.cc')
    (ffjni / 'ffmpeg').symlink_to(ff, target_is_directory=True)
    cmake(ffjni, WORK / 'ffmpeg-jni-build')
    avjni = media / 'decoder_av1/src/main/jni'
    (avjni / 'cpu_features').symlink_to(src['cpu_features'], target_is_directory=True)
    (avjni / 'libgav1').symlink_to(src['libgav1'], target_is_directory=True)
    abseil = src['libgav1'] / 'third_party/abseil-cpp'
    abseil.parent.mkdir(exist_ok=True)
    if abseil.exists() and not any(abseil.iterdir()): abseil.rmdir()
    abseil.symlink_to(src['abseil'], target_is_directory=True)
    cmake(avjni, WORK / 'gav1-jni-build')
    # Build libvpx directly with clang; the JNI library statically links it.
    vpx = src['libvpx']
    env = dict(os.environ, CC=str(CC), CXX=str(CXX), AR=str(BIN / 'llvm-ar'),
               LD=str(CXX), AS=str(CC)+' -c', STRIP=str(BIN / 'llvm-strip'))
    run(vpx / 'configure', '--target=armv7-linux-gcc', '--disable-examples',
        '--disable-tools', '--disable-docs', '--disable-unit-tests',
        '--disable-vp8', '--disable-vp9-encoder', '--enable-vp9-highbitdepth',
        '--enable-pic', '--disable-shared', '--enable-static',
        '--disable-runtime-cpu-detect', '--enable-neon', cwd=vpx, env=env)
    run('make', '-j' + JOBS, cwd=vpx, env=env)
    cpu = NDK / 'sources/android/cpufeatures'
    run(CC, '-fPIC', '-O2', '-I' + str(cpu), '-c', cpu / 'cpu-features.c', '-o', WORK / 'cpu-features.o')
    run(CXX, '-shared', '-fPIC', '-O2', '-std=c++11', '-static-libstdc++',
        '-I' + str(vpx), '-I' + str(cpu), media / 'decoder_vp9/src/main/jni/vpx_jni.cc',
        WORK / 'cpu-features.o', vpx / 'libvpx.a', '-llog', '-landroid', '-lz', '-lm',
        '-Wl,-z,max-page-size=16384', '-o', WORK / 'libvpxV2JNI.so')
    libs = [WORK / 'ffmpeg-jni-build/libffmpegJNI.so',
            WORK / 'gav1-jni-build/libgav1JNI.so', WORK / 'libvpxV2JNI.so']
    provenance = {'sources': SOURCES, 'patches': ['patch_ffmpeg.py: TrueHD channel layout and flush'], 'ndk': '26.1.10909125', 'abi': 'armeabi-v7a',
                  'api': 23, 'audio_decoders': decoders, 'libraries': {}}
    with zipfile.ZipFile(OUT / 'marco-decoders-armv7.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
        for lib in libs:
            run(BIN / 'llvm-strip', '--strip-unneeded', lib)
            provenance['libraries'][lib.name] = hashlib.sha256(lib.read_bytes()).hexdigest()
            archive.write(lib, 'lib/armeabi-v7a/' + lib.name)
    (OUT / 'provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
    with tarfile.open(OUT / 'marco-decoder-sources.tar.xz', 'w:xz') as archive:
        for name, folder in src.items():
            target = WORK / (name + '-source.tar')
            args = ['git', 'archive', '--format=tar', '--output=' + str(target), 'HEAD']
            if name == 'media':
                args += ['libraries/decoder_ffmpeg','libraries/decoder_av1','libraries/decoder_vp9','LICENSE']
            run(*args, cwd=folder)
            archive.add(target, arcname=name + '-source.tar')
        archive.add(Path(__file__).parent, arcname='build')
        archive.add(OUT / 'provenance.json', arcname='provenance.json')
    for item in list(OUT.iterdir()):
        item.with_name(item.name + '.sha256').write_text(hashlib.sha256(item.read_bytes()).hexdigest() + '  ' + item.name + '\n')

if __name__ == '__main__': main()
