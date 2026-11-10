"""Run only on a disposable emulator: installs and clears the test application."""
from pathlib import Path
import json
import os
import re
import subprocess
import argparse

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT/'android/build/mobile-player-probe'
ADB = os.environ.get('ADB', 'adb')


def adb(*args, check=True):
    return subprocess.run([ADB, *args], check=check, text=True, capture_output=True, timeout=240).stdout


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--navigation', choices=['gestural', 'threebutton'], default='gestural')
    args = parser.parse_args()
    if adb('shell', 'getprop', 'ro.kernel.qemu').strip() != '1':
        raise RuntimeError('This destructive fixture is restricted to an emulator')
    if adb('shell', 'getprop', 'ro.build.version.sdk').strip() != '36':
        raise RuntimeError('The phone layout regression requires API 36')
    navigation = 'com.android.internal.systemui.navbar.' + args.navigation
    adb('shell', 'cmd', 'overlay', 'enable-exclusive', '--category', navigation)
    overlays = adb('shell', 'cmd', 'overlay', 'list')
    if '[x] ' + navigation not in overlays:
        raise RuntimeError('Requested navigation overlay is not active')
    (OUT/'navigation.txt').write_text(overlays, encoding='utf-8')
    (OUT/'device.txt').write_text(adb('shell', 'getprop'), encoding='utf-8')
    adb('install', '-r', str(OUT/'layout-only.apk'))
    adb('install', '-r', str(OUT/'probe.apk'))
    adb('shell', 'pm', 'clear', 'com.pilipala.marcomovie')
    log = ''
    try:
        log = adb('shell', 'am', 'instrument', '-w', 'com.pilipala.marcomovie.test/com.pilipala.marcomovie.MobilePlayerProbe')
        print(log)
        match = re.search(r'INSTRUMENTATION_STATUS: result=(\{[^\r\n]+\})', log)
        result = json.loads(match[1]) if match else {'passed': False}
        (OUT/'results.json').write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
        required = {name + suffix for name in ('landscape','smaller_viewport','restored_viewport','reverse_landscape','portrait')
                    for suffix in ('_timeline_visible','_inside_safe_area','_heading_clear_of_controls','_touch_seek')}
        if result.get('passed') is not True or any(result.get(name) is not True for name in required):
            raise RuntimeError('Mobile player regression failed; see instrumentation.log and screenshots')
    finally:
        (OUT/'instrumentation.log').write_text(log, encoding='utf-8')
        (OUT/'logcat.txt').write_text(adb('logcat', '-d', check=False), encoding='utf-8')
        adb('pull', '/sdcard/Android/data/com.pilipala.marcomovie/files/', str(OUT/'screenshots'), check=False)
