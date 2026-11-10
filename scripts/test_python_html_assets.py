"""Reject corrupted HTML bundles and stale recipes without rebuilding or network use."""
from pathlib import Path
import json
import tempfile
import unittest
from unittest.mock import patch
import prepare_python_html as assets


class HtmlAssetChecks(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        for name in ('parser.js', 'parser-LICENSE.txt', 'parser-provenance.json'):
            (root / name).write_bytes((assets.OUT / name).read_bytes())
        for name, value in [('OUT', root), ('MANIFEST', root / 'parser-provenance.json')]:
            p = patch.object(assets, name, value)
            p.start()
            self.addCleanup(p.stop)

    def test_current_bundle_matches_pinned_recipe(self):
        assets.verify()

    def test_modified_code_rejected(self):
        with (assets.OUT / 'parser.js').open('ab') as stream:
            stream.write(b'\n// changed')
        with self.assertRaisesRegex(ValueError, 'digest mismatch'):
            assets.verify()

    def test_license_changes_rejected(self):
        (assets.OUT / 'parser-LICENSE.txt').write_bytes(b'missing notices')
        with self.assertRaisesRegex(ValueError, 'digest mismatch'):
            assets.verify()

    def test_stale_recipe_rejected(self):
        doc = json.loads(assets.MANIFEST.read_bytes())
        doc['entry_sha256'] = '0' * 64
        assets.MANIFEST.write_text(json.dumps(doc), encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'recipe changed'):
            assets.verify()

    def test_lock_dependency_mismatch_rejected(self):
        doc = json.loads(assets.MANIFEST.read_bytes())
        doc['packages']['node_modules/cheerio']['integrity'] = 'wrong'
        assets.MANIFEST.write_text(json.dumps(doc), encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'differs from npm lock'):
            assets.verify()


if __name__ == '__main__':
    unittest.main()
