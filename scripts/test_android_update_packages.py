"""Offline APK edition/publishing checks, with isolated output and no remote writes."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import android_update_packages as m
from android_package_names import package_name, compatibility_alias
from sync_platform_packages import patch_card


class AndroidUpdates(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.out = Path(self.temp.name)
        self.release = dict(tag_name='android-mobile-v0.5.2', published_at='2026-11-08',
                            draft=False, prerelease=False, body='Phone fixes')
        self.identity = dict(package='com.pilipala.marcomovie', edition='mobile',
                             versionName='0.5.2', versionCode=52, minSdk=23)
    def plan(self, releases=None):
        with patch.object(m, 'asset', return_value=(b'owned-apk', 'a' * 64)), \
             patch.object(m, 'apk_identity', return_value=self.identity):
            return m.plan(self.out, releases or [self.release])
    def test_independent_feed_and_actual_tag(self):
        files, versions, cards = self.plan()
        self.assertEqual(versions, {'android-mobile': '0.5.2'})
        self.assertNotIn('updates/stable.json', files)
        self.assertNotIn('updates/android-tv.json', files)
        feed = json.loads(files['updates/android-mobile.json'])
        self.assertEqual(feed['versionCode'], 52)
        self.assertTrue(feed['githubUrl'].endswith('/android-mobile-v0.5.2/MarcoMovie-0.5.2-android-mobile.apk'))
        self.assertEqual(files['updates/android-mobile-preview.json'], files['updates/android-mobile.json'])
        self.assertEqual(list(self.out.iterdir()), [], 'planning never mutates mirror')
    def test_preview_does_not_replace_stable(self):
        preview = dict(self.release, tag_name='android-mobile-v0.5.3-preview', prerelease=True)
        self.identity.update(versionName='0.5.3', versionCode=53)
        files, versions, cards = self.plan([preview])
        self.assertEqual(versions, {})
        self.assertEqual(cards, {})
        self.assertNotIn('updates/android-mobile.json', files)
        self.assertTrue(json.loads(files['updates/android-mobile-preview.json'])['prerelease'])
    def test_tag_and_channel_cannot_disagree(self):
        with self.assertRaises(ValueError): self.plan([dict(self.release, prerelease=True)])
    def test_apk_identity_not_filename_decides_edition(self):
        for identity in (dict(self.identity, edition='tv'), dict(self.identity, versionName='0.5.9'),
                         {k: v for k, v in self.identity.items() if k != 'edition'}):
            with patch.object(m, 'asset', return_value=(b'owned-apk', 'a' * 64)), patch.object(m, 'apk_identity', return_value=identity):
                with self.assertRaises(ValueError): m.plan(self.out, [self.release])
    def test_code_rollback_and_replacement_rejected(self):
        files, _, _ = self.plan()
        path = self.out / 'updates/android-mobile.json'
        path.parent.mkdir()
        path.write_bytes(files['updates/android-mobile.json'])
        self.identity['versionCode'] = 51
        with self.assertRaises(ValueError): self.plan()
        self.identity['versionCode'] = 52
        old = json.loads(path.read_bytes()); old['sha256'] = 'b' * 64
        path.write_text(json.dumps(old))
        with self.assertRaises(ValueError): self.plan()
    def test_notes_required_before_publication(self):
        for notes in ('', ' ', None, 'x' * 8001):
            with self.assertRaises(ValueError): self.plan([dict(self.release, body=notes)])
    def test_new_names_and_legacy_alias_bytes(self):
        for edition, suffix in (('mobile', 'mobile'), ('tv', 'preview'), ('lite', 'lite')):
            name = package_name('0.5.2', edition)
            self.assertEqual(name, f'MarcoMovie-0.5.2-android-{edition}.apk')
            path = self.out / name; path.write_bytes(b'signed-package-' + edition.encode())
            alias = compatibility_alias(path, '0.5.2', edition)
            self.assertEqual(alias.name, f'MarcoMovie-0.5.2-{suffix}.apk')
            self.assertEqual(alias.read_bytes(), path.read_bytes())
            self.assertEqual(alias.with_name(alias.name + '.sha256').read_text(),
                             hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + alias.name + '\n')
    def test_existing_card_changes_links_without_restyling(self):
        for platform, old in (('android-mobile', 'mobile'), ('android-tv', 'preview')):
            name = f'MarcoMovie-0.5.0-{old}.apk'
            page = f'<style>untouched</style><div class="dl" data-platform="{platform}"><a href="{name}">下载</a><a href="{name}.sha256">校验</a><code>SHA-256：{"a"*64}</code><span>12.0 MB</span></div>'
            package = dict(url=m.BASE + f'MarcoMovie-0.5.2-{platform}.apk', size=100, sha256='b'*64)
            result = patch_card(page, platform + '.apk', package)
            self.assertIn('<style>untouched</style>', result)
            self.assertIn('href="' + package['url'] + '"', result)
            self.assertEqual(patch_card(result, platform + '.apk', package), result)


if __name__ == '__main__':
    unittest.main()
