"""Deployment guard regression tests; these do not replace a device launch test."""
import plistlib
import struct
import tempfile
import unittest
from unittest.mock import patch
import prepare_platform
from pathlib import Path
from patch_ios_ipa import validate_app


class DeploymentChecks(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.app = Path(self.folder.name)
        (self.app / 'Info.plist').write_bytes(plistlib.dumps({'MinimumOSVersion': '14.0'}))

    def binary(self, minimum, platform=2):
        return struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, 1, 24, 0, 0) + struct.pack('<6I', 0x32, 24, platform, minimum, 0x120000, 0)

    def test_real_compatible_deployment_is_unchanged(self):
        blob = self.binary(0x0d0000)
        (self.app / 'Runner').write_bytes(blob)
        validate_app(self.app)
        self.assertEqual((self.app / 'Runner').read_bytes(), blob)

    def test_new_engine_is_rejected_instead_of_forging_minimum(self):
        blob = self.binary(0x0f0000)
        (self.app / 'Runner').write_bytes(blob)
        with self.assertRaises(ValueError):
            validate_app(self.app)
        self.assertEqual((self.app / 'Runner').read_bytes(), blob)

    def test_simulator_binary_rejected(self):
        (self.app / 'Runner').write_bytes(self.binary(0x0e0000, 7))
        with self.assertRaises(ValueError):
            validate_app(self.app)

    def test_truncated_binary_rejected(self):
        (self.app / 'Runner').write_bytes(self.binary(0x0e0000)[:-4])
        with self.assertRaises(ValueError):
            validate_app(self.app)

    def test_empty_bundle_rejected(self):
        with self.assertRaises(ValueError):
            validate_app(self.app)

    def test_platform_settings_are_written_at_plist_root(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            runner = root / 'ios/Runner'
            runner.mkdir(parents=True)
            plist = runner / 'Info.plist'
            nested = {'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': True}}
            plist.write_bytes(plistlib.dumps(nested))
            with patch.object(prepare_platform, 'ROOT', root):
                prepare_platform.main()
            result = plistlib.loads(plist.read_bytes())
            self.assertIn('NSLocalNetworkUsageDescription', result)
            self.assertTrue(result['NSAppTransportSecurity']['NSAllowsArbitraryLoads'])
            self.assertEqual(result['UIApplicationSceneManifest'], nested['UIApplicationSceneManifest'])


if __name__ == '__main__':
    unittest.main()
