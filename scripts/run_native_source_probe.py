"""Execute real Node JNI checks on a disposable x86_64 emulator; no private networks."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'android/build/native-source-probe'
ADB = os.environ.get('ADB', 'adb')


def adb(*args, check=True, timeout=300):
    return subprocess.run([ADB, *args], check=check, timeout=timeout, capture_output=True,
                          text=True, encoding='utf-8', errors='replace').stdout


def emulator_page_size():
    reported = adb('shell', 'getconf', 'PAGESIZE', check=False).strip()
    if reported.isdigit():
        return int(reported)
    # Android 6 has no getconf binary. This fallback is only for the regular
    # API 23 image; the instrumentation still checks Os.sysconf independently.
    sdk = adb('shell', 'getprop', 'ro.build.version.sdk').strip()
    if sdk != '23':
        raise RuntimeError('getconf did not report the emulator page size')
    smaps = adb('shell', 'cat', '/proc/self/smaps')
    sizes = {int(value) * 1024 for value in re.findall(r'^KernelPageSize:\s+(\d+)\s+kB\s*$', smaps, re.MULTILINE)}
    if sizes != {4096}:
        raise RuntimeError('API 23 kernel page size is missing or unexpected')
    return sizes.pop()


def main(page_size):
    if adb('shell', 'getprop', 'ro.kernel.qemu').strip() != '1':
        raise RuntimeError('This destructive probe is restricted to a disposable emulator')
    if adb('shell', 'getprop', 'ro.product.cpu.abi').strip() != 'x86_64':
        raise RuntimeError('The verified Node probe includes only x86_64 libraries')
    # API 23 may report boot_completed while CryptKeeper is still encrypting.
    import run_api23_probes as boot
    boot.OUT = OUT
    boot.wait_for_full_boot()
    actual = emulator_page_size()
    if actual != page_size:
        raise RuntimeError('Wrong emulator page size: expected ' + str(page_size) + ', got ' + str(actual))
    (OUT / 'device.txt').write_text(adb('shell', 'getprop') + '\nPAGESIZE=' + str(actual) + '\n', encoding='utf-8')
    # Keep native extraction on the ordinary filesystem. Incremental install
    # adds a separate filesystem/mapping path to the experimental 16 KB image.
    adb('install', '--no-incremental', '-r', str(OUT / 'fixture.apk'))
    adb('install', '--no-incremental', '-r', str(OUT / 'probe.apk'))
    adb('shell', 'pm', 'clear', 'com.pilipala.marcomovie')
    adb('shell', 'svc', 'wifi', 'disable')
    adb('shell', 'svc', 'data', 'disable')
    adb('logcat', '-c')
    log = ''
    try:
        log = adb('shell', 'am', 'instrument', '-w', '-e', 'page_size', str(page_size),
                  'com.pilipala.marcomovie.test/com.pilipala.marcomovie.NativeSourceProbe')
        print(log)
        match = re.search(r'INSTRUMENTATION_STATUS: result=(\{[^\r\n]+\})', log)
        result = json.loads(match[1]) if match else {'passed': False, 'error': 'No instrumentation result'}
        (OUT / 'results.json').write_text(json.dumps(result, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
        if result.get('passed') is not True:
            raise RuntimeError('Embedded Node source regression failed; see instrumentation and logcat')
    finally:
        (OUT / 'instrumentation.log').write_text(log, encoding='utf-8')
        (OUT / 'logcat.txt').write_text(adb('logcat', '-d', check=False), encoding='utf-8')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--page-size', choices=[4096, 16384], type=int, required=True)
    main(parser.parse_args().page_size)
