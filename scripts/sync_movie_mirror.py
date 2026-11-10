"""Sync published Marco Movie preview releases into an isolated static mirror directory.

Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only.
Only official release assets are accepted; all downloads are checked before writing the feed.
"""
import argparse
import hashlib
import html
import io
import json
import os
from pathlib import Path
import re
import struct
import urllib.request
import zipfile

REPO = 'Pilipala9919/MarcoMovie'
BASE = 'https://marcotv.wlj9919.top/movie/'
LIMIT = 25 * 1024 * 1024
# Desktop and Apple packages may exceed the 25 MiB per-file limit of the Cloudflare Pages host.
# Those are listed on the mirror page but downloaded from the official GitHub release asset.
PLATFORM_LIMIT = 300 * 1024 * 1024
# (file name pattern, button label, short note). Mirrored only when the release carries the
# package together with its official .sha256 file.
PLATFORMS = (
    ('MarcoMovie-{version}-mobile.apk', 'Android 手机 / 平板版 (64位)', 'Android 6.0+ · 原生 64 位 (arm64-v8a) 与 32 位双架构 · 竖屏触控 UI'),
    ('MarcoMovie-{version}-ios-unsigned.ipa', 'iPhone / iPad 版 (IPA)', 'iOS / iPadOS 14.0+ · 支持巨魔 (TrollStore) 直接安装或自签安装'),
    ('MarcoMovie-{version}-windows-setup.exe', 'Windows 安装版 (推荐)', 'Windows 10 / 11 · 64 位安装向导 · 内置运行库与快捷方式，支持后续一键更新'),
    ('MarcoMovie-{version}-windows-x64.zip', 'Windows 绿色版 (ZIP)', 'Windows 10 / 11 · 64 位便携压缩包 · 完整解压后运行 marco_movie.exe'),
    ('MarcoMovie-{version}-macos.zip', 'macOS 版', 'macOS · 解压后拖入“应用程序”；未公证，首次打开请右键选择“打开”'),
    ('MarcoMovie-{version}-lite.apk', 'Android 4.0+ 轻量版', 'Android 4.0+ (API 14+) · 适配老旧电视/盒子/老手机 · 独立包名可共存'),
)


def fetch(url, limit=LIMIT):
    headers = {'User-Agent': 'MarcoMovie-Mirror', 'Accept-Encoding': 'identity'}
    if url.startswith('https://api.github.com/') and os.environ.get('GITHUB_TOKEN'):
        headers['Authorization'] = 'Bearer ' + os.environ['GITHUB_TOKEN']
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as response:
        data = response.read(limit + 1)
    if len(data) > limit:
        raise ValueError('Download exceeds limit')
    return data


def apk_identity(apk):
    """Read literal package/version/minSdk from the actual binary APK manifest."""
    with zipfile.ZipFile(io.BytesIO(apk)) as z:
        entry = z.getinfo('AndroidManifest.xml')
        if entry.file_size > 1024 * 1024:
            raise ValueError('Manifest too large')
        data = z.read(entry)
    if struct.unpack_from('<H', data)[0] != 3:
        raise ValueError('Expected binary Android manifest')
    strings, values, editions, elements = [], {}, [], []
    offset = 8
    while offset < len(data):
        kind, header, size = struct.unpack_from('<HHI', data, offset)
        if size < header or header < 8 or offset + size > len(data):
            raise ValueError('Invalid XML chunk')
        if kind == 1:
            count, _, flags, start = struct.unpack_from('<IIII', data, offset + 8)
            if count > 65536 or header + count * 4 > size:
                raise ValueError('Invalid string pool')
            for i in range(count):
                pos = offset + start + struct.unpack_from('<I', data, offset + header + 4 * i)[0]
                if flags & 256:
                    def length8(p):
                        n = data[p]
                        return (((n & 127) << 8) | data[p + 1], p + 2) if n & 128 else (n, p + 1)
                    _, pos = length8(pos)
                    length, pos = length8(pos)
                    strings.append(data[pos:pos + length].decode('utf-8'))
                else:
                    length = struct.unpack_from('<H', data, pos)[0]; pos += 2
                    if length & 32768:
                        length = ((length & 32767) << 16) | struct.unpack_from('<H', data, pos)[0]; pos += 2
                    strings.append(data[pos:pos + length * 2].decode('utf-16le'))
        elif kind == 0x102:
            name = strings[struct.unpack_from('<I', data, offset + 20)[0]]
            start, stride, count = struct.unpack_from('<HHH', data, offset + 24)
            if stride < 20 or 16 + start + stride * count > size:
                raise ValueError('Invalid attributes')
            if name in ('manifest', 'uses-sdk', 'meta-data'):
                attributes = {}
                for i in range(count):
                    pos = offset + 16 + start + i * stride
                    _, key, raw, _, _, value_type, value = struct.unpack_from('<IIIHBBI', data, pos)
                    attributes[strings[key]] = strings[raw] if raw != 0xffffffff else strings[value] if value_type == 3 else value
                    values[(name, strings[key])] = attributes[strings[key]]
                if name == 'meta-data' and elements == ['manifest', 'application'] and attributes.get('name') == 'com.pilipala.marcomovie.EDITION':
                    editions.append(attributes.get('value'))
            elements.append(name)
        elif kind == 0x103:
            name = strings[struct.unpack_from('<I', data, offset + 20)[0]]
            if not elements or elements.pop() != name:
                raise ValueError('Unbalanced Android manifest')
        offset += size
    result = {'package': values[('manifest', 'package')], 'versionName': values[('manifest', 'versionName')],
              'versionCode': int(values[('manifest', 'versionCode')]), 'minSdk': int(values[('uses-sdk', 'minSdkVersion')])}
    if result['package'] != 'com.pilipala.marcomovie' or result['minSdk'] < 23 or result['versionCode'] <= 0:
        raise ValueError('Wrong application identity')
    if editions:
        if len(editions) != 1 or editions[0] not in ('tv', 'mobile'):
            raise ValueError('Invalid application edition')
        result['edition'] = editions[0]
    return result


def choose(releases):
    valid = [r for r in releases if not r.get('draft') and r.get('published_at')
             and re.fullmatch(r'v\d+\.\d+\.\d+-preview', r.get('tag_name', ''))]
    if not valid:
        raise ValueError('No published preview release')
    return max(valid, key=lambda r: tuple(map(int, r['tag_name'][1:-8].split('.'))))


def asset(release, name, output, limit=LIMIT):
    matches = [a for a in release['assets'] if a['name'] == name and a['state'] == 'uploaded']
    if len(matches) != 1:
        raise ValueError('Missing or duplicate asset: ' + name)
    info = matches[0]
    expected = f'https://github.com/{REPO}/releases/download/{release["tag_name"]}/{name}'
    if info['browser_download_url'] != expected or not 0 < info['size'] <= limit:
        raise ValueError('Unexpected asset URL or size')
    sha_url = expected + '.sha256'
    checksums = [a for a in release['assets'] if a['name'] == name + '.sha256' and a['state'] == 'uploaded' and a['browser_download_url'] == sha_url]
    if len(checksums) != 1:
        raise ValueError('Missing official checksum')
    checksum = fetch(sha_url, 4096).decode('ascii').strip().split()
    if len(checksum) != 2 or checksum[1].lstrip('*') != name or not re.fullmatch('[0-9a-f]{64}', checksum[0]):
        raise ValueError('Invalid checksum file')
    local = output / name
    body = local.read_bytes() if local.exists() else fetch(expected, limit)
    digest = hashlib.sha256(body).hexdigest()
    if len(body) != info['size'] or digest != checksum[0] or info.get('digest') not in (None, 'sha256:' + digest):
        raise ValueError('Release digest mismatch: ' + name)
    return body, digest


def platform_asset(release, name, output):
    """Return (href, size, sha256, body-or-None). Large packages stay on GitHub, never on Pages."""
    info = [a for a in release['assets'] if a['name'] == name and a['state'] == 'uploaded']
    if len(info) != 1:
        raise ValueError('Missing or duplicate asset: ' + name)
    size = info[0]['size']
    if size <= LIMIT:
        body, digest = asset(release, name, output)
        return name, size, digest, body
    expected = f'https://github.com/{REPO}/releases/download/{release["tag_name"]}/{name}'
    if info[0]['browser_download_url'] != expected or size > PLATFORM_LIMIT:
        raise ValueError('Unexpected asset URL or size')
    sha_url = expected + '.sha256'
    if len([a for a in release['assets'] if a['name'] == name + '.sha256' and a['state'] == 'uploaded'
            and a['browser_download_url'] == sha_url]) != 1:
        raise ValueError('Missing official checksum')
    checksum = fetch(sha_url, 4096).decode('ascii').strip().split()
    if len(checksum) != 2 or checksum[1].lstrip('*') != name or not re.fullmatch('[0-9a-f]{64}', checksum[0]):
        raise ValueError('Invalid checksum file')
    if info[0].get('digest') not in (None, 'sha256:' + checksum[0]):
        raise ValueError('Release digest mismatch: ' + name)
    return expected, size, checksum[0], None


def sync(output):
    release = choose(json.loads(fetch(f'https://api.github.com/repos/{REPO}/releases?per_page=100', 4 * 1024 * 1024)))
    version = release['tag_name'][1:-8]
    apk_name, source_name = f'MarcoMovie-{version}-preview.apk', f'MarcoMovie-{version}-source.zip'
    # Always download and validate the TV APK identity, even when Pages cannot
    # store its bytes. The channel then points at the verified official asset.
    apk, sha = asset(release, apk_name, output, limit=PLATFORM_LIMIT)
    apk_href = apk_name if len(apk) <= LIMIT else f'https://github.com/{REPO}/releases/download/{release["tag_name"]}/{apk_name}'
    source, source_sha = asset(release, source_name, output)
    platforms = []
    for pattern, label, note in PLATFORMS:
        name = pattern.format(version=version)
        if any(a['name'] == name for a in release['assets']):
            href, size, digest, body = platform_asset(release, name, output)
            platforms.append((name, label, note, href, size, digest, body))
    identity = apk_identity(apk)
    if identity['versionName'] != version:
        raise ValueError('APK version does not match release')
    with zipfile.ZipFile(io.BytesIO(source)) as archive:
        if archive.testzip() is not None:
            raise ValueError('Source ZIP failed CRC')
        license_text = archive.read(f'MarcoMovie-{version}/LICENSE')
        notice = archive.read(f'MarcoMovie-{version}/NOTICE')
    feed = dict(schema=1, versionCode=identity['versionCode'], versionName=version, minSdk=identity['minSdk'],
                size=len(apk), sha256=sha, url=apk_href if apk_href.startswith('https://') else BASE + apk_name,
                prerelease=bool(release.get('prerelease',True)), notes=(release.get('body') or '')[:8000])
    for name, _, _, href, size, digest, _ in platforms:
        if name == f'MarcoMovie-{version}-mobile.apk':
            feed['mobile'] = dict(size=size, sha256=digest, url=href if href.startswith('https://') else BASE + name)
        if name == f'MarcoMovie-{version}-windows-setup.exe':
            feed['windows'] = dict(size=size, sha256=digest, url=href if href.startswith('https://') else BASE + name)
    feed_path = output / 'updates/preview.json'
    feed_paths = [feed_path] + ([] if feed['prerelease'] else [output/'updates/stable.json'])
    for channel in feed_paths:
        if channel.exists():
            previous = json.loads(channel.read_text(encoding='utf-8'))
            if previous['versionCode'] > feed['versionCode']:
                raise ValueError('Refusing to roll the mirror back')
            if previous['versionCode'] == feed['versionCode'] and previous['sha256'] != sha:
                raise ValueError('Refusing to replace a published version')
    escaped = html.escape
    mobile_href = next((p[3] for p in platforms if p[0] == f'MarcoMovie-{version}-mobile.apk'), '')
    platform_card = ''
    if platforms:
        rows = ''.join(
            f'<div class="box"><h3>{escaped(label)}</h3><p class="muted">{escaped(note)} · {size/1024/1024:.1f} MB</p>'
            f'<a class="button" href="{escaped(href)}">下载{escaped(label)}</a>'
            f'<p class="muted"><a href="{escaped(href)}.sha256">校验文件</a> · SHA-256<br><code>{digest}</code></p></div>'
            for name, label, note, href, size, digest, body in platforms)
        platform_card = ('<div class="card"><h2>其他平台</h2><p class="muted">与 Android 版同一版本，由 GitHub Actions 云端构建；'
                         '尚未在每台设备上实机验证。</p><div class="grid">' + rows + '</div></div>\n')
    page = f'''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Marco Movie · 多端自适应播放器 · Pilipala</title><style>body{{margin:0;background:#101013;color:#f5f5f7;font:16px/1.8 system-ui,sans-serif}}main{{max-width:920px;margin:auto;padding:56px 24px}}h1{{font-size:48px;letter-spacing:-2px;margin:10px 0 8px}}h2{{margin-top:0}}h3{{margin:0 0 8px;color:#fff}}.muted{{color:#a1a1aa}}.card{{background:#232329;border:1px solid #37373f;border-radius:28px;padding:28px;margin:24px 0}}.grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:16px;margin:24px 0}}.box{{background:#1a1b22;border:1px solid #31333d;border-radius:22px;padding:22px}}a{{color:#9ac6ff}}.button{{display:inline-block;background:#f5f5f7;color:#111;padding:12px 24px;border-radius:18px;text-decoration:none;font-weight:600;margin:6px 12px 6px 0}}.button-ghost{{display:inline-block;border:1px solid #52525b;color:#f5f5f7;padding:11px 22px;border-radius:18px;text-decoration:none;margin:6px 12px 6px 0}}pre{{white-space:pre-wrap;overflow-wrap:anywhere;font:inherit;margin:0}}code{{overflow-wrap:anywhere}}</style>
<main><p class="muted">PILIPALA · ANDROID 电视 / 手机 / 平板 · WINDOWS · APPLE</p><h1>Marco Movie</h1><p>支持 Android 电视大屏遥控、手机与平板 64 位专属触控，以及 Windows / macOS / iOS (iOS 14.0+ 巨魔与自签) 多端独立适配的开源播放器。</p>
<div class="card"><h2>{version}</h2><p>Android 6.0+ 电视 / 盒子 / 投影仪大屏专享版 · ARM 32 位（内置 FFmpeg / AV1 / VP9 扩展）· {len(apk)/1024/1024:.1f} MB</p>
<a class="button" href="{escaped(apk_href)}">下载 Android 电视版</a>{f'<a class="button" href="{escaped(mobile_href)}">下载 Android 手机版 (64位)</a>' if mobile_href else ''}<a class="button-ghost" href="{source_name}">下载同版本源码</a>{'' if any(p[0].endswith(('.zip', '.ipa')) for p in platforms) else f'<a class="button-ghost" href="https://github.com/{REPO}/releases/tag/{release['tag_name']}">Windows / macOS / iOS 多平台下载</a>'}
<p><a href="{escaped(apk_href)}.sha256">校验文件</a> · <a href="https://github.com/{REPO}/releases/tag/{release['tag_name']}">GitHub 发布页</a> · <a href="https://github.com/{REPO}/blob/main/docs/USER_GUIDE.md">使用指南</a></p>
<p class="muted">SHA-256<br><code>{sha}</code></p></div>
{platform_card}<div class="grid">
<div class="box"><h3>📺 Android 电视端</h3><p class="muted">专为遥控器与 10 英尺大屏打造：5–8 列 2:3 海报墙、右侧悬浮图标 Dock、内置遥控全拼/首拼搜索、左固定海报 + 右独立滚动选集、小屏返回续播、局域网扫码导入配置。</p></div>
<div class="box"><h3>📱 Android 手机 / 平板端</h3><p class="muted">完全独立的移动端触控 UI：底部固定 5 栏导航（首页、搜索、直播、我的、设置；平板横屏自动变左侧导航栏），保留系统状态栏、去除遥控白框；首页直接支持剪贴板一键粘贴与原生输入法导入（无需扫码）；支持 50 集分组触控选集与全屏横屏手势播放（双击暂停、左右滑快进、左半屏亮度、右半屏音量、长按 2 倍速）。</p></div>
<div class="box"><h3>💻 Windows &amp; Apple 端</h3><p class="muted">提供跨平台客户端工程（覆盖 Windows x64、macOS、iPhone 与 iPad），自适应桌面侧边导航与移动端底部导航，内置硬件加速播放内核，支持与 Android 端互通备份文件。</p></div>
</div>
<div class="card"><h2>本次更新</h2><pre>{escaped(feed['notes'])}</pre></div>
<p>本产品仅为工具，不内置、不提供、不托管任何影视资源或配置地址。内容与配置请自行合法获取。</p>
<p>作者：Pilipala · <a href="LICENSE">GPL-3.0-only</a> · <a href="NOTICE">署名与许可</a> · <a href="/">Marco TV</a></p></main></html>'''
    files = {apk_name + '.sha256': (sha + '  ' + apk_name + '\n').encode(),
             source_name: source, source_name + '.sha256': (source_sha + '  ' + source_name + '\n').encode(),
             'LICENSE': license_text, 'NOTICE': notice, 'index.html': page.encode()}
    if len(apk) <= LIMIT:
        files[apk_name] = apk
    for name, _, _, _, _, digest, body in platforms:
        if body is None:
            continue
        files[name] = body
        files[name + '.sha256'] = (digest + '  ' + name + '\n').encode()
    # Versions are immutable and written before the channel pointer; Git/Pages publishes one complete snapshot.
    output.mkdir(parents=True, exist_ok=True)
    for name, data in files.items():
        target = output / name
        if target.exists() and target.suffix in ('.apk', '.zip', '.ipa', '.exe') and target.read_bytes() != data:
            raise ValueError('Immutable asset already differs')
        target.write_bytes(data)
    feed_path.parent.mkdir(exist_ok=True)
    for channel in feed_paths:
        temporary = channel.with_suffix('.tmp')
        temporary.write_text(json.dumps(feed, ensure_ascii=False, indent=2) + '\n', encoding='utf-8', newline='\n')
        temporary.replace(channel)
    print(f'Synced {version}: {len(apk)} bytes, SHA-256 {sha}; deployment must be verified separately.')
    return feed


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    sync(args.output)
