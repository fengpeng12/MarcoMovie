import json
from pathlib import Path
import tempfile
import unittest
import hashlib
from unittest.mock import patch

import sync_platform_packages as m
from platform_package_names import clear_names, PLATFORMS, ALIASES


class PackageTests(unittest.TestCase):
    def test_clear_names_retain_exact_installers_and_matching_checksums(self):
        for platform, suffixes in PLATFORMS.items():
            for suffix in suffixes:
                source = self.out/('MarcoMovie-0.5.1-'+suffix)
                source.write_bytes(b'package fixture '+suffix.encode())
                source.with_name(source.name+'.sha256').write_text(hashlib.sha256(source.read_bytes()).hexdigest()+'  '+source.name+'\n')
            for target in clear_names(self.out, '0.5.1', platform):
                old = next(old for old, new in ALIASES.items() if target.name.endswith('-'+new))
                self.assertEqual(target.read_bytes(), (self.out/('MarcoMovie-0.5.1-'+old)).read_bytes())
                self.assertEqual(target.with_name(target.name+'.sha256').read_text().split(),
                                 [hashlib.sha256(target.read_bytes()).hexdigest(), target.name])
            clear_names(self.out, '0.5.1', platform)

    def test_named_package_validation_happens_before_any_copy(self):
        suffix = 'windows-setup.exe'
        source = self.out/('MarcoMovie-0.5.1-'+suffix)
        source.write_bytes(b'first package')
        source.with_name(source.name+'.sha256').write_text(hashlib.sha256(source.read_bytes()).hexdigest()+'  '+source.name+'\n')
        with self.assertRaises(FileNotFoundError): clear_names(self.out, '0.5.1', 'windows')
        self.assertFalse((self.out/'MarcoMovie-0.5.1-windows-x64-setup.exe').exists())
        source.with_name(source.name+'.sha256').write_text('a'*64+'  '+source.name+'\n')
        with self.assertRaises(ValueError): clear_names(self.out, '0.5.1', 'windows')
        with self.assertRaises(ValueError): clear_names(self.out, '../escape', 'ios')

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.out = Path(self.temp.name)
        cards = []
        for suffix in sum(m.SUFFIXES.values(), ()):
            name = 'MarcoMovie-0.5.0-' + suffix
            cards.append(f'<div class="dl"><h3>{suffix}</h3><p>Existing copy · 12.0 MB</p>'
                         f'<a href="{name}">下载</a><a href="{name}.sha256">校验文件</a>'
                         f'<code>SHA-256：{"a" * 64}</code></div>')
        self.page = ('<style>existing CSS</style><header>Existing layout</header>' + ''.join(cards)
                     + '<section class="block" id="changelog"><h2>Previous notes</h2></section>'
                     + '<footer>Existing footer</footer>')
        (self.out / 'index.html').write_text(self.page, encoding='utf-8')
        (self.out / 'updates').mkdir()
        (self.out / 'updates/stable.json').write_text('{"versionName":"0.5.0"}', encoding='utf-8')
        self.release = dict(tag_name='ios-v0.5.1', published_at='date', draft=False, prerelease=False, body='iOS fixes')

    def sync(self, releases=None):
        with patch.object(m, 'platform_asset', return_value=('https://github.com/Pilipala9919/MarcoMovie/releases/download/ios-v0.5.1/MarcoMovie-0.5.1-ios-unsigned.ipa', 123456, 'b' * 64, None)):
            return m.sync(self.out, [self.release] if releases is None else releases)

    def test_independent_package_preserves_style_other_cards_and_legacy_channel(self):
        self.assertEqual(self.sync(), {'ios': '0.5.1'})
        result = (self.out / 'index.html').read_text(encoding='utf-8')
        package = dict(url='https://github.com/Pilipala9919/MarcoMovie/releases/download/ios-v0.5.1/MarcoMovie-0.5.1-ios-unsigned.ipa', size=123456, sha256='b' * 64)
        expected = m.patch_notes(m.patch_card(self.page, 'ios-unsigned.ipa', package), [m.note_record(self.release)])
        self.assertEqual(result, expected)
        self.assertEqual((self.out / 'updates/stable.json').read_text(), '{"versionName":"0.5.0"}')
        self.assertFalse((self.out / 'updates/windows.json').exists())
        self.sync()
        self.assertEqual(result, (self.out / 'index.html').read_text(encoding='utf-8'))

    def test_clear_iphone_name_is_preferred_without_changing_card_layout(self):
        name = 'MarcoMovie-0.5.1-ios-iphone-ipad-unsigned.ipa'
        release = dict(self.release, assets=[{'name': name}, {'name': 'MarcoMovie-0.5.1-ios-unsigned.ipa'}])
        with patch.object(m, 'platform_asset', return_value=('https://fixture.invalid/' + name, 123456, 'b'*64, None)) as download:
            m.sync(self.out, [release])
            self.assertEqual(download.call_args.args[1], name)
        page = (self.out/'index.html').read_text(encoding='utf-8')
        self.assertIn('<style>existing CSS</style>', page)
        self.assertIn('<h3>ios-unsigned.ipa</h3>', page)
        self.assertIn('https://fixture.invalid/' + name, page)
        feed = json.loads((self.out/'updates/ios.json').read_text())
        self.assertEqual(set(feed['packages']), {name})
        # A later legacy-only release can still match the newly named card links.
        self.assertIn('legacy.ipa', m.patch_card(page, 'ios-unsigned.ipa',
                      dict(url='https://fixture.invalid/legacy.ipa', size=123, sha256='c'*64)))

    def test_named_windows_card_preserves_the_installed_client_updater(self):
        names = ['MarcoMovie-0.5.1-windows-x64-setup.exe', 'MarcoMovie-0.5.1-windows-x64-portable.zip',
                 'MarcoMovie-0.5.1-windows-setup.exe']
        release = dict(self.release, tag_name='windows-v0.5.1', assets=[{'name': name} for name in names])
        body = b'installer fixture'
        digest = hashlib.sha256(body).hexdigest()
        with patch.object(m, 'platform_asset', side_effect=lambda rel, name, output: (name, len(body), digest, body)):
            m.sync(self.out, [release])
        feed = json.loads((self.out/'updates/windows.json').read_text())
        self.assertEqual(feed['windows']['url'], m.BASE + names[2])
        self.assertEqual(feed['windows']['sha256'], digest)
        self.assertEqual(set(feed['packages']), set(names))
        page = (self.out/'index.html').read_text(encoding='utf-8')
        self.assertIn('href="' + m.BASE + names[0] + '"', page)
        self.assertNotIn('href="' + m.BASE + names[2] + '"', page)
        self.assertEqual((self.out/names[2]).read_bytes(), body)
        self.assertEqual((self.out/(names[2]+'.sha256')).read_text().split(), [digest, names[2]])

    def test_missing_or_different_windows_updater_alias_prevents_all_writes(self):
        names = ['MarcoMovie-0.5.1-windows-x64-setup.exe', 'MarcoMovie-0.5.1-windows-x64-portable.zip']
        legacy = 'MarcoMovie-0.5.1-windows-setup.exe'
        for mismatch in ('missing', 'size', 'digest'):
            listed = names if mismatch == 'missing' else names + [legacy]
            release = dict(self.release, tag_name='windows-v0.5.1', assets=[{'name': name} for name in listed])
            def download(rel, name, output):
                return (name, 124 if mismatch == 'size' and name == legacy else 123,
                        'c'*64 if mismatch == 'digest' and name == legacy else 'b'*64, b'fixture')
            with self.subTest(mismatch=mismatch), patch.object(m, 'platform_asset', side_effect=download):
                with self.assertRaisesRegex(ValueError, 'alias'):
                    m.sync(self.out, [release])
                self.assertEqual((self.out/'index.html').read_text(encoding='utf-8'), self.page)
                self.assertFalse((self.out/'updates/windows.json').exists())
                self.assertFalse((self.out/names[0]).exists())

    def test_drafts_unrecognized_and_no_release_leave_page_unchanged(self):
        self.sync([dict(self.release, draft=True), dict(self.release, tag_name='unrelated'), dict(self.release, tag_name='v0.5.0-preview')])
        self.assertEqual((self.out / 'index.html').read_text(encoding='utf-8'), self.page)
        self.assertFalse((self.out / 'updates/ios.json').exists())

    def test_preview_notes_are_labelled_without_publishing_preview_packages(self):
        self.sync([dict(self.release, prerelease=True)])
        self.assertFalse((self.out / 'updates/ios.json').exists())
        page = (self.out / 'index.html').read_text(encoding='utf-8')
        self.assertIn('0.5.1 · 预览版', page)
        self.assertNotIn(' open>', page)
        self.assertIn('MarcoMovie-0.5.0-ios-unsigned.ipa', page)

    def test_missing_card_fails_without_writes(self):
        (self.out / 'index.html').write_text('<style>unchanged</style>')
        with self.assertRaises(ValueError): self.sync()
        self.assertFalse((self.out / 'updates/ios.json').exists())
        self.assertEqual((self.out / 'index.html').read_text(), '<style>unchanged</style>')

    def test_rollback_and_same_version_replacement_rejected(self):
        self.sync()
        path = self.out / 'updates/ios.json'
        original = path.read_bytes()
        with self.assertRaises(ValueError): self.sync([dict(self.release, tag_name='ios-v0.4.99')])
        self.assertEqual(path.read_bytes(), original)
        feed = json.loads(original)
        feed['packages']['MarcoMovie-0.5.1-ios-unsigned.ipa']['sha256'] = 'c' * 64
        path.write_text(json.dumps(feed))
        with self.assertRaises(ValueError): self.sync()

    def test_missing_second_windows_asset_does_not_publish_partial_feed(self):
        with patch.object(m, 'platform_asset', side_effect=[('first', 10, 'b' * 64, b'installer'), ValueError('missing ZIP')]):
            with self.assertRaises(ValueError): m.sync(self.out, [dict(self.release, tag_name='windows-v0.5.1')])
        self.assertFalse((self.out / 'updates/windows.json').exists())
        self.assertFalse((self.out / 'MarcoMovie-0.5.1-windows-setup.exe').exists())
        self.assertEqual((self.out / 'index.html').read_text(encoding='utf-8'), self.page)

    def test_notes_are_complete_escaped_and_archived_for_each_version(self):
        self.release['body'] = '新增本地包\n修复返回\n<script>not executable</script>\n已知限制：待实机测试'
        self.sync()
        notes = self.out / 'updates/history/ios-v0.5.1.md'
        self.assertEqual(notes.read_text(encoding='utf-8'), self.release['body'] + '\n')
        page = (self.out / 'index.html').read_text(encoding='utf-8')
        self.assertIn('&lt;script&gt;not executable&lt;/script&gt;', page)
        self.assertNotIn('<script>', page)
        newer = dict(self.release, tag_name='ios-v0.5.2', published_at='later', body='第二版修复')
        self.sync([newer])
        records = json.loads((self.out / 'updates/history.json').read_text(encoding='utf-8'))['releases']
        self.assertEqual({r['tag'] for r in records}, {'ios-v0.5.1', 'ios-v0.5.2'})
        self.assertEqual(notes.read_text(encoding='utf-8'), self.release['body'] + '\n')
        page = (self.out / 'index.html').read_text(encoding='utf-8')
        self.assertEqual(page.count(' open>'), 1)
        self.assertIn('iPhone / iPad · 0.5.2', page)
        self.assertIn('iPhone / iPad · 0.5.1', page)

    def test_missing_new_release_notes_fails_before_any_write(self):
        for body in ('', '  ', None):
            with self.assertRaisesRegex(ValueError, 'missing update notes'):
                self.sync([dict(self.release, body=body)])
        self.assertEqual((self.out / 'index.html').read_text(encoding='utf-8'), self.page)
        self.assertFalse((self.out / 'updates/ios.json').exists())
        self.assertFalse((self.out / 'updates/history.json').exists())

    def test_shared_release_notes_use_actual_package_platforms(self):
        shared = dict(self.release, tag_name='v0.5.0-preview', body='共用版本的变更', assets=[
            {'name': 'MarcoMovie-0.5.0-preview.apk'}, {'name': 'MarcoMovie-0.5.0-mobile.apk'},
            {'name': 'MarcoMovie-0.5.0-ios-unsigned.ipa'}, {'name': 'MarcoMovie-0.5.0-source.zip'}])
        self.sync([self.release, shared])
        record = m.note_record(shared)
        self.assertEqual(record['platforms'], ['android-tv', 'android-mobile', 'ios'])
        self.assertEqual((self.out / 'updates/history/v0.5.0-preview.md').read_text(encoding='utf-8'), shared['body'] + '\n')
        self.assertEqual((self.out / 'updates/stable.json').read_text(), '{"versionName":"0.5.0"}')

    def test_missing_notes_section_fails_without_partial_feed(self):
        (self.out / 'index.html').write_text(self.page.replace('id="changelog"', 'id="other"'), encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'changelog section'):
            self.sync()
        self.assertFalse((self.out / 'updates/ios.json').exists())
        self.assertFalse((self.out / 'updates/history.json').exists())

    def test_notes_render_readably_without_html_or_unsafe_links(self):
        result = m.render_notes('## 修复\n\n1. **窗口** 与 `Esc`\n2. [说明](https://example.invalid/release)\n\n<script>alert(1)</script>\n[坏地址](javascript:alert)')
        self.assertIn('<h4>修复</h4>', result)
        self.assertIn('<ol><li><strong>窗口</strong> 与 <code>Esc</code>', result)
        self.assertIn('href="https://example.invalid/release"', result)
        self.assertNotIn('href="javascript:', result)
        self.assertIn('&lt;script&gt;', result)

    def test_visible_package_version_changes_with_download(self):
        page = self.page.replace('<h3>ios-unsigned.ipa</h3>', '<h3>iPhone</h3><span class="package-version">0.5.0</span>')
        package = dict(url='https://example.invalid/MarcoMovie-0.5.2-ios-unsigned.ipa', size=123, sha256='b'*64)
        result = m.patch_card(page, 'ios-unsigned.ipa', package)
        self.assertIn('<span class="package-version">0.5.2</span>', result)

    def test_responsive_card_metadata_survives_future_sync(self):
        page = self.page.replace('<div class="dl"><h3>ios-unsigned.ipa</h3>', '<div class="dl" data-platform="ios"><span class="package-version">0.5.0</span><h3>iPhone</h3>')
        page = page.replace('<code>SHA-256：', '<details class="package-check"><summary>校验</summary><code>SHA-256：').replace('</code>', '</code></details>')
        (self.out / 'index.html').write_text(page, encoding='utf8')
        self.sync()
        result = (self.out / 'index.html').read_text(encoding='utf8')
        self.assertIn('data-platform="ios"><span class="package-version">0.5.1</span>', result)
        self.assertIn('<details class="package-check"><summary>校验</summary><code>SHA-256：'+'b'*64, result)
        self.assertIn('<style>existing CSS</style>', result)


if __name__ == '__main__':
    unittest.main()
