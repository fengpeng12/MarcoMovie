"""Offline mirror contract tests; no release upload or network access."""
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile
import sync_movie_mirror as m


class MirrorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.out = Path(self.temp.name) / 'movie'
        self.release = dict(tag_name='v0.4.12-preview', published_at='2026-11-01', prerelease=True,
                            draft=False, body='<script>example</script>', assets=[])
        self.data = {}
        source = io.BytesIO()
        with zipfile.ZipFile(source, 'w') as z:
            z.writestr('MarcoMovie-0.4.12/LICENSE', 'GPL-3.0-only')
            z.writestr('MarcoMovie-0.4.12/NOTICE', 'Pilipala')
        for name, body in [('MarcoMovie-0.4.12-preview.apk', b'apk fixture'), ('MarcoMovie-0.4.12-source.zip', source.getvalue())]:
            url = f'https://github.com/{m.REPO}/releases/download/v0.4.12-preview/{name}'
            sha = hashlib.sha256(body).hexdigest()
            for suffix, payload in [('', body), ('.sha256', (sha + '  ' + name).encode())]:
                self.release['assets'].append(dict(name=name+suffix, state='uploaded', browser_download_url=url+suffix,
                                                   size=len(payload), digest='sha256:'+hashlib.sha256(payload).hexdigest()))
                self.data[url+suffix] = payload
        self.identity = dict(package='com.pilipala.marcomovie', versionName='0.4.12', versionCode=25, minSdk=23)

    def fetch(self, url, limit=m.LIMIT):
        if url.startswith('https://api.github.com/'):
            return json.dumps([self.release]).encode()
        return self.data[url]

    def sync(self):
        with patch.object(m, 'fetch', self.fetch), patch.object(m, 'apk_identity', return_value=self.identity):
            return m.sync(self.out)

    def test_latest_numeric_preview_only(self):
        older = dict(self.release, tag_name='v0.4.9-preview')
        draft = dict(self.release, tag_name='v99.0.0-preview', draft=True)
        stable = dict(self.release, tag_name='v99.0.0', prerelease=False)
        self.assertEqual(m.choose([older, self.release, draft, stable])['tag_name'], 'v0.4.12-preview')
        with self.assertRaises(ValueError): m.choose([draft, stable])

    def test_complete_snapshot_and_repeat(self):
        unrelated = self.out.parent/'index.html'
        unrelated.write_text('Marco TV')
        feed = self.sync()
        self.assertEqual(feed['versionCode'], 25)
        self.assertEqual(feed['url'], m.BASE+'MarcoMovie-0.4.12-preview.apk')
        self.assertEqual(json.loads((self.out/'updates/preview.json').read_text(encoding='utf-8')), feed)
        self.assertIn('&lt;script&gt;', (self.out/'index.html').read_text(encoding='utf-8'))
        self.assertEqual(unrelated.read_text(), 'Marco TV')
        self.assertEqual(self.sync(), feed)

    def test_wrong_release_checksum_leaves_feed_unchanged(self):
        self.sync()
        before = (self.out/'updates/preview.json').read_bytes()
        name='MarcoMovie-0.4.12-preview.apk'
        (self.out/name).write_bytes(b'bad')
        with self.assertRaises(ValueError): self.sync()
        self.assertEqual((self.out/'updates/preview.json').read_bytes(), before)

    def test_wrong_asset_host(self):
        self.release['assets'][0]['browser_download_url']='https://example.invalid/file.apk'
        with self.assertRaises(ValueError): self.sync()
        self.assertFalse(self.out.exists())

    def test_wrong_apk_version(self):
        self.identity['versionName']='0.4.13'
        with self.assertRaises(ValueError): self.sync()
        self.assertFalse(self.out.exists())

    def test_reject_rollback(self):
        self.sync()
        self.identity['versionCode']=24
        with self.assertRaises(ValueError): self.sync()
        self.assertEqual(json.loads((self.out/'updates/preview.json').read_text(encoding='utf-8'))['versionCode'],25)

    def test_pages_size_limit(self):
        self.release['assets'][0]['size']=m.LIMIT+1
        with self.assertRaises(ValueError): self.sync()

    def test_invalid_manifest_rejected(self):
        source=io.BytesIO()
        with zipfile.ZipFile(source,'w') as z: z.writestr('AndroidManifest.xml',b'<manifest/>')
        with self.assertRaises(ValueError): m.apk_identity(source.getvalue())

    def test_large_tv_package_is_verified_and_linked_from_both_download_and_feed(self):
        name='MarcoMovie-0.4.12-preview.apk'
        self.release['assets']=[a for a in self.release['assets'] if a['name'] not in (name,name+'.sha256')]
        self.add_asset(name,b'large apk fixture' * (m.LIMIT//17+2))
        feed=self.sync()
        expected=f'https://github.com/{m.REPO}/releases/download/v0.4.12-preview/{name}'
        self.assertEqual(feed['url'],expected)
        self.assertFalse((self.out/name).exists())
        self.assertIn('href="'+expected+'"',(self.out/'index.html').read_text(encoding='utf8'))

    def test_official_release_updates_stable_channel(self):
        self.release['prerelease']=False
        feed=self.sync()
        self.assertFalse(feed['prerelease'])
        self.assertEqual(json.loads((self.out/'updates/stable.json').read_text(encoding='utf8')),feed)

    def test_large_mobile_hero_link_matches_update_feed(self):
        name='MarcoMovie-0.4.12-mobile.apk';self.add_asset(name,b'mobile fixture')
        next(a for a in self.release['assets'] if a['name']==name)['size']=m.LIMIT+1
        feed=self.sync()
        page=(self.out/'index.html').read_text(encoding='utf8')
        self.assertIn('href="'+feed['mobile']['url']+'">下载 Android 手机版',page)
        self.assertNotIn('href="'+name+'"',page)

    def add_asset(self, name, body, checksum=True):
        url = f'https://github.com/{m.REPO}/releases/download/v0.4.12-preview/{name}'
        sha = hashlib.sha256(body).hexdigest()
        items = [('', body)] + ([('.sha256', (sha + '  ' + name).encode())] if checksum else [])
        for suffix, payload in items:
            self.release['assets'].append(dict(name=name+suffix, state='uploaded', browser_download_url=url+suffix,
                                               size=len(payload), digest='sha256:'+hashlib.sha256(payload).hexdigest()))
            self.data[url+suffix] = payload

    def test_platform_packages_mirrored_when_published(self):
        self.add_asset('MarcoMovie-0.4.12-windows-x64.zip', b'windows fixture')
        self.add_asset('MarcoMovie-0.4.12-ios-unsigned.ipa', b'ios fixture')
        self.sync()
        self.assertEqual((self.out/'MarcoMovie-0.4.12-windows-x64.zip').read_bytes(), b'windows fixture')
        self.assertTrue((self.out/'MarcoMovie-0.4.12-ios-unsigned.ipa.sha256').exists())
        self.assertFalse((self.out/'MarcoMovie-0.4.12-macos.zip').exists())
        page = (self.out/'index.html').read_text(encoding='utf-8')
        self.assertIn('MarcoMovie-0.4.12-windows-x64.zip', page)
        self.assertIn('其他平台', page)

    def test_platform_package_without_checksum_rejected(self):
        self.add_asset('MarcoMovie-0.4.12-macos.zip', b'mac fixture', checksum=False)
        with self.assertRaises(ValueError): self.sync()
        self.assertFalse(self.out.exists())

    def test_large_platform_package_links_github_not_copied(self):
        self.add_asset('MarcoMovie-0.4.12-windows-x64.zip', b'windows fixture')
        big = [a for a in self.release['assets'] if a['name'] == 'MarcoMovie-0.4.12-windows-x64.zip'][0]
        big['size'] = m.LIMIT + 1
        self.sync()
        self.assertFalse((self.out/'MarcoMovie-0.4.12-windows-x64.zip').exists())
        page = (self.out/'index.html').read_text(encoding='utf-8')
        self.assertIn(f'https://github.com/{m.REPO}/releases/download/v0.4.12-preview/MarcoMovie-0.4.12-windows-x64.zip', page)

    def test_without_platform_packages_links_release_page(self):
        self.sync()
        self.assertIn('Windows / macOS / iOS 多平台下载', (self.out/'index.html').read_text(encoding='utf-8'))

if __name__ == '__main__': unittest.main()
