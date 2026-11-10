"""Run production source bytecode/JNI on a disposable Android 16 phone emulator."""
from pathlib import Path
import json
import os
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'android/build/phone-source-probe'
ADB = os.environ.get('ADB', 'adb')


def adb(*args, check=True):
    return subprocess.run([ADB, *args], check=check, text=True, encoding='utf-8',
                          errors='replace', capture_output=True, timeout=240).stdout


def main():
    if adb('shell', 'getprop', 'ro.kernel.qemu').strip() != '1':
        raise RuntimeError('This destructive fixture is restricted to an emulator')
    if adb('shell', 'getprop', 'ro.build.version.sdk').strip() != '36':
        raise RuntimeError('API 36 is required')
    if adb('shell', 'getprop', 'ro.product.cpu.abi').strip() != 'x86_64':
        raise RuntimeError('This isolated fixture requires x86_64 JNI')
    if 'android.software.leanback' in adb('shell', 'pm', 'list', 'features'):
        raise RuntimeError('Use a phone system image for phone source acceptance')
    scope = json.loads((OUT/'scope.json').read_text())
    if scope['fixture_edition'] != 'mobile' or scope['fixture_abi'] != 'x86_64':
        raise RuntimeError('Fixture is not the phone source build')
    (OUT/'device.txt').write_text(adb('shell', 'getprop'), encoding='utf-8')
    adb('install', '--no-incremental', '-r', str(OUT/'fixture.apk'))
    adb('install', '--no-incremental', '-r', str(OUT/'probe.apk'))
    adb('shell', 'pm', 'clear', 'com.pilipala.marcomovie')
    adb('logcat', '-c')
    log = ''
    try:
        log = adb('shell', 'am', 'instrument', '-w',
                  'com.pilipala.marcomovie.test/com.pilipala.marcomovie.SourceHostProbe')
        match = re.search(r'INSTRUMENTATION_STATUS: result=(\{[^\r\n]+\})', log)
        result = json.loads(match[1]) if match else {'passed': False}
        (OUT/'results.json').write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
        required = ('live_plugin_scheme_starts_host', 'live_plugin_native_catalogue_headers',
                    'live_plugin_remote_channel_headers', 'live_plugin_reload_preserves_instance',
                    'live_api_config_selects_isolated_engines', 'live_api_js_text', 'live_api_js_json',
                    'live_api_python_text', 'live_api_python_json', 'live_api_js_state_retained',
                    'live_api_jar_text', 'live_api_jar_json', 'live_api_jar_state_retained',
                    'live_api_missing_method_explicit', 't4_http_selected', 't4_category_base64url',
                    't4_player_opaque_id_and_flag', 't4_large_extension_post', 't4_invalid_response_explicit')
        if (result.get('passed') is not True or result.get('checks', 0) < 122
                or any(result.get(key) is not True for key in required)
                or any(value is False for value in result.values())):
            raise RuntimeError('Phone source regression failed; see results and native logs')
        print('Android 16 phone source checks passed:', result['checks'])
    finally:
        (OUT/'instrumentation.log').write_text(log, encoding='utf-8')
        (OUT/'logcat.txt').write_text(adb('logcat', '-d', check=False), encoding='utf-8')


if __name__ == '__main__':
    main()
