"""Verify source/archive asset integrity across Windows and Unix line endings."""
from pathlib import Path
import hashlib
import json
import tempfile
import unittest
from unittest.mock import patch

import update_drpy_assets as assets


class AssetChecks(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.asset = self.root / 'drpy-fixture.cjs'
        self.asset.write_bytes(b'line one\r\nline two\r\n')
        self.root_patch = patch.object(assets, 'ROOT', self.root)
        self.names_patch = patch.object(assets, 'NAMES', [self.asset.name])
        self.root_patch.start()
        self.names_patch.start()
        self.addCleanup(self.root_patch.stop)
        self.addCleanup(self.names_patch.stop)

    def test_generation_normalizes_before_hashing(self):
        assets.update()
        data = self.asset.read_bytes()
        self.assertEqual(data, b'line one\nline two\n')
        entry = json.loads((self.root / 'drpy-assets.json').read_bytes())['files'][0]
        self.assertEqual(entry['bytes'], len(data))
        self.assertEqual(entry['sha256'], hashlib.sha256(data).hexdigest())
        assets.update(check=True)

    def test_check_rejects_stale_content_without_rewriting(self):
        assets.update()
        before = (self.root / 'drpy-assets.json').read_bytes()
        self.asset.write_bytes(b'changed\n')
        with self.assertRaisesRegex(ValueError, 'stale'):
            assets.update(check=True)
        self.assertEqual((self.root / 'drpy-assets.json').read_bytes(), before)

    def test_check_rejects_new_crlf_without_rewriting(self):
        raw = self.asset.read_bytes()
        with self.assertRaisesRegex(ValueError, 'must use LF'):
            assets.update(check=True)
        self.assertEqual(self.asset.read_bytes(), raw)


if __name__ == '__main__':
    unittest.main()
