"""Update independently released platform packages without rendering the site.

The existing page is the template: package URLs, sizes and checksums inside
matching download cards change, and the existing changelog section receives
version-specific release notes. CSS and legacy Android update channels stay intact.
"""
import argparse
import html
import json
from pathlib import Path
import re
from urllib.parse import urlsplit

from sync_movie_mirror import BASE, REPO, fetch, platform_asset
from platform_package_names import ALIASES as CLEAR_NAMES

SUFFIXES = {
    'ios': ('ios-unsigned.ipa',),
    'windows': ('windows-setup.exe', 'windows-x64.zip'),
    'macos': ('macos.zip',),
}
PLATFORM_LABELS = {
    'ios': 'iPhone / iPad', 'windows': 'Windows', 'macos': 'macOS',
    'android-tv': 'Android 电视', 'android-mobile': 'Android 手机 / 平板',
    'android-lite': 'Android Lite',
}
NOTE_SUFFIXES = {
    'android-tv.apk': 'android-tv', 'android-mobile.apk': 'android-mobile',
    'android-lite.apk': 'android-lite',
    'preview.apk': 'android-tv', 'mobile.apk': 'android-mobile',
    'lite.apk': 'android-lite', 'ios-unsigned.ipa': 'ios',
    'windows-setup.exe': 'windows', 'windows-x64.zip': 'windows',
    'macos.zip': 'macos',
}
NOTE_SUFFIXES.update({new: NOTE_SUFFIXES[old] for old, new in CLEAR_NAMES.items()})


def note_record(release):
    """Keep the published text verbatim; filenames/tags establish platform scope."""
    tag = release.get('tag_name', '')
    match = re.fullmatch(r'(?:(ios|windows|macos|android-tv|android-mobile|android-lite)-)?v(\d+\.\d+\.\d+)(-preview)?', tag)
    if not match or release.get('draft') or not release.get('published_at'):
        return None
    platform, version, _ = match.groups()
    names = {asset.get('name') for asset in release.get('assets', [])}
    platforms = [platform] if platform else list(dict.fromkeys(
        p for suffix, p in NOTE_SUFFIXES.items()
        if f'MarcoMovie-{version}-{suffix}' in names))
    if not platforms:
        return None
    notes = release.get('body') or ''
    if not isinstance(notes, str) or len(notes.encode('utf-8')) > 128 * 1024:
        raise ValueError('Invalid release notes: ' + tag)
    return dict(tag=tag, version=version, platforms=platforms,
                published_at=release['published_at'], prerelease=bool(release.get('prerelease')),
                target_commitish=release.get('target_commitish', ''), notes=notes,
                release_url=f'https://github.com/{REPO}/releases/tag/{tag}')


def release_history(output, releases):
    """Retain older entries even when they fall outside GitHub's newest page."""
    path = output / 'updates/history.json'
    records = json.loads(path.read_text(encoding='utf-8'))['releases'] if path.exists() else []
    by_tag = {item['tag']: item for item in records}
    for release in releases:
        item = note_record(release)
        if item is not None:
            by_tag[item['tag']] = item
    records = sorted(by_tag.values(), key=lambda item: (item['published_at'], item['tag']), reverse=True)
    files = {}
    for item in records:
        # Validate saved names too: an on-disk index never supplies output paths.
        if not re.fullmatch(r'(?:(?:ios|windows|macos|android-tv|android-mobile|android-lite)-)?v\d+\.\d+\.\d+(?:-preview)?', item['tag']):
            raise ValueError('Invalid archived release tag')
        text = item['notes'] if item['notes'].strip() else '该历史版本未提供更新说明。'
        files[f'updates/history/{item["tag"]}.md'] = (text + '\n').encode('utf-8')
    if records:
        files['updates/history.json'] = (json.dumps(dict(schema=1, releases=records), ensure_ascii=False, indent=2) + '\n').encode('utf-8')
    return records, files


def render_notes(notes):
    """A small escaped Markdown subset, with no raw HTML or executable URLs."""
    def inline(text):
        result, start = [], 0
        for token in re.finditer(r'`([^`\n]+)`|\*\*([^*\n]+)\*\*|\[([^\]\n]+)\]\(([^\s)]+)\)', text):
            result.append(html.escape(text[start:token.start()]))
            if token[1] is not None:
                result.append('<code>' + html.escape(token[1]) + '</code>')
            elif token[2] is not None:
                result.append('<strong>' + html.escape(token[2]) + '</strong>')
            else:
                try:
                    url = urlsplit(token[4])
                    safe = url.scheme == 'https' and url.hostname and not url.username and not url.password
                except ValueError:
                    safe = False
                if safe:
                    result.append('<a href="' + html.escape(token[4], quote=True) + '">' + html.escape(token[3]) + '</a>')
                else:
                    result.append(html.escape(token[0]))
            start = token.end()
        result.append(html.escape(text[start:]))
        return ''.join(result)

    blocks, paragraph, listing = [], [], None
    def flush():
        if paragraph:
            blocks.append('<p>' + '<br>'.join(map(inline, paragraph)) + '</p>')
            paragraph.clear()
    for raw in notes.splitlines() + ['']:
        line = raw.strip()
        heading = re.match(r'^#{1,6}\s+(.+)$', line)
        bullet = re.match(r'^(?:([-*])|\d+[.)])\s+(.+)$', line)
        if listing and not bullet:
            blocks.append('</' + listing + '>')
            listing = None
        if heading:
            flush()
            blocks.append('<h4>' + inline(heading[1]) + '</h4>')
        elif bullet:
            flush()
            kind = 'ul' if bullet[1] else 'ol'
            if listing != kind:
                if listing:
                    blocks.append('</' + listing + '>')
                start = re.match(r'^(\d+)', line) if kind == 'ol' else None
                blocks.append('<' + kind + (' start="' + start[1] + '"' if start and start[1] != '1' else '') + '>')
                listing = kind
            blocks.append('<li>' + inline(bullet[2]) + '</li>')
        elif line:
            paragraph.append(line)
        else:
            flush()
    return ''.join(blocks)


def patch_notes(page, records):
    if not records:
        return page
    sections = list(re.finditer(r'(<section\b[^>]*\bid="changelog"[^>]*>).*?</section>', page, re.S))
    if len(sections) != 1:
        raise ValueError('Expected exactly one existing changelog section')
    seen, current, archive = set(), [], []
    for item in records:
        platforms = item['platforms']
        latest = not item['prerelease'] and any(p not in seen for p in platforms)
        if not item['prerelease']:
            seen.update(platforms)
        platform_names = '、'.join(PLATFORM_LABELS[p] for p in platforms)
        label = (platform_names if len(platforms) < 3 else '多平台') + ' · ' + item['version']
        if item['prerelease']:
            label += ' · 预览版'
        escaped = html.escape
        note = item['notes'] if item['notes'].strip() else '该历史版本未提供更新说明。'
        entry = (
            '<details class="release-entry" data-platforms="' + ' '.join(platforms) + '"'
            + (' open' if latest and not current else '') + '><summary><span>' + escaped(label) + '</span>'
            '<span class="release-date">' + escaped(item['published_at'][:10]) + '</span></summary>'
            '<div class="release-content"><p class="release-platforms">适用：' + escaped(platform_names) + '</p><p class="release-links">'
            '<a href="' + escaped(item['release_url'], quote=True) + '">GitHub 发布记录</a> · '
            '<a href="updates/history/' + escaped(item['tag']) + '.md">完整更新说明</a></p>'
            + render_notes(note) + '</div></details>')
        (current if latest else archive).append(entry)
    section = sections[0]
    options = '<option value="all">全部平台</option>' + ''.join(
        '<option value="' + key + '">' + value + '</option>' for key, value in PLATFORM_LABELS.items())
    content = (section[1] + '<div class="section-heading"><div><p class="eyebrow">RELEASE NOTES</p><h2>版本更新</h2></div>'
               '<label class="filter-control" hidden>查看平台<select id="release-platform" aria-label="查看平台">' + options + '</select></label></div>'
               '<p class="sub">各端独立更新。展开对应版本，查看新增、修复和已知限制。</p>'
               + '<div class="current-releases">' + '\n'.join(current) + '</div>'
               + ('<details class="release-archive"><summary>历史版本 <span>' + str(len(archive)) + ' 个版本</span></summary>'
                  + '\n'.join(archive) + '</details>' if archive else '')
               + '<p id="release-empty" class="sub" hidden>该平台暂无发布记录。</p></section>')
    return page[:section.start()] + content + page[section.end():]


def version_key(version):
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('Invalid platform version')
    return tuple(map(int, version.split('.')))


def choose_platform(releases, platform):
    candidates = []
    for release in releases:
        match = re.fullmatch(re.escape(platform) + r'-v(\d+\.\d+\.\d+)', release.get('tag_name', ''))
        if match and not release.get('draft') and not release.get('prerelease') and release.get('published_at'):
            candidates.append((version_key(match[1]), release))
    return max(candidates, key=lambda item: item[0])[1] if candidates else None


def patch_card(page, suffix, package):
    aliases = {'android-tv.apk': 'preview.apk', 'android-mobile.apk': 'mobile.apk',
               'android-lite.apk': 'lite.apk'}
    aliases.update(CLEAR_NAMES)
    aliases.update({new: old for old, new in CLEAR_NAMES.items()})
    endings = [suffix] + ([aliases[suffix]] if suffix in aliases else [])
    name_pattern = r'MarcoMovie-\d+\.\d+\.\d+-(?:' + '|'.join(map(re.escape, endings)) + ')'
    cards = list(re.finditer(r'<div class="dl"(?:\s+[^>]*)?>.*?</div>', page, re.S))
    matches = [card for card in cards if re.search(name_pattern, card[0])]
    if len(matches) != 1:
        raise ValueError('Expected exactly one existing download card: ' + suffix)
    card = matches[0]
    replacement, links = re.subn(
        r'href="[^"<>]*' + name_pattern + r'(\.sha256)?"',
        lambda match: 'href="' + html.escape(package['url'], quote=True) + (match[1] or '') + '"',
        card[0])
    if links != 2:
        raise ValueError('Expected package and checksum links: ' + suffix)
    replacement, hashes = re.subn(r'(SHA-256：)[a-f0-9]{64}',
                                 lambda match: match[1] + package['sha256'], replacement)
    replacement, sizes = re.subn(r'\d+(?:\.\d+)? MB', f'{package["size"] / 1024 / 1024:.1f} MB', replacement)
    if hashes != 1 or sizes != 1:
        raise ValueError('Missing existing checksum or size: ' + suffix)
    # New layout exposes the package version; older templates remain supported.
    version = re.search(r'MarcoMovie-(\d+\.\d+\.\d+)-', package['url'])
    if version:
        replacement = re.sub(r'(<span class="package-version">)[^<]*(</span>)',
                             lambda m: m[1] + version[1] + m[2], replacement)
    return page[:card.start()] + replacement + page[card.end():]


def sync(output, releases=None):
    output = Path(output)
    original = (output / 'index.html').read_bytes()
    page = original.decode('utf-8')
    if releases is None:
        releases = json.loads(fetch(f'https://api.github.com/repos/{REPO}/releases?per_page=100', 4 * 1024 * 1024))
    from android_update_packages import plan as android_plan
    files, versions, android_cards = android_plan(output, releases)
    for platform, package in android_cards.items():
        page = patch_card(page, platform + '.apk', package)
    for platform, suffixes in SUFFIXES.items():
        release = choose_platform(releases, platform)
        if release is None:
            continue
        if not isinstance(release.get('body'), str) or not release['body'].strip():
            raise ValueError('Published platform release is missing update notes: ' + platform)
        version = release['tag_name'].split('-v', 1)[1]
        packages = {}
        names = {asset.get('name') for asset in release.get('assets', [])}
        for suffix in suffixes:
            preferred = CLEAR_NAMES.get(suffix, suffix)
            name = f'MarcoMovie-{version}-{preferred}'
            if name not in names:
                name = f'MarcoMovie-{version}-{suffix}'
            href, size, digest, body = platform_asset(release, name, output)
            package = dict(size=size, sha256=digest, url=href if href.startswith('https://') else BASE + name)
            packages[name] = package
            if body is not None:
                files[name] = body
                files[name + '.sha256'] = (digest + '  ' + name + '\n').encode('ascii')
            page = patch_card(page, suffix, package)
        feed = dict(schema=1, platform=platform, versionName=version, prerelease=False,
                    notes=release.get('body') or '', packages=packages,
                    release_url=f'https://github.com/{REPO}/releases/tag/{release["tag_name"]}')
        if platform == 'windows':
            # Installed 0.5.x clients require this exact legacy filename. The
            # public card can use the clearer name, but the update channel must
            # retain a verified, byte-identical alias until those clients migrate.
            legacy_name = f'MarcoMovie-{version}-windows-setup.exe'
            setup = next(package for name, package in packages.items()
                         if name.endswith(('-windows-x64-setup.exe', '-windows-setup.exe')))
            if legacy_name not in packages:
                if legacy_name not in names:
                    raise ValueError('Missing Windows updater compatibility alias')
                href, size, digest, body = platform_asset(release, legacy_name, output)
                if size != setup['size'] or digest != setup['sha256']:
                    raise ValueError('Windows updater alias differs from the public installer')
                packages[legacy_name] = dict(size=size, sha256=digest,
                                            url=href if href.startswith('https://') else BASE + legacy_name)
                if body is not None:
                    files[legacy_name] = body
                    files[legacy_name + '.sha256'] = (digest + '  ' + legacy_name + '\n').encode('ascii')
            feed['windows'] = packages[legacy_name]
        path = f'updates/{platform}.json'
        previous_path = output / path
        if previous_path.exists():
            previous = json.loads(previous_path.read_text(encoding='utf-8'))
            if version_key(previous['versionName']) > version_key(version):
                raise ValueError('Refusing platform rollback: ' + platform)
            if previous['versionName'] == version and previous['packages'] != packages:
                raise ValueError('Refusing to replace a published package: ' + platform)
        files[path] = (json.dumps(feed, ensure_ascii=False, indent=2) + '\n').encode('utf-8')
        versions[platform] = version
    history, note_files = release_history(output, releases)
    files.update(note_files)
    page = patch_notes(page, history)
    files['index.html'] = page.encode('utf-8')
    # Nothing is written until every release/card has validated. Git publishes
    # the complete snapshot; never rewrite a previously published binary.
    for name, body in files.items():
        target = output / name
        if target.exists() and target.suffix in ('.ipa', '.exe', '.zip', '.apk') and target.read_bytes() != body:
            raise ValueError('Immutable package differs: ' + name)
    for name, body in files.items():
        target = output / name
        if not target.exists() or target.read_bytes() != body:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(body)
    return versions


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(sync(args.output), ensure_ascii=False))
