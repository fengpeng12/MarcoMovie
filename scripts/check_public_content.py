"""Check tracked/public source scope. This is a guardrail, not a secret scanner guarantee."""
from pathlib import Path
import re, subprocess, sys, hashlib, json

ROOT=Path(__file__).resolve().parents[1]
EXCLUDED={'.git','private','tools','dist','build','__pycache__','lib','classes'}
ALLOWED_HOSTS={'nodejs.org','api.github.com','release-assets.githubusercontent.com','marcotv.wlj9919.top','github.com','raw.githubusercontent.com','chromium.googlesource.com','android.googlesource.com','ffmpeg.org','trac.ffmpeg.org','dl.google.com','repo.maven.apache.org',
 'dl.frostwire.com','schemas.android.com','maven.apache.org','www.apache.org','www.boost.org',
 'www.unicode.org','unicode.org','opensource.org','jsoup.org','developer.mozilla.org',
 'perfectionkills.com','www.engr.mun.ca','android.git.kernel.org','fsf.org','www.gnu.org',
 'gnu.org','www.fsf.org','barcode4j.sourceforge.net','maven.aliyun.com','10.0.2.2','127.0.0.1','localhost','…','x',
 'm.douban.com','movie.douban.com','www.douban.com','img1.doubanio.com','img2.doubanio.com','img3.doubanio.com','cn.bing.com','tse1-mm.cn.bing.net','tse2-mm.cn.bing.net','tse3-mm.cn.bing.net','tse4-mm.cn.bing.net','www.tuxiaobei.com','m.youlai.cn','www.huya.com','mp.huya.com','m.douyu.com','api.bilibili.com','www.bilibili.com','search.bilibili.com','i0.hdslb.com','i1.hdslb.com','i2.hdslb.com',
 'pub.dev','www.6huo.com','api.bgm.tv','bgm.tv','lain.bgm.tv','baike.baidu.com','baike.so.com','v.qq.com','weibo.com',
 'cj.ffzyapi.com','tyyszy.com','bfzyapi.com','caiji.dyttzyapi.com','cj.lziapi.com','suoniapi.com','cj.rycjapi.com','hhzyapi.com','jszyapi.com','ikunzyapi.com','subocaiji.com','api.xinlangapi.com','www.hongniuzy2.com','caiji.moduapi.cc','360zy.com','zuidazy.me',
 'uop.quark.cn','pan.quark.cn','drive.quark.cn','drive-pc.quark.cn','drive-social-api.quark.cn','su.quark.cn','www.wogg.net','api.open.uc.cn','drive.uc.cn','su.uc.cn','passport.baidu.com','pan.baidu.com','wappass.baidu.com','passport.aliyundrive.com','www.aliyundrive.com','www.alipan.com','api.qrserver.com','www.mdzypic.com'}

# Permit documentation/example URLs only in the pinned upstream text files. A changed
# file goes through normal host review again. Private-value scanning remains active.
UPSTREAM_TEXT = json.loads((ROOT/'scripts/upstream-text-sha256.json').read_text(encoding='utf-8'))

# Exact synthetic authorities used to test URL authentication/IPv6 and a second
# loopback origin. Never allow their apparent username-as-host globally, and do
# not suppress any of the private-value checks above the URL review below.
TEST_AUTHORITIES = {
    'android/tests/DrpyChecks.java': {'new:login@127.0.0.1:', 'user:p%2Bss@', 'user:pass@', 'user:p%2Bss@source.test', 'user:pass@source.test'},
    'android/tests/GuardChecks.java': {'user:pass@media.test'},
    'flutter/test/drpy_cancellation_test.dart': {'user:pass@fixture.invalid'},
    'flutter/test/drpy_host_test.dart': {'user:secret@fixture.invalid'},
    'flutter/test/guard_bootstrap_host_test.dart': {'user:secret@fixture.invalid'},
    'flutter/test/subscription_redirect_test.dart': {'injected:secret@127.0.0.1:${origin.port}'},
    'android/tests/JsHttpChecks.java': {'new:secret@', 'us%40er:pa%2Bss@'},
    'flutter/test/python_host_compat_test.dart': {'user:pass@[::1]:8443'},
    'scripts/test_python_host.js': {'user:pass@[::1]:8443', '127.0.0.2', '127.0.0.2:'},
    'scripts/test_python_proxy.js': {'0.0.0.0:18345'},
    'scripts/test_t4_adapter.cjs': {'name:secret@127.0.0.1'},
    'scripts/test_t4_adapter.py': {'name:secret@example.invalid'},
    # The URL scan stops at the escaped dot in this reviewed loopback-only regex.
    'scripts/ios_cpython_transport/dart/fixture_http_transport.dart': {'127'},
    'scripts/ios_cpython_transport/dart/fixture_http_transport_test.dart': {'user@127.0.0.1:${server.port}'},
}

# Pinned interpreter dependencies and their primary documentation are reviewed
# only for the isolated native experiment, never for imported source defaults.
EXPERIMENT_HOSTS = {
    'scripts/ios_cpython/run_cpython_probe.py': {'files.pythonhosted.org'},
    'scripts/ios_cpython/pure-dependencies.lock.json': {'files.pythonhosted.org', 'pypi.org'},
    'scripts/ios_cpython/README.md': {'docs.python.org', 'briefcase.beeware.org'},
    'scripts/ios_cpython_transport/README.md': {'requests.readthedocs.io'},
}

def paths():
    if (ROOT/'.git').exists():
        result=subprocess.run(['git','ls-files','-z'],cwd=ROOT,check=True,capture_output=True)
        return [ROOT/p for p in result.stdout.decode('utf-8').split('\0') if p]
    return [p for p in ROOT.rglob('*') if p.is_file() and not any(
        part in EXCLUDED or part.endswith(('-classes','-compile')) for part in p.relative_to(ROOT).parts)
        and not p.name.endswith('results.txt')]

issues=[];files=paths()
for p in files:
    relative=p.relative_to(ROOT)
    # Exact reviewed, owner-supplied brand asset; all other videos remain excluded.
    if relative.as_posix()=='android/src/main/assets/branding/startup.mp4':
        if hashlib.sha256(p.read_bytes()).hexdigest()!='915d0b8e337d7980ef67f71864eed346407e0061602ca67ff3272502b5d8ec1b':issues.append(f'{relative}: unreviewed brand video')
        continue
    vendor_dart = relative.as_posix().startswith('flutter/packages/quickjs_engine/lib/') and p.suffix == '.dart'
    if any(part in (EXCLUDED - {'lib'} if vendor_dart else EXCLUDED) for part in relative.parts) or p.suffix in {'.apk','.aab','.p12','.jks','.keystore','.rar','.zip','.bin','.mp4'}:
        issues.append(f'{relative}: excluded file type/path');continue
    if p.suffix=='.png':continue
    data=p.read_bytes()
    try: text=data.decode('utf-8')
    except UnicodeDecodeError:issues.append(f'{relative}: unexpected binary');continue
    if p.name==Path(__file__).name:continue
    for pattern in [r'gh[pousr]_[A-Za-z0-9]{25,}',r'github_pat_[A-Za-z0-9_]{30,}',
                    r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
                    r'[A-Za-z]:[/\\](?:Users|TV)[/\\]',r'192\.168\.\d+\.\d+']:
        if re.search(pattern,text):issues.append(f'{relative}: private value pattern')
    if UPSTREAM_TEXT.get(relative.as_posix()) == hashlib.sha256(text.replace('\r\n','\n').encode('utf-8')).hexdigest():
        continue
    for authority in re.findall(r'https?://([^/\s\"\'<>\\)]+)',text):
        if authority in TEST_AUTHORITIES.get(relative.as_posix(), set()):continue
        host=authority.split(':')[0].lower().rstrip('.,;')
        if host in EXPERIMENT_HOSTS.get(relative.as_posix(), set()):continue
        if relative.as_posix() == 'flutter/pubspec.lock' and host in {'pub.dev','dart.dev'}:continue
        if relative.as_posix() == 'docs/python-json-compatibility.md' and host == 'docs.python.org':continue
        if host not in ALLOWED_HOSTS and not host.endswith(('.test','.example','.invalid')):
            issues.append(f'{relative}: review network domain {host}')

main=(ROOT/'android/src/main/java/com/pilipala/marcomovie/MainActivity.java').read_text(encoding='utf-8')
if not re.search(r'prefs\.getString\(\s*"origin"\s*,\s*""\s*\)',main):issues.append('First-run configuration address must be empty')
if '不内置、不提供、不托管' not in main:issues.append('Missing first-run tool declaration')
if issues:
    print('\n'.join(sorted(set(issues))));sys.exit(1)
print(f'PASS public file scope, address default, declaration and network/secret patterns ({len(files)} files)')
