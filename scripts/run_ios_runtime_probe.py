"""Run the production embedded Node engine/scripts inside an iOS simulator.

This app is a CI-only runtime fixture, not a published Marco Movie package.
It does not establish physical-device playback or Flutter UI compatibility.
"""
from pathlib import Path
import hashlib
import json
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'verification/ios-runtime'
APP = OUT / 'RuntimeProbe.app'
IDENTIFIER = 'com.pilipala.marcomovie.runtimeprobe'
PROGRESS = {}


def select_iphone(inventory, sdk_version, arch):
    """Use an installed runtime within the selected SDK's version family."""
    sdk = tuple(map(int, sdk_version.split('.')[:2]))
    candidates = []
    for runtime, devices in inventory.get('devices', {}).items():
        if '.iOS-' not in runtime:
            continue
        version = tuple(map(int, re.findall(r'\d+', runtime.split('.iOS-', 1)[1])))
        if version[:2] > sdk:
            continue
        for device in devices:
            if device.get('isAvailable') and device.get('name', '').startswith('iPhone'):
                candidates.append((version, runtime, device))
    if not candidates:
        raise RuntimeError('No available iPhone runtime for the selected simulator SDK ' + sdk_version)
    # Keep the established oldest-runtime Intel coverage; ARM exercises the newest
    # runtime supported by this toolchain instead of an unrelated installed Xcode.
    _, runtime, device = sorted(candidates, key=lambda item: item[0], reverse=arch == 'arm64')[0]
    return runtime, device


def run(*args, capture=False, timeout=180):
    PROGRESS['host_command'] = list(map(str, args))
    print('Running:', ' '.join(map(str,args)), flush=True)
    result = subprocess.run(list(map(str, args)), check=True, text=True,
                            timeout=timeout,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else ''


def main():
    if sys.platform != 'darwin':
        raise SystemExit('This validation requires a macOS host and iOS simulator.')
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT/'result.json').unlink(missing_ok=True)
    from prepare_catpaw_runtime import prepare
    runtime = OUT / 'node'
    prepare('ios', runtime)
    framework = runtime / 'NodeMobile.xcframework/ios-arm64_x86_64-simulator/NodeMobile.framework'
    (APP / 'Frameworks').mkdir(parents=True, exist_ok=True)
    shutil.copytree(framework, APP/'Frameworks/NodeMobile.framework', dirs_exist_ok=True)
    shutil.copytree(ROOT/'shared/catpaw', APP/'runtime', dirs_exist_ok=True)
    shutil.copyfile(ROOT/'scripts/ios_runtime/fixture.cjs', APP/'fixture.cjs')
    # Generate the synthetic CMS rule through the production T4 adapter. The
    # probe substitutes its authenticated local server address after startup.
    t4 = run('node', '-e',
        "const n=require(process.argv[1]).normalizeConfig({siteUrl:'http://fixture.invalid/api/cms',type:1});process.stdout.write(require(process.argv[2])(n));",
        ROOT/'shared/catpaw/drpy-t4-extractor.cjs', ROOT/'shared/catpaw/drpy-t4-adapter.cjs', capture=True)
    (APP/'t4-rule.js').write_text(t4, encoding='utf-8')
    fy = run('node', '-e',
        "const api='http://fixture.invalid/player/mplayer.php';const c={origin:'http://fixture.invalid',userAgent:'Fixture-UA',parsers:[api,api],parserMap:Object.fromEntries(['co','BBA','vwnet','YYNB','JD4K','JD2K','qiyi','bilibili','qq','youku'].map(k=>[k,api]))};process.stdout.write(require(process.argv[1])(c));",
        ROOT/'shared/catpaw/drpy-fy-adapter.cjs', capture=True)
    (APP/'fy-rule.js').write_text(fy, encoding='utf-8')
    shutil.copytree(ROOT/'android/src/main/assets/python-host', APP/'python-host', dirs_exist_ok=True)
    interop = ROOT/'android/src/main/assets/js-host/module-interop.js'
    catvod_assets = [ROOT/'android/src/main/assets/js-host'/name for name in ('catvod.mjs', 'crypto-js.js')]
    catvod_fixtures = [ROOT/'scripts/fixtures'/name for name in ('catvod_native_bridge.js', 'catvod_native_fixture.mjs')]
    (APP/'js-host').mkdir(parents=True, exist_ok=True)
    shutil.copyfile(interop, APP/'js-host/module-interop.js')
    for source in catvod_assets:
        shutil.copyfile(source, APP/'js-host'/source.name)
    for source in catvod_fixtures:
        shutil.copyfile(source, APP/source.name)
    for name in ('python_html_contract.py', 'python_html_expected.json',
                 'python_json_contract.py', 'python_json_expected.json',
                 'python_io_contract.py', 'python_io_expected.json',
                 'python_package_contract.py', 'python_package_expected.json',
                 'python_package_fixture.json'):
        shutil.copyfile(ROOT/'scripts/fixtures'/name, APP/name)
    info = {'CFBundleIdentifier': IDENTIFIER, 'CFBundleExecutable': 'RuntimeProbe',
            'CFBundleName': 'RuntimeProbe', 'CFBundlePackageType': 'APPL',
            'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0',
            'MinimumOSVersion': '14.0', 'UIDeviceFamily': [1, 2],
            'UILaunchScreen': {}, 'NSAppTransportSecurity': {'NSAllowsArbitraryLoads': True},
            'NSLocalNetworkUsageDescription': 'Local runtime regression fixture.'}
    (APP/'Info.plist').write_bytes(plistlib.dumps(info))
    sdk = run('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path', capture=True)
    sdk_version = run('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version', capture=True)
    PROGRESS['sdk_version'] = sdk_version
    arch = 'arm64' if platform.machine() == 'arm64' else 'x86_64'
    classes = ROOT/'flutter/packages/catpaw_runtime/ios/Classes'
    quickjs = ROOT/'flutter/packages/quickjs_engine/native/cxx'
    quickjs_ios = ROOT/'flutter/packages/quickjs_engine/ios/quickjs_engine/quickjs_engine_native/Sources/quickjs_engine_native'
    objects = []
    for name in ['quickjs.c', 'dtoa.c', 'libregexp.c', 'libunicode.c', 'libfastdev_quickjs_runtime.cpp']:
        obj=OUT/(name+'.o'); objects.append(obj)
        run('xcrun', '--sdk', 'iphonesimulator', 'clang++' if name.endswith('.cpp') else 'clang',
            '-target', arch+'-apple-ios14.0-simulator', '-isysroot', sdk, '-O2', '-DNDEBUG=1',
            '-DCONFIG_VERSION="ng-0.14.0"', '-I'+str(quickjs), '-I'+str(quickjs/'quickjs'),
            '-std=c++17' if name.endswith('.cpp') else '-std=c11', '-c', quickjs_ios/name, '-o', obj)
    run('xcrun', '--sdk', 'iphonesimulator', 'clang++', '-fobjc-arc', '-std=c++17',
        '-target', arch+'-apple-ios14.0-simulator', '-isysroot', sdk,
        '-I'+str(classes), '-I'+str(quickjs), '-F'+str(framework.parent), '-framework', 'NodeMobile',
        '-framework', 'Foundation', '-framework', 'UIKit',
        '-Wl,-rpath,@executable_path/Frameworks', ROOT/'scripts/ios_runtime/Probe.mm',
        classes/'CatpawRuntimeEngine.mm', ROOT/'scripts/ios_runtime/QuickJsProbe.mm',
        *objects, '-o', APP/'RuntimeProbe')
    run('codesign', '--force', '--sign', '-', APP/'Frameworks/NodeMobile.framework')
    run('codesign', '--force', '--sign', '-', APP)
    inventory = json.loads(run('xcrun', 'simctl', 'list', 'devices', 'available', '--json', capture=True))
    runtime_name, device = select_iphone(inventory, sdk_version, arch)
    PROGRESS.update(cpu=arch, simulator=device['name'], os_runtime=runtime_name)
    print('Simulator selection:', json.dumps(PROGRESS), flush=True)
    udid = device['udid']
    if device['state'] != 'Booted':
        run('xcrun', 'simctl', 'boot', udid)
    run('xcrun', 'simctl', 'bootstatus', udid, '-b', timeout=360)
    run('xcrun', 'simctl', 'install', udid, APP)
    container = Path(run('xcrun', 'simctl', 'get_app_container', udid, IDENTIFIER, 'data', capture=True))
    result_file = container/'Documents/result.json'
    result_file.unlink(missing_ok=True)
    run('xcrun', 'simctl', 'launch', '--terminate-running-process', udid, IDENTIFIER, timeout=180)
    deadline = time.monotonic()+180
    while not result_file.exists() and time.monotonic() < deadline:
        time.sleep(1)
    if not result_file.exists():
        raise RuntimeError('iOS runtime fixture produced no result; inspect simulator crash diagnostics')
    report = json.loads(result_file.read_text())
    report.update({'simulator': device['name'], 'os_runtime': runtime_name, 'cpu': arch,
                   'sdk_version': sdk_version,
                   'commit': run('git', '-C', ROOT, 'rev-parse', 'HEAD', capture=True),
                   'production_inputs': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in [classes/'CatpawRuntimeEngine.mm', *sorted((ROOT/'shared/catpaw').glob('*.cjs')),
                               ROOT/'shared/catpaw/drpy-core.js', ROOT/'shared/catpaw/drpy-assets.json', ROOT/'shared/catpaw/drpy-dependencies.js',
                               quickjs/'libfastdev_quickjs_runtime.cpp', quickjs/'quickjs/quickjs.c',
                               *sorted((ROOT/'android/src/main/assets/python-host').glob('*.js')), interop, *catvod_assets]},
                   'fixture_inputs': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in [*sorted((ROOT/'scripts/fixtures').glob('python_*')), *catvod_fixtures,
                               ROOT/'scripts/ios_runtime/QuickJsProbe.mm', ROOT/'scripts/ios_runtime/Probe.mm',
                               ROOT/'scripts/ios_runtime/LoopbackDiagnostics.h', ROOT/'scripts/run_ios_runtime_probe.py']}})
    (OUT/'result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n', encoding='utf8')
    print(json.dumps({'passed': report['passed'], 'checks': report['checks'],
                      'runtime': report['runtime'], 'failure': report['failure']}, ensure_ascii=False))
    package_cases = len(json.loads((ROOT/'scripts/fixtures/python_package_expected.json').read_text(encoding='utf-8')))
    expected_checks = 135 + package_cases
    names = [check.get('name') for check in report['checks']]
    if (not report['passed'] or len(names) != expected_checks
            or len(set(names)) != expected_checks
            or any(not isinstance(name, str) or not name for name in names)
            or any(check.get('passed') is not True for check in report['checks'])):
        raise RuntimeError('iOS runtime behavior verification failed')


if __name__ == '__main__':
    try:
        main()
    except Exception as failure:
        OUT.mkdir(parents=True, exist_ok=True)
        if not (OUT/'result.json').exists():
            (OUT/'result.json').write_text(json.dumps(dict(
                passed=False, checks=[], failure=type(failure).__name__ + ': ' + str(failure),
                scope='Host setup or simulator launch failed; application runtime was not accepted',
                **PROGRESS), indent=2) + '\n', encoding='utf-8')
        raise
