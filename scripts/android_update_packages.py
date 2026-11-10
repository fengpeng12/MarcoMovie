"""Plan edition-isolated Android feeds from verified release APKs. No writes here."""
import json
import re

from android_package_names import package_name
from sync_movie_mirror import BASE, LIMIT, REPO, apk_identity, asset


def plan(output, releases):
    files, versions, cards, cache = {}, {}, {}, {}
    for edition in ('mobile', 'tv'):
        platform = 'android-' + edition
        candidates = []
        for release in releases:
            match = re.fullmatch(re.escape(platform) + r'-v(\d+\.\d+\.\d+)(-preview)?', release.get('tag_name', ''))
            if not match or release.get('draft') or not release.get('published_at'):
                continue
            version = match[1]
            preview = bool(release.get('prerelease'))
            if bool(match[2]) != preview:
                raise ValueError('Android release tag/channel mismatch')
            candidates.append((tuple(map(int, version.split('.'))), not preview, version, release))
        for channel in ('stable', 'preview'):
            eligible = [c for c in candidates if channel == 'preview' or c[1]]
            if not eligible:
                continue
            _, stable, version, release = max(eligible, key=lambda c: (c[0], c[1]))
            tag = release['tag_name']
            if tag not in cache:
                notes = release.get('body')
                if not isinstance(notes, str) or not notes.strip() or len(notes) > 8000:
                    raise ValueError('Android release needs complete notes of at most 8000 characters')
                name = package_name(version, edition)
                body, digest = asset(release, name, output, limit=128 * 1024 * 1024)
                identity = apk_identity(body)
                if identity.get('edition') != edition or identity['versionName'] != version:
                    raise ValueError('APK edition/version does not match Android release')
                github = f'https://github.com/{REPO}/releases/download/{tag}/{name}'
                package = dict(size=len(body), sha256=digest, url=BASE + name if len(body) <= LIMIT else github)
                if len(body) <= LIMIT:
                    files[name] = body
                    files[name + '.sha256'] = (digest + '  ' + name + '\n').encode('ascii')
                cache[tag] = dict(schema=1, platform=platform, versionName=version,
                    versionCode=identity['versionCode'], minSdk=identity['minSdk'],
                    prerelease=not stable, notes=notes, githubUrl=github,
                    size=len(body), sha256=digest, url=BASE + name,
                    packages={name: package}, release_url=f'https://github.com/{REPO}/releases/tag/{tag}')
            feed = cache[tag]
            path = 'updates/' + platform + ('-preview' if channel == 'preview' else '') + '.json'
            previous_path = output / path
            if previous_path.exists():
                previous = json.loads(previous_path.read_text(encoding='utf-8'))
                if previous['versionCode'] > feed['versionCode']:
                    # A stable-only page of releases must not erase a newer saved preview.
                    if channel == 'preview':
                        continue
                    raise ValueError('Refusing Android platform rollback')
                if previous['versionCode'] == feed['versionCode'] and any(
                        previous.get(key) != feed.get(key) for key in ('versionName', 'sha256', 'size', 'platform')):
                    raise ValueError('Refusing to replace an Android version')
            files[path] = (json.dumps(feed, ensure_ascii=False, indent=2) + '\n').encode('utf-8')
            if channel == 'stable':
                versions[platform] = version
                cards[platform] = dict(size=feed['size'], sha256=feed['sha256'], url=feed['packages'][package_name(version, edition)]['url'])
    return files, versions, cards
