"""Run edition/update checks only on a disposable Android emulator."""
import json
import os
from pathlib import Path
import re
import subprocess

OUT = Path(__file__).resolve().parents[1] / 'android/build/update-isolation'
ADB = os.environ.get('ADB', 'adb')


def adb(*args, check=True):
    return subprocess.run([ADB, *args], capture_output=True, text=True, encoding='utf-8', errors='replace', check=check, timeout=180).stdout


def main():
    if adb('shell', 'getprop', 'ro.kernel.qemu').strip() != '1':
        raise RuntimeError('Only disposable emulators may run this installation test')
    (OUT / 'device.txt').write_text(adb('shell', 'getprop'), encoding='utf-8')
    reports = {}
    for edition in ('mobile', 'tv'):
        adb('uninstall', 'com.pilipala.marcomovie.test', check=False)
        adb('uninstall', 'com.pilipala.marcomovie', check=False)
        adb('install', '--no-incremental', str(OUT / (edition + '.apk')))
        adb('install', '--no-incremental', str(OUT / 'probe.apk'))
        raw = adb('shell', 'am', 'instrument', '-w', '-e', 'edition', edition,
                  'com.pilipala.marcomovie.test/com.pilipala.marcomovie.UpdateIsolationProbe')
        (OUT / (edition + '.log')).write_text(raw, encoding='utf-8')
        match = re.search(r'INSTRUMENTATION_STATUS: result=(\{[^\r\n]+\})', raw)
        if not match: raise RuntimeError('Missing instrumentation report: ' + edition)
        report = json.loads(match[1]); reports[edition] = report
        (OUT / 'results.json').write_text(json.dumps(reports, indent=2) + '\n', encoding='utf-8')
        if report.get('passed') is not True or report.get('checks') != 18 or report.get('edition') != edition:
            raise RuntimeError('Update isolation check failed: ' + json.dumps(report))
    print(json.dumps(reports, indent=2))


if __name__ == '__main__': main()
